import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'backend.dart';

/// Default backend: Go tsnet compiled with gomobile, bridged over a
/// MethodChannel registered by the plugin's native side.
class MethodChannelTailscaleBackend implements TailscaleBackend {
  static const _channel = MethodChannel('com.tailarr.tailscale_embed/method');

  const MethodChannelTailscaleBackend();

  @override
  bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<int> start(String authKey, String hostname) async {
    final port = await _channel.invokeMethod<int>('start', {
      'authKey': authKey,
      'hostname': hostname,
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
  Future<void> installWebViewProxy(int port) async {
    await _channel.invokeMethod('installWebViewProxy', {'port': port});
  }
}
