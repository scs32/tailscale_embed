/// dart:io half of tailscale_embed: tailnet host matching and the global
/// [HttpOverrides] that routes tailnet destinations through the embedded
/// node's local HTTP CONNECT proxy.
///
/// Import this only from dart:io platforms (mobile/desktop), typically via a
/// conditional import.
library tailscale_embed_io;

export 'src/overrides_io.dart';
