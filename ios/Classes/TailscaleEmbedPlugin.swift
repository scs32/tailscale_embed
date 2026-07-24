import Flutter
import UIKit
import WebKit
import Network
import TailscaleEmbed

public class TailscaleEmbedPlugin: NSObject, FlutterPlugin {
    private var tailscale: TsembedTailscale?
    private var proxyPort: Int?

    /// The identity name of the node currently running (or nil when
    /// stopped). After a rollback this is the identity that actually came
    /// back up, which may differ from the one the failed start asked for.
    private var activeIdentity: String?

    private struct StartConfig {
        let identity: String
        let authKey: String
        let hostname: String
        let ephemeral: Bool
        let upTimeoutSeconds: Int
        let acceptRoutes: Bool
    }

    /// The config of the last successful start — used to roll the node back
    /// when a re-start with new settings (e.g. a bad auth key) fails, so a
    /// working node isn't torn down for nothing. This includes the identity:
    /// a failed switch to identity B restarts identity A's node (tunnel-up
    /// beats consistency). The persisted identity makes the rollback start
    /// succeed even with a consumed key.
    private var lastGoodConfig: StartConfig?

    /// Rebinds magicsock on every network path change. iOS invalidates UDP
    /// sockets on WiFi↔cellular handoffs and radio power transitions that
    /// can happen while the app is foregrounded — no resume event fires
    /// there, so the EnsureProxy wake rebind never runs. This mirrors the
    /// official iOS client, which pairs its wake rebind with an
    /// NWPathMonitor-driven one. Started lazily at the first successful
    /// start and kept for the plugin's lifetime (NWPathMonitor cannot be
    /// restarted after cancel); the isRunning guard makes it inert while
    /// the node is stopped.
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(
        label: "com.tailarr.tailscale_embed.path-monitor")
    /// Last seen path signature, touched only on pathMonitorQueue.
    private var lastPathSignature: String?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.tailarr.tailscale_embed/method",
            binaryMessenger: registrar.messenger()
        )
        let instance = TailscaleEmbedPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            handleStart(call: call, result: result)
        case "stop":
            handleStop(result: result)
        case "ensure":
            handleEnsure(result: result)
        case "isRunning":
            result(tailscale?.isRunning() ?? false)
        case "status":
            handleStatus(result: result)
        case "installWebViewProxy":
            handleInstallWebViewProxy(call: call, result: result)
        case "getActiveIdentity":
            result(tailscale?.isRunning() == true ? activeIdentity : nil)
        case "listIdentities":
            handleListIdentities(result: result)
        case "deleteIdentity":
            handleDeleteIdentity(call: call, result: result)
        case "getPort":
            if let port = proxyPort, tailscale?.isRunning() == true {
                result(port)
            } else {
                result(nil)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// The Go layer prefixes errors with "tsembed:CODE: " so a stable code
    /// survives the gomobile→NSError trip. Parse it into FlutterError.code;
    /// fall back to the given code for errors without a prefix.
    private func flutterError(_ error: Error, fallbackCode: String) -> FlutterError {
        let msg = error.localizedDescription
        if let match = msg.range(of: #"tsembed:([A-Z_]+): "#, options: .regularExpression) {
            let tagged = String(msg[match])  // "tsembed:CODE: "
            let code = String(tagged.dropFirst("tsembed:".count).dropLast(2))
            let detail = String(msg[match.upperBound...])
            return FlutterError(code: code, message: detail, details: nil)
        }
        return FlutterError(code: fallbackCode, message: msg, details: nil)
    }

    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Interface names distinguish real transitions (en0→pdp_ip0)
            // that a status-only signature would miss.
            let signature = path.status == .satisfied
                ? "up|" + path.availableInterfaces
                    .map { "\($0.type):\($0.name)" }
                    .joined(separator: ",")
                : "down"
            // The first callback reports the current path, not a change —
            // record the baseline and only rebind on real transitions.
            let changed = self.lastPathSignature != nil
                && self.lastPathSignature != signature
            self.lastPathSignature = signature
            guard changed else { return }
            // Snapshot the instance on the main thread (where it's
            // mutated), then rebind off it — Rebind churns sockets and
            // ReSTUN does network work.
            DispatchQueue.main.async {
                guard let instance = self.tailscale, instance.isRunning() else { return }
                DispatchQueue.global(qos: .utility).async {
                    instance.rebindNetwork()
                }
            }
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    private func makeInstance(stateDir: String, config: StartConfig) -> TsembedTailscale? {
        let instance = TsembedNewTailscale(stateDir, config.authKey, config.hostname)
        instance?.setIdentity(config.identity)
        instance?.setEphemeral(config.ephemeral)
        instance?.setUpTimeoutSeconds(config.upTimeoutSeconds)
        instance?.setAcceptRoutes(config.acceptRoutes)
        return instance
    }

    private func handleStart(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let authKey = args["authKey"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGUMENT",
                message: "Missing authKey argument",
                details: nil
            ))
            return
        }
        let identity = args["identity"] as? String ?? "default"
        guard Self.isValidIdentity(identity) else {
            result(FlutterError(
                code: "INVALID_ARGUMENT",
                message: "Invalid identity name '\(identity)' — must match "
                    + "[A-Za-z0-9][A-Za-z0-9._-]* (max 64 chars)",
                details: nil
            ))
            return
        }
        let config = StartConfig(
            identity: identity,
            authKey: authKey,
            hostname: args["hostname"] as? String ?? "",
            ephemeral: args["ephemeral"] as? Bool ?? false,
            upTimeoutSeconds: args["upTimeoutSeconds"] as? Int ?? 45,
            acceptRoutes: args["acceptRoutes"] as? Bool ?? true
        )

        guard let stateDir = stateDirectory(identity: identity) else {
            result(FlutterError(
                code: "STATE_DIR_ERROR",
                message: "Failed to create state directory",
                details: nil
            ))
            return
        }

        // Stop existing instance if running. tsnet instances share the state
        // dir, so the old node must stop before the new one starts; if the
        // new one fails, we roll back to the last good config below.
        if tailscale?.isRunning() == true {
            tailscale?.stopProxy()
        }

        let instance = makeInstance(stateDir: stateDir, config: config)
        tailscale = instance

        // StartProxy blocks until the node is authenticated (up to the
        // configured timeout) — keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var port: Int = 0
                try instance?.startProxy(&port)
                DispatchQueue.main.async {
                    self.proxyPort = port
                    self.activeIdentity = config.identity
                    self.lastGoodConfig = config
                    self.startPathMonitorIfNeeded()
                    result(port)
                }
            } catch {
                let flutterErr = self.flutterError(error, fallbackCode: "START_FAILED")
                // Roll back: restart the previously-working node — its own
                // identity's state dir, which may differ from the one that
                // just failed — so a bad new key doesn't leave the user with
                // no tunnel at all.
                var rolledBack = false
                var runningIdentity: String?
                if let lastGood = self.lastGoodConfig,
                   let fallbackDir = self.stateDirectory(identity: lastGood.identity),
                   let fallback = self.makeInstance(stateDir: fallbackDir, config: lastGood) {
                    var port: Int = 0
                    if (try? fallback.startProxy(&port)) != nil {
                        rolledBack = true
                        runningIdentity = lastGood.identity
                        DispatchQueue.main.async {
                            self.tailscale = fallback
                            self.proxyPort = port
                            self.activeIdentity = lastGood.identity
                            self.startPathMonitorIfNeeded()
                        }
                    }
                }
                DispatchQueue.main.async {
                    if !rolledBack {
                        self.tailscale = nil
                        self.proxyPort = nil
                        self.activeIdentity = nil
                    }
                    result(FlutterError(
                        code: flutterErr.code,
                        message: flutterErr.message,
                        details: [
                            "rolledBack": rolledBack,
                            "activeIdentity": runningIdentity as Any? ?? NSNull(),
                        ]
                    ))
                }
            }
        }
    }

    private func handleEnsure(result: @escaping FlutterResult) {
        guard let instance = tailscale, instance.isRunning() else {
            result(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var port: Int = 0
                try instance.ensureProxy(&port)
                DispatchQueue.main.async {
                    self.proxyPort = port
                    result(port)
                }
            } catch {
                DispatchQueue.main.async {
                    result(self.flutterError(error, fallbackCode: "ENSURE_FAILED"))
                }
            }
        }
    }

    private func handleStatus(result: @escaping FlutterResult) {
        guard let instance = tailscale else {
            result("{\"running\":false}")
            return
        }
        // StatusJSON talks to the tsnet LocalClient — keep it off the main
        // thread like the other blocking calls.
        DispatchQueue.global(qos: .userInitiated).async {
            var statusError: NSError?
            let json = instance.statusJSON(&statusError)
            DispatchQueue.main.async {
                if let statusError {
                    result(self.flutterError(statusError, fallbackCode: "STATUS_FAILED"))
                } else {
                    result(json)
                }
            }
        }
    }

    private func handleStop(result: @escaping FlutterResult) {
        tailscale?.stopProxy()
        tailscale = nil
        proxyPort = nil
        activeIdentity = nil
        result(nil)
    }

    private func handleListIdentities(result: @escaping FlutterResult) {
        migrateLegacyStateIfNeeded()
        guard let dir = identitiesDirectory() else {
            result([String]())
            return
        }
        let fm = FileManager.default
        // Only identities that actually enrolled count — tailscaled.state is
        // the persisted node identity. The state dir itself is created
        // eagerly before a start, so a dir without it is just the residue of
        // a failed enrollment, not an identity. (This also backs
        // `isEnrolled` on the Dart side.)
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { name in
                Self.isValidIdentity(name)
                    && fm.fileExists(
                        atPath: dir.appendingPathComponent(name)
                            .appendingPathComponent("tailscaled.state").path)
            }
        result(names.sorted())
    }

    private func handleDeleteIdentity(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let identity = args["identity"] as? String,
              Self.isValidIdentity(identity) else {
            result(FlutterError(
                code: "INVALID_ARGUMENT",
                message: "Missing or invalid identity argument",
                details: nil
            ))
            return
        }
        if tailscale?.isRunning() == true, identity == activeIdentity {
            result(FlutterError(
                code: "IDENTITY_ACTIVE",
                message: "Identity '\(identity)' is currently running — stop "
                    + "the node or switch identities before deleting it",
                details: nil
            ))
            return
        }
        migrateLegacyStateIfNeeded()
        guard let dir = identitiesDirectory()?.appendingPathComponent(identity) else {
            result(nil)
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            do {
                try fm.removeItem(at: dir)
            } catch {
                result(FlutterError(
                    code: "DELETE_FAILED",
                    message: "Could not delete identity '\(identity)': "
                        + error.localizedDescription,
                    details: nil
                ))
                return
            }
        }
        result(nil)
    }

    // Points every WKWebView using the default WKWebsiteDataStore at the
    // embedded node's local HTTP CONNECT proxy. The proxy carries ALL
    // traffic (tailnet hosts via tsnet, everything else dialed directly),
    // so no match/exclude domain lists are needed. Call again after the
    // proxy rebinds on a new port — applies to subsequent loads.
    private func handleInstallWebViewProxy(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let port = args["port"] as? Int,
              port > 0, port <= 65535 else {
            result(FlutterError(
                code: "INVALID_ARGUMENT",
                message: "Missing or invalid port argument",
                details: nil
            ))
            return
        }
        guard #available(iOS 17.0, *) else {
            result(FlutterError(
                code: "UNSUPPORTED",
                message: "WKWebView proxying requires iOS 17 (WKWebsiteDataStore.proxyConfigurations)",
                details: nil
            ))
            return
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: UInt16(port))!
        )
        WKWebsiteDataStore.default().proxyConfigurations =
            [ProxyConfiguration(httpCONNECTProxy: endpoint)]
        result(nil)
    }

    // MARK: - Identity state layout
    //
    // The plugin owns the on-disk layout under its state root; consumers only
    // see logical identity names:
    //
    //   <AppSupport>/tailscale/identities/<name>/   one tsnet state dir each
    //
    // Versions before identities kept a single node's state directly at
    // <AppSupport>/tailscale/. That state is migrated in place to
    // identities/default on first use, so an upgrading user's node keeps its
    // enrollment (uniform layout beats a permanent legacy special case, and
    // makes list/delete trivial).

    /// Identity names are logical labels, never paths: first char
    /// alphanumeric (which also excludes "." and ".."), then a small safe
    /// charset, bounded length.
    static func isValidIdentity(_ name: String) -> Bool {
        return name.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
            options: .regularExpression
        ) != nil
    }

    private func stateRoot() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("tailscale")
    }

    private func identitiesDirectory() -> URL? {
        stateRoot()?.appendingPathComponent("identities")
    }

    /// Moves pre-identity state (a tsnet state dir directly at the root)
    /// into identities/default. Two atomic renames with a crash-recovery
    /// marker: root → tailscale.migrating, then tailscale.migrating →
    /// identities/default. A crash between them leaves the .migrating dir,
    /// which the next call finishes moving.
    private func migrateLegacyStateIfNeeded() {
        let fm = FileManager.default
        guard let root = stateRoot(), let identities = identitiesDirectory() else { return }
        let migrating = root.deletingLastPathComponent()
            .appendingPathComponent("tailscale.migrating")

        if !fm.fileExists(atPath: migrating.path) {
            // Only a root holding actual node state needs migrating —
            // tailscaled.state is the enrollment; logs alone are disposable.
            let legacyState = root.appendingPathComponent("tailscaled.state")
            guard fm.fileExists(atPath: legacyState.path),
                  !fm.fileExists(atPath: identities.path) else { return }
            try? fm.moveItem(at: root, to: migrating)
        }
        guard fm.fileExists(atPath: migrating.path) else { return }
        try? fm.createDirectory(at: identities, withIntermediateDirectories: true)
        try? fm.moveItem(at: migrating, to: identities.appendingPathComponent("default"))
    }

    private func stateDirectory(identity: String) -> String? {
        migrateLegacyStateIfNeeded()
        guard let dir = identitiesDirectory()?.appendingPathComponent(identity) else {
            return nil
        }
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return dir.path
    }
}
