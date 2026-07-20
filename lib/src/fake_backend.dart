import 'package:flutter/services.dart';

import 'auth_keys.dart';
import 'backend.dart';
import 'config.dart';
import 'status.dart';

/// An in-memory [TailscaleBackend] for consumer tests: no MethodChannel, no
/// device, no network. Pass it to `TailscaleEmbed.instance.configure(backend:
/// …)` in a widget test and the whole facade — start/ensure/stop, identity
/// switching, onKeyConsumed, status — behaves like a node that always comes
/// up.
///
/// ```dart
/// final backend = FakeTailscaleBackend();
/// TailscaleEmbed.instance.configure(
///   config: () => const TailscaleConfig(enabled: true, authKey: 'k'),
///   backend: backend,
/// );
/// await tester.pumpWidget(const MyApp());
/// ```
///
/// Knobs: [startError] makes the next start throw (auth-failure UI paths),
/// [statusOverride] pins what `status()` returns (peer lists, health
/// warnings), and [enrolled] seeds identities that already have "on-disk"
/// state. [startedConfigs] records every config a start actually used, for
/// assertions.
class FakeTailscaleBackend extends TailscaleBackend {
  FakeTailscaleBackend({
    this.supported = true,
    this.port = 40000,
    Set<String>? enrolled,
  }) : enrolled = enrolled ?? <String>{};

  /// What [isSupported] reports.
  bool supported;

  /// The proxy port a successful start returns.
  int port;

  /// When set, the next [start] throws this (and clears it), leaving the
  /// backend stopped — like a failed enrollment with nothing to roll back
  /// to. Use a `PlatformException(code: TailscaleErrorCodes.…)` to exercise
  /// error-code handling.
  Object? startError;

  /// When set, [status] returns this instead of the synthesized snapshot.
  TailscaleStatus? statusOverride;

  /// Identities with persisted node state, as [listIdentities] reports them.
  final Set<String> enrolled;

  /// Every config passed to a successful [start], oldest first.
  final List<TailscaleConfig> startedConfigs = [];

  /// Ports passed to [installWebViewProxy], oldest first.
  final List<int> webViewProxyPorts = [];

  String? _active;
  bool _running = false;

  /// The identity currently "running", or null when stopped.
  String? get runningIdentity => _running ? _active : null;

  @override
  bool get isSupported => supported;

  @override
  Future<int> start(TailscaleConfig config) async {
    if (startError != null) {
      final error = startError!;
      startError = null;
      _running = false;
      _active = null;
      throw error;
    }
    _running = true;
    _active = config.identity;
    if (!config.ephemeral) enrolled.add(config.identity);
    startedConfigs.add(config);
    return port;
  }

  @override
  Future<int?> ensure() async => _running ? port : null;

  @override
  Future<void> stop() async {
    _running = false;
    _active = null;
  }

  @override
  Future<bool> isRunning() async => _running;

  @override
  Future<int?> getPort() async => _running ? port : null;

  @override
  Future<TailscaleStatus?> status() async =>
      statusOverride ??
      TailscaleStatus(
        running: _running,
        identity: _active,
        proxyPort: _running ? port : 0,
        backendState: _running ? 'Running' : '',
      );

  @override
  Future<String?> activeIdentity() async => runningIdentity;

  @override
  Future<List<String>> listIdentities() async => enrolled.toList()..sort();

  @override
  Future<void> deleteIdentity(String identity) async {
    if (_running && identity == _active) {
      throw PlatformException(
        code: TailscaleErrorCodes.identityActive,
        message: "Identity '$identity' is currently running",
      );
    }
    enrolled.remove(identity);
  }

  @override
  Future<void> installWebViewProxy(int port) async {
    webViewProxyPorts.add(port);
  }
}
