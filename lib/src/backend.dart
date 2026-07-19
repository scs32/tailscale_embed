import 'config.dart';
import 'status.dart';

/// A platform implementation of the embedded Tailscale node + local proxy.
///
/// The default is [MethodChannelTailscaleBackend] (Go tsnet via gomobile,
/// iOS). Alternative backends (Android gomobile .aar, FFI-based packages)
/// can be slotted in without touching consumers.
abstract class TailscaleBackend {
  /// Whether this backend can run on the current platform.
  bool get isSupported;

  /// Start the node (blocking until authenticated) and the local proxy.
  /// Returns the proxy port. Throws with a platform error on auth failure —
  /// see [TailscaleErrorCodes] for the stable codes.
  Future<int> start(TailscaleConfig config);

  /// Health-check the local proxy listener and rebind it if the OS reclaimed
  /// it. Returns the current port, or null if the node is not running.
  Future<int?> ensure();

  /// Stop the proxy and the node.
  Future<void> stop();

  Future<bool> isRunning();

  Future<int?> getPort();

  /// A snapshot of the node's state (tailnet IPs, DNS name, backend state,
  /// peers) for consumer UIs. Returns null when the backend has no status
  /// support; a `TailscaleStatus(running: false)` when the node is stopped.
  Future<TailscaleStatus?> status() async => null;

  /// Point the platform's system webview (WKWebView on iOS) at the local
  /// proxy on [port], so webview traffic reaches the tailnet too. The proxy
  /// carries all traffic (tailnet via tsnet, everything else dialed
  /// directly). No-op by default; backends without webview support may
  /// leave it unimplemented. On iOS this requires iOS 17+.
  Future<void> installWebViewProxy(int port) async {}
}
