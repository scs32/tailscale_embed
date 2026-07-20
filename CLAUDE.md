# tailscale_embed — session notes

## Plezy feedback session (2026-07-20, latest): drop-in DX gaps, v0.3.0

**State correction (verified at break time, same day):** commit `2c109c0`
IS on origin/main — committed and pushed, contrary to the "NOT yet pushed"
note below. What's actually still missing: the **`v0.3.0` git tag** (only
v0.2.0 exists) and the README install snippet still says `ref: v0.2.0` —
bump it when tagging. Then the Plezy relay (item 1 below).

Plezy (edde746/plezy, ~2900★ cross-platform Plex/Jellyfin client) integrated
v0.2.0 and filed 7 gaps. Gatekeeper triage (kept surface crisp): built the
pure-Dart / DX ones, deferred the big platform work. **No xcframework
rebuild** — all changes are Dart + docs. `flutter analyze` clean (pkg +
example), `flutter test` 23/23 green. Version bumped 0.2.0 → **0.3.0**
(additive API, non-breaking) in pubspec + podspec. NOT committed/pushed yet.

### What landed
- **Gap 2 — proxy-port listenable (highest ROI):** `TailscaleEmbed.instance
  .proxyPortListenable` (`ValueListenable<int?>`), fires on start/rebind/stop.
  `_proxyPort` is now a `ValueNotifier`. The missing primitive for anything
  that *bakes in* the port (native URLSession/OkHttp, loaded libmpv,
  AVPlayer/ExoPlayer) vs. `findProxy` which reads it live.
- **Gap 1 — client-agnostic CONNECT wrapper:** new opt-in entrypoint
  `lib/tailscale_embed_http.dart` → `TailscaleClient(inner)` (an
  `http.BaseClient`). Tailnet hosts (incl. short names) route via an internal
  `dart:io` `IOClient`+`findProxy`; everything else delegates to `inner`, so
  apps keep their native client (cupertino_http/cronet_http/win_http) for
  public traffic. Design choice: delegate, do NOT hand-roll CONNECT/TLS.
  **Rejected** the native per-client proxy-factory sub-request (too much
  per-platform native surface). Added `http: >=0.13.0 <2.0.0` dep (core never
  imports it). Corrected the false "http & Dio just ride dart:io → zero
  changes" README claim.
- **Gap 4 — tvOS isSupported (correctness bug):** tvOS reports as
  `TargetPlatform.iOS` but the plugin isn't registered → was throwing
  MissingPluginException. No web-safe sync tvOS signal exists, so:
  `MethodChannelTailscaleBackend` now catches MissingPluginException on the
  first call, latches a static `_pluginMissing`, `isSupported` then returns
  false, lifecycle probes (isRunning/status/listIdentities/ensure) degrade to
  quiet no-ops, and an explicit start() throws the new stable
  `UNSUPPORTED` code (`TailscaleErrorCodes.unsupported` + friendlyError).
- **Gap 7 — `SingleIdentityTailscaleStore`** (in settings_panel.dart): pure
  base collapsing the per-identity store API to three plain pairs
  (enabled/authKey/hostname), identity pinned to 'default'. No dep. **Did NOT**
  ship a SharedPreferences concrete store (would break "package owns no
  storage" + add a dep) — kept it opt-in-only-if-ever.
- **Docs (Gaps 3 & 6):** README gained "Routing native HTTP clients"
  (TailscaleClient), "Routing native media players" (mpv `http-proxy` recipe +
  proxyPortListenable rebind + ffmpeg-resolves-proxy-side note), and "Client
  lifetime and enabling mid-session" (live-port vs baked-in ordering).
  Platforms section now documents the no-op-everywhere + tvOS behavior and
  flags Android/macOS as the top roadmap item.
- **Tests:** +proxyPortListenable, +SingleIdentityTailscaleStore,
  +unsupported-platform latch (needs `TestWidgetsFlutterBinding
  .ensureInitialized()` + `debugDefaultTargetPlatformOverride`), new
  `test/tailscale_client_test.dart` (routing/delegation/close via MockClient).

### DEFERRED — Gap 5 (Android + macOS backends): the real "drop into anything"
unlock, but a project not a task (gomobile .aar + Kotlin plugin + proxy
lifecycle; macOS own build; multiplies the dist/CI story). Top roadmap item.

### Next session, in order
1. **Commit + push** this work (branch off main; nothing pushed yet), tag
   `v0.3.0`. Then relay to Plezy: adopt `proxyPortListenable` (players),
   `TailscaleClient` (their cupertino_http/cronet_http path), drop the tvOS
   onError workaround, optionally `SingleIdentityTailscaleStore`.
2. Still-open older item: **real-key end-to-end** (needs user's fresh
   `tskey-auth-…` × 2) — sim `ts-browser-test`
   (9540842C-9F8C-4482-B159-85E4B2BC967C) still exists. Also the untested
   real-device short-name/system-DNS-fallback smoke test from Tailarr.
3. Gap 5 when there's appetite for a multi-session platform push.

## Distribution session (2026-07-20): GH Releases + history purge, PUSHED

Backlog item 2 (framework distribution) is DONE. Repo history was rewritten
(git filter-repo --strip-blobs-bigger-than 10M) and force-pushed: `.git`
went 180MB → ~134KB. **All commit hashes before this session changed** —
any other checkout, and any Tailarr pubspec.lock pinning an old hash, must
re-clone / re-resolve.

### How it works now
- xcframework is NOT in git. `ios/download_framework.sh` fetches the zip
  pinned in `ios/Framework.lock` (TAG/ZIP/SHA256) from GitHub Releases,
  verifies SHA-256, caches via `ios/.framework-tag`.
- The podspec runs the script at **podspec-eval time** (top of the file).
  NOT prepare_command (skipped for development pods = all Flutter plugins)
  and NOT script_phase (the earlier design — too late: CocoaPods needs the
  .xcframework at pod-install time for slice selection/linking). This was
  the one deviation from the previously decided design.
- `go/build.sh` = build from source + install locally, writes
  `ios/.framework-local` so the download script won't clobber it.
  `go/build.sh --publish` = also zip, `gh release create` under an
  immutable tag `framework-v<ts-version>[-N]` (never reuses a tag), and
  rewrite Framework.lock → commit it. One command, no manual ritual.
- **NEVER delete old release assets** — every historical commit's pin must
  stay downloadable. Current release: `framework-v1.92.5` (created against
  post-rewrite main so the tag doesn't resurrect purged history).

### Verified this session
Standalone download, cache no-op, checksum-mismatch refusal (exit 1), and
the real path: framework deleted + Pods/Podfile.lock wiped → `flutter build
ios --simulator` in example/ downloads during `pod install` and builds.
`flutter test` 16/16 green.

### Tailarr feedback round 3 (2026-07-20, same day): all landed
Tailarr build 8 shipped on the new pipeline (CI + local pod install both
downloaded/verified framework-v1.92.5 first try; bump from efc0e02-era to
39b8afd needed zero Dart changes). Its four suggestions implemented here:
- **Semver tags**: version 0.2.0 (pubspec + podspec), tag `v0.2.0` pushed.
  Policy in README: consumers pin `ref: v<version>`, not hashes/main;
  pre-1.0 breaking API = minor bump; tag on every Dart API change.
- **Cache-hit log line** in download_framework.sh (provenance always
  visible in CI, not just on first download).
- **`.github/workflows/framework-assets.yml`**: weekly + manual; walks
  EVERY historical version of ios/Framework.lock in git history and
  re-downloads + SHA-256-verifies each pinned asset — enforces the
  "never delete old release assets" rule before a consumer breaks.
- **Pub-cache caveat** in README: framework lives inside the pub-cache git
  checkout; `dart pub cache repair`/cache clean silently drops it; next
  pod install re-downloads.
Outstanding from that feedback: relay Stephen's real-device short-name
smoke test (`http://truenas-ts/` on build 8) back here — it's the first
real-device exercise of the short-name fix; the system-DNS-fallback half
is the untested part.

### Next session, in order
1. Real-key end-to-end (unchanged — see feedback-round-2 notes below):
   needs user's fresh `tskey-auth-…` × 2. Sim `ts-browser-test`
   (9540842C-9F8C-4482-B159-85E4B2BC967C) still exists.
2. Tailarr side: remaining adoption is optional DX (restart(),
   isEnrolled, settings panel/store seam, FakeTailscaleBackend in its
   tests) + surfacing status() in Settings > Network. Its next bump
   should switch to `ref: v0.2.0` style pins.

## Feedback round 2 (2026-07-19): DX items landed & PUSHED

Four Tailarr consumer-feedback items implemented, tested, committed
(`0f2d0a5`) and pushed to github.com/scs32/tailscale_embed main —
consumable by Tailarr now. Session ended cleanly; nothing uncommitted.

### Next session, in order
1. Real-key end-to-end (unchanged, needs user's fresh `tskey-auth-…` × 2):
   enroll `default` + a second identity, switch via list + Apply (now via
   the package panel), `status().identity` tracks, key field self-empties,
   IDENTITY_ACTIVE on deleting active. Browse `*.ts.net` + public site +
   subnet-route IP. Bonus now: browse `http://truenas-ts/` (bare short
   name) from the example to verify item-2 end-to-end. Sim
   `ts-browser-test` (9540842C-9F8C-4482-B159-85E4B2BC967C) still exists.
2. Framework distribution via GitHub Releases + script_phase (design
   already decided — see "Maintainer session" item 3 below). Do before
   Tailarr bumps.
3. Tailarr side (grew this session): per-profile TAILSCALE_* fields,
   `identity: <profileSlug>`, `ensure()` on profile switch,
   `onKeyConsumed(identity)` (BREAKING signature), PLUS adopt
   `restart()` (delete copied apply logic), `isEnrolled()` (delete
   `ts_key_consumed` sentinel), `TailscaleSettingsPanel`/store or at
   least the panel's store seam, and `FakeTailscaleBackend` for its
   widget tests.

### What landed (summary — details in commit 0f2d0a5)

1. **`TailscaleSettingsPanel`** (`lib/src/settings_panel.dart`) + abstract
   `TailscaleSettingsStore` (per-identity key/hostname; consumer owns
   storage) + `TailscaleEmbed.restart()`. Key insight: the example's
   "subtle apply logic" (ensure-vs-stop/start branch) was never needed —
   native start already stops the running node first, so `restart()`
   (≡ start) covers same-identity config changes AND identity switches.
   Example settings page refactored onto the panel (~20 lines now).
   `showIdentity: false` hides identity UI for profile-driven apps.
2. **Bare short names** (`truenas-ts`): Go `matchNode` already resolved
   them — the footgun was Dart-side; `tailscaleFindProxy` now routes
   dotless non-IP hosts to the proxy (`isPossibleTailnetShortName`),
   which resolves from peers or dials direct via system DNS. Pure Dart,
   NO xcframework rebuild.
3. **`isEnrolled(identity)`** on embed + backend seam (derived from
   `listIdentities`). Swift `listIdentities` now requires
   `tailscaled.state` (failed-start residue dirs no longer count) —
   that's what makes it trustworthy for baked-in-key apps (kills
   Tailarr's `ts_key_consumed` sentinel).
4. **`FakeTailscaleBackend`** (exported) + first `test/` suite: 11 unit +
   5 panel widget tests, `flutter test` green, analyze clean both.

**Gotchas learned** (test-infra, worth remembering):
- `pumpAndSettle` never settles after `enterText` — focused field's
  cursor-blink timer reschedules frames forever. Use `pump()`.
- The old `_serial = Future.value()` singleton field pinned all
  serialized ops to the zone that FIRST touched `TailscaleEmbed.instance`
  (Dart runs a future's listeners on the future's own zone). With
  `configure()` in test `setUp` (real zone), `testWidgets` FakeAsync
  could never complete `start()` → 10-min timeouts + cross-test hangs.
  Fixed in `_serialized`: chain is nullable, ops run in caller's zone
  when idle, resets to null when drained. Tailarr consumers configuring
  in setUp would have hit this.

Still outstanding from previous backlog: real-key end-to-end (item 1
below), framework distribution via GH Releases (item 2), Tailarr-side
adoption (item 3 — now also: adopt the panel or at least `restart()`,
`isEnrolled`, drop slugified short-name docs caveat).

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
