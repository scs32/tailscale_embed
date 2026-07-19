import 'backend.dart';
import 'config.dart';
import 'method_channel_backend.dart';
import 'status.dart';

/// Singleton facade over the embedded Tailscale node.
///
/// Call [configure] once at startup with a config provider that reads your
/// app's settings, then use [ensure]/[start]/[stop]. The current proxy port
/// is cached here and read per-request by the routing layer (see
/// `tailscale_embed_io.dart`), so clients created before the node started —
/// or across an iOS socket rebind — always use the live port.
class TailscaleEmbed {
  TailscaleEmbed._();
  static final TailscaleEmbed instance = TailscaleEmbed._();

  TailscaleBackend _backend = const MethodChannelTailscaleBackend();
  TailscaleConfigProvider _config = () =>
      const TailscaleConfig(enabled: false, authKey: '');

  int? _proxyPort;
  bool _webViewProxy = false;
  void Function(String identity)? _onKeyConsumed;

  /// Serializes start/ensure/stop/deleteIdentity so an identity switch is
  /// atomic from callers' point of view: an `ensure()` arriving while a
  /// switch is in flight (e.g. TailscaleGuard on app resume) waits for it,
  /// then health-checks whichever identity won.
  Future<void> _serial = Future.value();
  Future<T> _serialized<T>(Future<T> Function() op) {
    final run = _serial.then((_) => op());
    _serial = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// The local proxy port, or null when the node is not running.
  int? get proxyPort => _proxyPort;

  TailscaleBackend get backend => _backend;
  TailscaleConfig get config => _config();

  bool get isSupported => _backend.isSupported;
  bool get isEnabled => isSupported && config.enabled;

  /// [webViewProxy]: also point the platform's system webview (WKWebView)
  /// at the local proxy whenever the node (re)starts or rebinds, so webview
  /// traffic reaches the tailnet too. Requires iOS 17+.
  ///
  /// [onKeyConsumed]: fired after a start succeeded while an auth key was
  /// configured — the key has served its purpose (the node identity now
  /// persists on disk) and can be deleted from your settings store, so a
  /// plaintext `tskey-auth-…` doesn't linger where it could leak. The
  /// argument is the identity the key enrolled — taken from the config that
  /// start actually used, so it stays correct even if the provider switched
  /// identities while the start was in flight.
  void configure({
    required TailscaleConfigProvider config,
    TailscaleBackend? backend,
    bool webViewProxy = false,
    void Function(String identity)? onKeyConsumed,
  }) {
    _config = config;
    _webViewProxy = webViewProxy;
    _onKeyConsumed = onKeyConsumed;
    if (backend != null) _backend = backend;
  }

  /// Start the node with the configured auth key. Blocks until the node is
  /// authenticated (tsnet `Up()`), so auth failures surface here.
  ///
  /// A start on a new identity that fails rolls back to the previously
  /// running identity's node (tunnel-up beats consistency); the error's
  /// `details` map carries `rolledBack` and `activeIdentity` saying which
  /// identity is actually running.
  Future<int> start() => _serialized(_start);

  Future<int> _start() async {
    final cfg = config;
    final port = await _backend.start(cfg);
    await _adoptPort(port);
    // The node is up, so its persisted identity exists — the auth key (if
    // one was set) has been consumed or is no longer needed. Ephemeral
    // nodes keep needing the key on every start.
    if (cfg.authKey.isNotEmpty && !cfg.ephemeral) {
      _onKeyConsumed?.call(cfg.identity);
    }
    return port;
  }

  /// Ensure the node is up and its local listener is healthy, starting or
  /// rebinding as needed (iOS reclaims sockets during suspension). When the
  /// config provider now names a different identity than the running node,
  /// this switches: the running node stops and the new identity's node
  /// starts (fresh enroll if it has no state yet).
  Future<int> ensure() => _serialized(() async {
        final cfg = config;
        final active = await _backend.activeIdentity();
        if (active != null && active != cfg.identity) {
          // Identity switch — the backend's start stops the running node
          // before bringing up the new identity's state.
          return _start();
        }
        final port = await _backend.ensure();
        if (port != null) {
          await _adoptPort(port);
          return port;
        }
        return _start();
      });

  Future<void> _adoptPort(int port) async {
    _proxyPort = port;
    if (_webViewProxy) await _backend.installWebViewProxy(port);
  }

  Future<void> stop() => _serialized(() async {
        await _backend.stop();
        _proxyPort = null;
      });

  Future<bool> isRunning() => _backend.isRunning();

  /// A snapshot of the node's state (IPs, DNS name, backend state, peers)
  /// for settings pages and connection indicators. Null when the backend
  /// doesn't support status.
  Future<TailscaleStatus?> status() => _backend.status();

  /// The identity name of the currently running node, or null when stopped.
  Future<String?> activeIdentity() => _backend.activeIdentity();

  /// Identity names with on-disk node state, for cleanup UIs.
  Future<List<String>> listIdentities() => _backend.listIdentities();

  /// Delete the on-disk node state for [identity] (e.g. when the profile it
  /// belonged to is deleted, so orphaned identities don't accumulate).
  /// Throws with code `IDENTITY_ACTIVE` if it is currently running.
  Future<void> deleteIdentity(String identity) =>
      _serialized(() => _backend.deleteIdentity(identity));
}
