# tailscale_embed

Embed a [Tailscale](https://tailscale.com) node **inside** a Flutter app — no
system VPN profile, no Tailscale app on the device. The app becomes its own
tailnet device and can reach `*.ts.net` MagicDNS names and Tailscale IPs
(`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) transparently.

Extracted from [Tailarr](https://github.com/scs32/Tailarr), where this stack
has been running in production on iOS since July 2026.

## How it works

- **Go tsnet** (`go/main.go`), compiled with gomobile into
  `TailscaleEmbed.xcframework`, runs a persistent Tailscale node and a local
  HTTP CONNECT proxy on `127.0.0.1:<random port>`.
- A **MethodChannel plugin** (`ios/Classes/`) bridges start/ensure/stop.
- A global **`HttpOverrides`** installs a `findProxy` that sends tailnet
  destinations to the local proxy — capturing every `dart:io HttpClient` in
  the app (`package:http`, Dio, image loading, …) with **zero changes to
  request code**.
- **`TailscaleGuard`** re-checks node + listener health on launch/foreground
  (iOS reclaims sockets during suspension) behind a blocking overlay.
- MagicDNS names are resolved **on-device from the node's peer list** — the
  phone has no system MagicDNS, so the proxy does it itself.

## Usage

```dart
import 'package:tailscale_embed/tailscale_embed.dart';
import 'package:tailscale_embed/tailscale_embed_io.dart';

void main() {
  TailscaleEmbed.instance.configure(
    config: () => TailscaleConfig(
      enabled: mySettings.tailscaleEnabled,
      authKey: mySettings.tailscaleAuthKey, // tskey-auth-…, needed once
      hostname: 'myapp',
    ),
  );
  TailscaleHttpOverrides.install();
  runApp(MaterialApp(
    builder: (context, child) => TailscaleGuard(child: child),
    // ...
  ));
}
```

The node is **persistent** (`Ephemeral: false`): the auth key is needed
exactly once; the identity survives restarts like a normal device, so
single-use keys are fine. Use `TailscaleAuthKeys.typeError()` to reject
API tokens / OAuth secrets before dialing, and
`TailscaleAuthKeys.friendlyError()` to translate tsnet failures.

## Platforms

iOS only for now. `TailscaleBackend` is the extension seam for an Android
backend (gomobile `.aar`, or an FFI package) without touching consumers.

## Rebuilding the framework

The xcframework is checked in so consumers don't need a Go toolchain.
To rebuild (e.g. after bumping `tailscale.com`):

```sh
go/build.sh
```

**Gotcha:** gvisor must match tailscale's own go.mod pin — a newer gvisor
breaks `gomobile bind` with "found packages stack and bridge" errors.

## License

GPL-3.0 (originates from the Tailarr fork of LunaSea).
