import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'backend.dart';
import 'config.dart';
import 'status.dart';

/// Default backend: Go tsnet compiled with gomobile, bridged over a
/// MethodChannel registered by the plugin's native side.
class MethodChannelTailscaleBackend implements TailscaleBackend {
  static const _channel = MethodChannel('com.tailarr.tailscale_embed/method');

  const MethodChannelTailscaleBackend();

  @override
  bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<int> start(TailscaleConfig config) async {
    final port = await _channel.invokeMethod<int>('start', {
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
    return _channel.invokeMethod<int>('ensure');
  }

  @override
  Future<void> stop() async {
    await _channel.invokeMethod('stop');
  }

  @override
  Future<bool> isRunning() async {
    return await _channel.invokeMethod<bool>('isRunning') ?? false;
  }

  @override
  Future<int?> getPort() async {
    return _channel.invokeMethod<int>('getPort');
  }

  @override
  Future<TailscaleStatus?> status() async {
    final raw = await _channel.invokeMethod<String>('status');
    if (raw == null) return null;
    return TailscaleStatus.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>());
  }

  @override
  Future<String?> activeIdentity() {
    return _channel.invokeMethod<String>('getActiveIdentity');
  }

  @override
  Future<List<String>> listIdentities() async {
    final names = await _channel.invokeMethod<List<Object?>>('listIdentities');
    return names?.cast<String>() ?? const [];
  }

  @override
  Future<void> deleteIdentity(String identity) async {
    await _channel.invokeMethod('deleteIdentity', {'identity': identity});
  }

  @override
  Future<void> installWebViewProxy(int port) async {
    await _channel.invokeMethod('installWebViewProxy', {'port': port});
  }
}
