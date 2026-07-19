# tailscale_embed — session notes

## Multi-identity session (2026-07-19, later): identities landed & pushed

Tailarr's feature request implemented, committed (`efc0e02`) and PUSHED to
github.com/scs32/tailscale_embed main — ready for Tailarr to consume as a
git dep. Session ended cleanly: example app uninstalled from the sim,
`ts-browser-test` shut down (reuse it for real-key testing).

### Next session, in order
1. Real-key end-to-end (needs user's fresh `tskey-auth-…` × 2): enroll
   `default`, then a second identity (`work`, same tailnet fine —
   hostname auto-defaults to `ts-browser-work`), switch between them via
   the enrolled-identities list + Apply, confirm `status().identity`
   tracks, key field self-empties (onKeyConsumed), deleting the active
   identity errors IDENTITY_ACTIVE. Also still outstanding from the
   previous backlog: browse a `*.ts.net` host + a public site, subnet
   route hit.
2. Framework distribution (GitHub Releases + script_phase, decided
   earlier — see previous session's item 3): the push warned GH001 large
   files for the two ~90MB xcframework binaries; do this before Tailarr
   bumps multiply clone cost.
3. Tailarr side: per-profile TAILSCALE_* fields, `identity: <profileSlug>`
   (slugify! names are validated `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`),
   `ensure()` on profile switch, adopt `onKeyConsumed(identity)`
   (signature is BREAKING vs the old zero-arg one).

### What landed (detail)

- `TailscaleConfig.identity` (default `'default'`): logical label
  (`[A-Za-z0-9][A-Za-z0-9._-]{0,63}`), validated in Swift; the plugin owns
  the layout `AppSupport/tailscale/identities/<name>/`.
- **Legacy migration** (chosen over mapping default→legacy path): the old
  single state dir at `AppSupport/tailscale/` is moved in place to
  `identities/default` — two atomic renames via a `tailscale.migrating`
  marker (crash between them is recovered on the next call). Triggered from
  stateDirectory/list/delete. Rationale: uniform layout keeps list/delete
  trivial, no permanent special case.
- **Switch**: `ensure()` compares `backend.activeIdentity()` (new channel
  method `getActiveIdentity`) with the provider's identity; mismatch →
  `start()` (native start already stops the running node first).
  `TailscaleEmbed` now serializes start/ensure/stop/deleteIdentity through
  a `_serialized()` future chain — an ensure arriving mid-switch waits,
  then health-checks whichever identity won.
- **Rollback**: failed start on B restarts A (lastGoodConfig carries the
  identity; its state dir is recomputed). Error `details` =
  `{rolledBack, activeIdentity}` (NSNull when nothing running).
- **onKeyConsumed** is now `void Function(String identity)` (BREAKING);
  fires with the identity from the config the start actually used.
- `status().identity` (Go `SetIdentity` + StatusJSON, present even when
  not running), `activeIdentity()`, `listIdentities()`,
  `deleteIdentity(name)` (IDENTITY_ACTIVE when running; new code in
  TailscaleErrorCodes + friendlyError).
- Example: per-identity authKey/hostname prefs (default keeps legacy pref
  keys), identity field + enrolled-identities list (tap = select, trash =
  delete), Apply uses `ensure()` when switching identities.
- xcframework rebuilt; `go test` green, `flutter analyze` clean (both),
  sim-verified WITHOUT real keys: legacy migration (seeded fake
  `tailscaled.state` moved to `identities/default`), listIdentities,
  per-identity settings, deleteIdentity. Real-key items are "Next
  session" item 1 above.

### Coordination
- **Tailarr** consumes multi-identity in its next plugin bump alongside
  onKeyConsumed adoption (per-profile TAILSCALE_* fields, passes
  `identity: <profileSlug>`, calls `ensure()` on profile switch; maps its
  old global settings to the `default` profile — which is why default maps
  to the legacy state).

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
3. **Framework distribution** (decided, not yet built): move the ~92MB×2
   xcframework binaries out of git and fetch at build time.
   - `go/build.sh` gains a `gh release create` step: zip the xcframework +
     SHA-256, tag `framework-v<tailscale version>` on GitHub Releases.
   - Podspec downloads via a CocoaPods `script_phase` (before compile) with
     checksum pinning — NOT `prepare_command` (skipped for development
     pods, which Flutter plugins are). Cache after first build.
   - Repo keeps Go source + pinned version/checksum + download script;
     `go/build.sh` stays the offline from-source path.
   - Rejected: Git LFS (consumers without git-lfs get pointer files via
     `dart pub` git deps + bandwidth quotas); pub.dev (100MB compressed
     limit too close).
   - Optional while sole consumer: `git filter-repo` to purge the two big
     blobs already in history (force-push decision).

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
