# tailscale_embed — session notes

## Maintainer session (2026-07-19): backlog worked, all committed

The browser-example integration work AND the resulting improvement backlog
are done and committed on main (through `fcd9c2d`). HANDOFF.md (untracked)
was the input to this session and is now fully processed/stale.

### Landed this session
- Committed the prior session's work: all-traffic proxy routing, WKWebView
  proxy support (`webViewProxy: true`, iOS 17+), `example/` browser app.
- **Status API**: Go `StatusJSON()` → `TailscaleEmbed.instance.status()` →
  `TailscaleStatus`/`TailscaleNode` (backend state, health, tailnet, self,
  peers with online + advertised routes).
- **Stable error codes**: Go prefixes errors `tsembed:CODE:`; Swift parses
  into `FlutterError.code`; Dart `TailscaleErrorCodes` +
  `friendlyError()` prefers codes, substring match is fallback only.
- **Status cache**: `LocalClient().Status()` cached 3s (was per-dial).
- **Shared transport** for plain-HTTP proxying; proxy now relays redirects
  (`ErrUseLastResponse`) instead of following them.
- **Config**: `TailscaleConfig` gains `ephemeral`, `upTimeout` (45s
  default), `acceptRoutes`. BREAKING for custom backends:
  `TailscaleBackend.start(TailscaleConfig)` replaces `(authKey, hostname)`.
- **Subnet routes** (decision made): destinations inside peer-advertised
  routes dial via tsnet by default (`acceptRoutes: true`; RouteAll enabled
  after Up). Always correct remotely; hairpins at home. 0/0 exit-node
  routes deliberately never inferred.
- **Rollback start**: Swift keeps the last good config; a failed re-start
  (bad key etc.) restarts the previous identity instead of leaving no
  tunnel. Error details carry `rolledBack: true`.
- **onKeyConsumed**: `configure(onKeyConsumed:)` fires after a successful
  start with a key on a persistent node → app deletes the plaintext key
  (example does this).
- **Go unit tests** (`go/main_test.go`): isTailnetIP, routesCover,
  matchNode, classifyUpError, resolveTailnet IP literals. `go test ./...`
  passes.
- README: all of the above + node-identity-in-backups semantics (J).
- xcframework rebuilt with the new Go API; `flutter analyze` clean (pkg +
  example); `flutter build ios --simulator` succeeds.
- Example launch UI **verified in simulator** (screenshot: landing page +
  URL bar render correctly). Sim `ts-browser-test`
  (9540842C-9F8C-4482-B159-85E4B2BC967C, iPhone 16 Plus / iOS 26.5) exists,
  shut down — reuse for real-key testing or `simctl delete` it.

### Remaining
1. Real end-to-end verification with a fresh `tskey-auth-…` key (needs the
   user): enable in example settings, browse a `*.ts.net` host AND a public
   site (both proxy paths), confirm status line shows self/peers, confirm
   the key field empties (onKeyConsumed). Bonus: hit a subnet-routed LAN IP
   (e.g. 192.168.64.x via the Mac's `apple-container` subnet router) to
   exercise acceptRoutes.
2. Then: back to the original goal — fork apps (e.g. Immich) around this
   package from a consumer session.

### Gotchas
- gvisor must match tailscale.com's go.mod pin or `gomobile bind` breaks
  ("found packages stack and bridge").
- `WKWebsiteDataStore.proxyConfigurations` is iOS 17+; plugin returns
  UNSUPPORTED below that.
- gomobile imports `StatusJSON() (string, error)` into Swift as
  `statusJSON(_ error: NSErrorPointer) -> String` (nonnull return blocks
  the throws transform) — not `throws`.
- Two tsnet instances can't share the state dir — that's why re-start is
  stop-then-start with rollback, not start-then-swap.
