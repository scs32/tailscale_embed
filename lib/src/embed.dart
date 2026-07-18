import 'backend.dart';
import 'config.dart';
import 'method_channel_backend.dart';

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

  /// The local proxy port, or null when the node is not running.
  int? get proxyPort => _proxyPort;

  TailscaleBackend get backend => _backend;
  TailscaleConfig get config => _config();

  bool get isSupported => _backend.isSupported;
  bool get isEnabled => isSupported && config.enabled;

  void configure({
    required TailscaleConfigProvider config,
    TailscaleBackend? backend,
  }) {
    _config = config;
    if (backend != null) _backend = backend;
  }

  /// Start the node with the configured auth key. Blocks until the node is
  /// authenticated (tsnet `Up()`), so auth failures surface here.
  Future<int> start() async {
    final cfg = config;
    final port = await _backend.start(cfg.authKey, cfg.hostname);
    _proxyPort = port;
    return port;
  }

  /// Ensure the node is up and its local listener is healthy, starting or
  /// rebinding as needed (iOS reclaims sockets during suspension).
  Future<int> ensure() async {
    final port = await _backend.ensure();
    if (port != null) {
      _proxyPort = port;
      return port;
    }
    return start();
  }

  Future<void> stop() async {
    await _backend.stop();
    _proxyPort = null;
  }

  Future<bool> isRunning() => _backend.isRunning();
}
