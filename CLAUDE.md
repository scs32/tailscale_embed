# tailscale_embed — session notes

## Browser example session (2026-07-19) — PAUSED, uncommitted

Goal: prove the embedded-Tailscale stack in a minimal browser app before
forking bigger apps (e.g. Immich) around it.

### Done (all uncommitted on main — review `git diff` / untracked `example/`)
- **go/main.go**: proxy now routes tailnet destinations (peer-list matches,
  100.64.0.0/10, fd7a:115c:a1e0::/48) via tsnet and dials everything else
  directly — so a webview can send it ALL traffic. New `dial()` helper;
  `resolveTailnet` returns `(dest, viaTailnet)`.
- **xcframework rebuilt** (go/build.sh) with that change and checked in place.
- **Plugin**: new `installWebViewProxy` method — Swift sets
  `WKWebsiteDataStore.default().proxyConfigurations` (iOS 17+) to the local
  CONNECT proxy. Dart: `TailscaleBackend.installWebViewProxy(port)` (no-op
  default) + `webViewProxy: true` flag on `TailscaleEmbed.configure()` that
  auto-reapplies after every start/ensure (port changes on iOS rebind).
- **example/**: browser app (`tailscale_browser`, org com.tailarr) —
  `main.dart` (configure + TailscaleGuard), `browser_page.dart`
  (webview_flutter, URL bar guessing http:// for tailnet-looking hosts /
  https:// otherwise, connection dot, last-URL restore), `settings.dart`
  (SharedPreferences: enabled/authKey/hostname + settings page with
  TailscaleAuthKeys validation).
- README updated (all-traffic proxy, webViewProxy, example app).

### Verified
- `go vet` + `go build` clean; `flutter analyze` clean.
- `flutter build ios --simulator` succeeded (Runner.app builds and links).

### Remaining
1. **First**: have the maintainer session review + commit the uncommitted
   work — paste `HANDOFF.md` into a session in this repo. It also carries
   the improvement backlog (status API, structured errors, peer cache,
   shared transport, transactional start, Go tests, subnet-route routing).
2. Boot example in a simulator, confirm launch UI (was interrupted — a
   Tailarr e2e run owned the machine; the temp sim was deleted to save
   disk. Recreate:
   `xcrun simctl create ts-browser-test com.apple.CoreSimulator.SimDeviceType.iPhone-16-Plus com.apple.CoreSimulator.SimRuntime.iOS-26-5`).
   App is prebuilt at `example/build/ios/iphonesimulator/Runner.app`.
3. Real verification on device/sim with a fresh `tskey-auth-…` key: enable in
   settings, browse to a `*.ts.net` host AND a public site (tests both proxy
   paths). WKWebView proxying needs iOS 17+.
4. Then: back to the original goal — fork apps (e.g. Immich) around this
   package from a separate consumer session.

### Gotchas
- gvisor must match tailscale.com's go.mod pin or `gomobile bind` breaks.
- `WKWebsiteDataStore.proxyConfigurations` is iOS 17+; plugin returns
  UNSUPPORTED below that.
- Only tailnet CIDR/peer-name destinations go via tsnet — subnet-routed LAN
  IPs (e.g. 192.168.64.x via the Mac's subnet router) currently dial DIRECT,
  not through the tailnet. Extend `isTailnetIP`/route handling if needed.
