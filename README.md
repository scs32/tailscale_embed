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
  phone has no system MagicDNS, so the proxy does it itself. That includes
  bare **short names** (`truenas-ts`, not just
  `truenas-ts.tail1234.ts.net`): dotless hostnames are routed to the proxy,
  which resolves them from the peer list, or dials them directly via system
  DNS when they match no peer.
- The proxy carries **all** traffic, not just tailnet traffic: tailnet
  destinations (peer names, `100.64.0.0/10`, `fd7a:115c:a1e0::/48`) are
  dialed through tsnet, everything else through the system dialer. This
  lets a webview point at the proxy wholesale.
- **WKWebView support** (`webViewProxy: true`, iOS 17+): sets
  `WKWebsiteDataStore.proxyConfigurations` so webview traffic — which
  bypasses Dart's `HttpClient` entirely — also flows through the embedded
  node. Re-applied automatically on every start/rebind.
- **Subnet routes** (`acceptRoutes`, default true): destinations inside
  peer-advertised routes (e.g. `192.168.1.0/24` behind a subnet router)
  dial through the tailnet, so they work away from home too. At worst a
  same-LAN destination hairpins through its router; set
  `acceptRoutes: false` to dial LAN-looking IPs directly instead.
  Exit-node default routes (`0.0.0.0/0`) are never inferred.
- **Transactional restarts**: if a re-start with new settings fails (bad
  auth key, timeout), the plugin rolls back to the previously-working node
  instead of leaving the user with no tunnel.

## Installation

Not on pub.dev — add it as a git dependency:

```yaml
dependencies:
  tailscale_embed:
    git: https://github.com/scs32/tailscale_embed.git
```

That's the only step. The ~90MB prebuilt `TailscaleEmbed.xcframework` is not
in the repo (clones are tiny); it downloads automatically — SHA-256 verified
and cached — during `pod install` on the first iOS build. See
[The prebuilt framework](#the-prebuilt-framework) for details and the
offline from-source fallback.

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

The node is **persistent** by default (`ephemeral: false`): the auth key is
needed exactly once; the identity survives restarts like a normal device, so
single-use keys are fine. Pass `onKeyConsumed:` to `configure()` to be told
when the key has done its job — then **delete it from your settings store**
so a plaintext `tskey-auth-…` doesn't linger (the example app does this).
`TailscaleConfig` also exposes `ephemeral`, `upTimeout` (default 45s), and
`acceptRoutes`.

If your app ships a **baked-in default key** (zero-setup first run) instead
of keeping the key in mutable storage, use `isEnrolled(identity)` to decide
whether the key is still needed — once it returns true, stop supplying the
key — rather than inventing a key-was-consumed sentinel of your own.

### Applying settings changes

`restart()` is the one call an **Apply** button needs: it stops whatever
node is running and starts one from the provider's current config. That
covers both a settings change on the same identity (which `ensure()` would
ignore — the node is already healthy) and an identity switch, with the
usual rollback if the new config fails. `ensure()` remains the right call
for health checks (launch/foreground) and profile switches where nothing
else changed.

### Settings panel widget

`TailscaleSettingsPanel` is the whole settings UI ready-made: enabled
switch, per-identity auth key + hostname fields with key-type validation,
Apply with the right semantics (`restart()`/`stop()`), a connection status
line that shows self/peers, and the enrolled-identities list. It renders as
a plain `Column`, so it embeds in any page, and it re-reads the auth key
from your store after apply, so a key cleared by `onKeyConsumed` empties on
screen by itself.

Back it with your own storage by implementing `TailscaleSettingsStore`
(enabled, selected identity, per-identity key/hostname) over your
SharedPreferences/profile object — the package never owns storage. Pass
`showIdentity: false` when your app drives the identity from its own
profile switcher. See `example/lib/settings.dart` for a complete store.

### Multiple identities

`TailscaleConfig.identity` (default `'default'`) names the **node identity**
the config uses. Each identity keeps its own tailscaled state — its own
node, auth key, and possibly a different tailnet — so app-level profiles can
each be their own device on their own tailnet. The name is a logical label
(`[A-Za-z0-9][A-Za-z0-9._-]*`, max 64 chars — slugify free-form profile
names); the plugin owns the on-disk layout under
`Application Support/tailscale/identities/<name>/`.

- **Upgrades**: pre-identity installs kept a single node's state at
  `Application Support/tailscale/`. It is migrated **in place** to
  `identities/default` on first use (two atomic renames with crash
  recovery), so an existing node keeps its enrollment — no re-enroll, no
  new auth key.
- **Switching**: config is read at `start()`/`ensure()`. When the provider
  returns a different identity than the running node, the next `ensure()`
  (or `start()`) stops the running node and starts the new identity's —
  fresh enroll via that config's `authKey` if it has no state yet. Only one
  node runs at a time; `start`/`ensure`/`stop` are serialized, so an
  `ensure()` arriving mid-switch (e.g. `TailscaleGuard` on app resume)
  waits and then health-checks whichever identity won.
- **Rollback**: if a start on identity B fails (bad key, timeout), the
  previously running identity A is restarted — tunnel-up beats
  consistency. The error's `details` map carries `rolledBack` and
  `activeIdentity` (the identity actually running, or null).
- **Attribution**: `onKeyConsumed` receives the identity whose key was
  consumed (from the config the start actually used, so it's correct even
  if the provider switched mid-start). `status().identity` and
  `TailscaleEmbed.activeIdentity()` report the running identity.
- **Cleanup**: `listIdentities()` returns names that actually enrolled
  (have persisted node state); `isEnrolled(name)` asks about one.
  `deleteIdentity(name)` removes one (e.g. when its profile is deleted).
  Deleting the running identity fails with `IDENTITY_ACTIVE`.

### Status

`TailscaleEmbed.instance.status()` returns a `TailscaleStatus` snapshot for
settings pages and connection indicators: backend state, health warnings,
active identity, tailnet name / MagicDNS suffix, self node (hostname, DNS
name, IPs), and the peer list with per-peer online state and advertised
routes.

### Errors

Failures carry **stable error codes** end-to-end (emitted in Go, parsed into
`PlatformException.code`): `AUTH_TIMEOUT`, `AUTH_KEY_INVALID`,
`AUTH_KEY_WRONG_TYPE`, `START_FAILED`, `PROXY_BIND_FAILED`, `NOT_RUNNING`,
`IDENTITY_ACTIVE` — see `TailscaleErrorCodes`. Use `TailscaleAuthKeys.typeError()` to reject API
tokens / OAuth secrets before dialing, and
`TailscaleAuthKeys.friendlyError()` to translate failures for humans (it
prefers the codes, falling back to message text).

### Node identity and backups

The node key (its tailnet identity) lives in the app's Application Support
directory, which is **included in device and iCloud backups**. That is a
deliberate choice: restoring a backup restores the tailnet identity, so the
app reconnects without a new auth key. If that doesn't fit your threat
model, use `ephemeral: true` (no persisted identity, key required every
start) or exclude the `tailscale/` state directory from backups in your app.
With multiple identities, every enrolled identity's state is backed up.

### Testing consumers

`FakeTailscaleBackend` is an in-memory backend for widget/unit tests — no
MethodChannel, no device. Pass it to `configure(backend: …)` and the whole
facade (start/ensure/stop, identity switching, `onKeyConsumed`, status)
behaves like a node that always comes up. Knobs: `startError` (auth-failure
paths), `statusOverride` (peer lists, health), `enrolled` (pre-seeded
identities), plus `startedConfigs` recording for assertions. This package's
own `test/` uses it, including pumping `TailscaleSettingsPanel`.

## Example app

`example/` is a minimal **browser**: a WKWebView (`webview_flutter`) whose
traffic rides through the embedded node via `webViewProxy: true`. Paste an
auth key in its settings, then browse to MagicDNS names, `*.ts.net` FQDNs,
tailnet IPs — or the regular web, which the proxy dials directly.

```sh
cd example && flutter run
```

## Platforms

iOS only for now. `TailscaleBackend` is the extension seam for an Android
backend (gomobile `.aar`, or an FFI package) without touching consumers.

## The prebuilt framework

The xcframework is **not** in git — it's published on GitHub Releases and
fetched automatically at `pod install` time by `ios/download_framework.sh`,
checksum-pinned by `ios/Framework.lock`. Consumers need no Go toolchain and
no manual steps; the download is cached until the pin changes. Old release
assets must never be deleted — every commit's pin must stay downloadable.

To rebuild from source (offline fallback, or after bumping `tailscale.com`):

```sh
go/build.sh            # build + install locally (marks ios/.framework-local)
go/build.sh --publish  # also upload a new release + update Framework.lock
```

After `--publish`, commit the updated `ios/Framework.lock`.

**Gotcha:** gvisor must match tailscale's own go.mod pin — a newer gvisor
breaks `gomobile bind` with "found packages stack and bridge" errors.

## License

GPL-3.0 (originates from the Tailarr fork of LunaSea).
