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

  /// The identity name of the currently running node, or null when the node
  /// is stopped (or the backend doesn't track identities).
  Future<String?> activeIdentity() async => null;

  /// Logical identity names that have on-disk state. Empty when the backend
  /// doesn't support identities.
  Future<List<String>> listIdentities() async => const [];

  /// Whether [identity] has enrolled (has persisted node state on disk).
  /// Derived from [listIdentities] by default; backends with a cheaper
  /// check may override.
  Future<bool> isEnrolled(String identity) async =>
      (await listIdentities()).contains(identity);

  /// Delete the on-disk node state for [identity]. Throws with code
  /// `IDENTITY_ACTIVE` when it names the currently running identity; a
  /// no-op when the identity has no state (or the backend doesn't support
  /// identities).
  Future<void> deleteIdentity(String identity) async {}

  /// Point the platform's system webview (WKWebView on iOS) at the local
  /// proxy on [port], so webview traffic reaches the tailnet too. The proxy
  /// carries all traffic (tailnet via tsnet, everything else dialed
  /// directly). No-op by default; backends without webview support may
  /// leave it unimplemented. On iOS this requires iOS 17+.
  Future<void> installWebViewProxy(int port) async {}
}
