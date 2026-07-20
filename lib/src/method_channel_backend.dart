import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'auth_keys.dart';
import 'backend.dart';
import 'config.dart';
import 'status.dart';

/// Default backend: Go tsnet compiled with gomobile, bridged over a
/// MethodChannel registered by the plugin's native side.
///
/// The native plugin is registered only for the iOS target. Flutter reports
/// tvOS (and iPad-on-visionOS) as [TargetPlatform.iOS] with no way to tell
/// them apart synchronously, so [isSupported] is optimistic until proven
/// otherwise: the first channel call that comes back as a
/// [MissingPluginException] — which is exactly what a tvOS target with no
/// registered plugin produces — latches this instance to unsupported, so
/// [isSupported] then reports `false` and no further call reaches a dead
/// channel. That one probing call surfaces as a clean [TailscaleErrorCodes]
/// `UNSUPPORTED` error rather than an uncaught `MissingPluginException`.
class MethodChannelTailscaleBackend implements TailscaleBackend {
  static const _channel = MethodChannel('com.tailarr.tailscale_embed/method');

  const MethodChannelTailscaleBackend();

  /// Latched true once a channel call reveals no plugin is registered on this
  /// platform. Static so every instance (the default backend is constructed
  /// in several places) shares the verdict once any one of them learns it.
  static bool _pluginMissing = false;

  @override
  bool get isSupported =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      !_pluginMissing;

  /// Invokes a channel method, translating a missing native plugin (no
  /// backend registered for this platform, e.g. tvOS) into a latched
  /// unsupported state plus a typed [TailscaleErrorCodes.unsupported] error.
  Future<T?> _invoke<T>(String method, [dynamic arguments]) async {
    if (_pluginMissing) throw _unsupported(method);
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      _pluginMissing = true;
      throw _unsupported(method);
    }
  }

  PlatformException _unsupported(String method) => PlatformException(
        code: TailscaleErrorCodes.unsupported,
        message: 'The embedded Tailscale node is not available on this '
            'platform (no native plugin registered).',
        details: {'method': method},
      );

  @override
  Future<int> start(TailscaleConfig config) async {
    final port = await _invoke<int>('start', {
      'authKey': config.authKey,
      'hostname': config.hostname,
      'ephemeral': config.ephemeral,
      'upTimeoutSeconds': config.upTimeout.inSeconds,
      'acceptRoutes': config.acceptRoutes,
      'identity': config.identity,
    });
    if (port == null) {
      throw Exception('Failed to start the embedded Tailscale proxy');
    }
    return port;
  }

  @override
  Future<int?> ensure() async {
    if (!await isRunning()) return null;
    return _invoke<int>('ensure');
  }

  @override
  Future<void> stop() async {
    await _invoke('stop');
  }

  @override
  Future<bool> isRunning() async {
    // A missing plugin means nothing is running — swallow it here (rather
    // than throwing) so lifecycle checks like TailscaleGuard degrade to a
    // quiet no-op on unsupported platforms instead of erroring on resume.
    if (_pluginMissing) return false;
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } on MissingPluginException {
      _pluginMissing = true;
      return false;
    }
  }

  @override
  Future<int?> getPort() async {
    if (_pluginMissing) return null;
    try {
      return await _channel.invokeMethod<int>('getPort');
    } on MissingPluginException {
      _pluginMissing = true;
      return null;
    }
  }

  @override
  Future<TailscaleStatus?> status() async {
    // Status is read speculatively by settings UIs; a missing plugin means
    // "no status to show", not an error to surface.
    if (_pluginMissing) return null;
    final String? raw;
    try {
      raw = await _channel.invokeMethod<String>('status');
    } on MissingPluginException {
      _pluginMissing = true;
      return null;
    }
    if (raw == null) return null;
    return TailscaleStatus.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>());
  }

  @override
  Future<String?> activeIdentity() async {
    if (_pluginMissing) return null;
    try {
      return await _channel.invokeMethod<String>('getActiveIdentity');
    } on MissingPluginException {
      _pluginMissing = true;
      return null;
    }
  }

  @override
  Future<List<String>> listIdentities() async {
    if (_pluginMissing) return const [];
    try {
      final names =
          await _channel.invokeMethod<List<Object?>>('listIdentities');
      return names?.cast<String>() ?? const [];
    } on MissingPluginException {
      _pluginMissing = true;
      return const [];
    }
  }

  @override
  Future<bool> isEnrolled(String identity) async =>
      (await listIdentities()).contains(identity);

  @override
  Future<void> deleteIdentity(String identity) async {
    await _invoke('deleteIdentity', {'identity': identity});
  }

  @override
  Future<void> installWebViewProxy(int port) async {
    await _invoke('installWebViewProxy', {'port': port});
  }
}
