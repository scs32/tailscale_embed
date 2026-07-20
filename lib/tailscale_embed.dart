/// Embed a Tailscale (tsnet) node inside a Flutter app.
///
/// This library is dart:io-free so it can be imported unconditionally
/// (including on web, where [TailscaleBackend.isSupported] is simply false).
/// The `HttpOverrides`/proxy-routing half lives in
/// `package:tailscale_embed/tailscale_embed_io.dart`.
library tailscale_embed;

export 'src/auth_keys.dart';
export 'src/backend.dart';
export 'src/config.dart';
export 'src/embed.dart';
export 'src/fake_backend.dart';
export 'src/guard.dart';
export 'src/method_channel_backend.dart';
export 'src/settings_panel.dart';
export 'src/status.dart';
