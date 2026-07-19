import Flutter
import UIKit
import WebKit
import Network
import TailscaleEmbed

public class TailscaleEmbedPlugin: NSObject, FlutterPlugin {
    private var tailscale: TsembedTailscale?
    private var proxyPort: Int?

    private struct StartConfig {
        let authKey: String
        let hostname: String
        let ephemeral: Bool
        let upTimeoutSeconds: Int
        let acceptRoutes: Bool
    }

    /// The config of the last successful start — used to roll the node back
    /// when a re-start with new settings (e.g. a bad auth key) fails, so a
    /// working node isn't torn down for nothing. The persisted identity
    /// makes the rollback start succeed even with a consumed key.
    private var lastGoodConfig: StartConfig?

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

    private func makeInstance(stateDir: String, config: StartConfig) -> TsembedTailscale? {
        let instance = TsembedNewTailscale(stateDir, config.authKey, config.hostname)
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
        let config = StartConfig(
            authKey: authKey,
            hostname: args["hostname"] as? String ?? "",
            ephemeral: args["ephemeral"] as? Bool ?? false,
            upTimeoutSeconds: args["upTimeoutSeconds"] as? Int ?? 45,
            acceptRoutes: args["acceptRoutes"] as? Bool ?? true
        )

        guard let stateDir = stateDirectory() else {
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
                    self.lastGoodConfig = config
                    result(port)
                }
            } catch {
                let flutterErr = self.flutterError(error, fallbackCode: "START_FAILED")
                // Roll back: restart the previously-working node so a bad
                // new key doesn't leave the user with no tunnel at all.
                var rolledBack = false
                if let lastGood = self.lastGoodConfig,
                   let fallback = self.makeInstance(stateDir: stateDir, config: lastGood) {
                    var port: Int = 0
                    if (try? fallback.startProxy(&port)) != nil {
                        rolledBack = true
                        DispatchQueue.main.async {
                            self.tailscale = fallback
                            self.proxyPort = port
                        }
                    }
                }
                DispatchQueue.main.async {
                    if !rolledBack {
                        self.tailscale = nil
                        self.proxyPort = nil
                    }
                    result(FlutterError(
                        code: flutterErr.code,
                        message: flutterErr.message,
                        details: ["rolledBack": rolledBack]
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

    private func stateDirectory() -> String? {
        guard let appSupportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let stateDir = appSupportDir.appendingPathComponent("tailscale")
        try? FileManager.default.createDirectory(
            at: stateDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return stateDir.path
    }
}
