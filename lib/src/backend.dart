/// A platform implementation of the embedded Tailscale node + local proxy.
///
/// The default is [MethodChannelTailscaleBackend] (Go tsnet via gomobile,
/// iOS). Alternative backends (Android gomobile .aar, FFI-based packages)
/// can be slotted in without touching consumers.
abstract class TailscaleBackend {
  /// Whether this backend can run on the current platform.
  bool get isSupported;

  /// Start the node (blocking until authenticated) and the local proxy.
  /// Returns the proxy port. Throws with a platform error on auth failure.
  Future<int> start(String authKey, String hostname);

  /// Health-check the local proxy listener and rebind it if the OS reclaimed
  /// it. Returns the current port, or null if the node is not running.
  Future<int?> ensure();

  /// Stop the proxy and the node.
  Future<void> stop();

  Future<bool> isRunning();

  Future<int?> getPort();
}
