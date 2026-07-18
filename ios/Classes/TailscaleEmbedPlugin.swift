import Flutter
import UIKit
import TailscaleEmbed

public class TailscaleEmbedPlugin: NSObject, FlutterPlugin {
    private var tailscale: TsembedTailscale?
    private var proxyPort: Int?

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
        let hostname = args["hostname"] as? String ?? ""

        guard let stateDir = stateDirectory() else {
            result(FlutterError(
                code: "STATE_DIR_ERROR",
                message: "Failed to create state directory",
                details: nil
            ))
            return
        }

        // Stop existing instance if running
        if tailscale?.isRunning() == true {
            tailscale?.stopProxy()
        }

        let instance = TsembedNewTailscale(stateDir, authKey, hostname)
        tailscale = instance

        // StartProxy blocks until the node is authenticated (up to ~45s) —
        // keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var port: Int = 0
                try instance?.startProxy(&port)
                DispatchQueue.main.async {
                    self.proxyPort = port
                    result(port)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "START_FAILED",
                        message: error.localizedDescription,
                        details: nil
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
                    result(FlutterError(
                        code: "ENSURE_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
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
