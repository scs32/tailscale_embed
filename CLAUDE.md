# tailscale_embed — session notes

## Dual-agent review + fix-bundle session (2026-07-28, latest): v0.3.7 → v0.3.8 → v0.3.9

### v0.3.9 — second self-review round found one more (generation-scope the tunnel latch)
Re-reviewed the v0.3.8 diff with BOTH agents (the "did my fix regress?" pass, per
[[self-review-shipped-diff]]). Fable cleared it; **Codex caught a real MEDIUM
Fable missed**: the v0.3.8 `tunClosed` latch was global, not scoped to a proxy
lifetime. A CONNECT handler descheduled right before `registerTunnel` could
survive a full stop→start (which cleared the global latch via `openTunnels`) and
register into the NEW lifetime's registry — the leak the latch was meant to stop,
one boundary over.

**Fix (Go-only, framework rebuild):** per-lifetime **generation**. `tunGen uint64`
under `tunMu`; `openTunnels()` bumps it and returns the new value; `StartProxy`
captures `gen := openTunnels()` BEFORE building `t.proxy` and wraps the handler in
a closure carrying that gen; `handleProxy`/`handleConnect` thread it;
`registerTunnel(p, gen)` rejects if `tunClosed || gen != tunGen`. Both conditions
are load-bearing: `tunClosed` catches the same-lifetime stop race (gen would
still match), the gen check catches the cross-lifetime straggler. `EnsureProxy`
(reuses the same `t.proxy`/closure) and `restartServer` (doesn't rebuild the
proxy) correctly keep the current gen, so healthy live traffic is never rejected;
`StartProxy` is the ONLY `openTunnels` caller. Lock order unchanged (`t.mu` →
`tunMu`, no inversion).

**Then re-reviewed the generation fix itself with both agents → BOTH said SHIP.**
Fable re-ran the extended `TestCloseTunnels` under `-race` (drives
openA→register→close→register(A rejected)→openB→register(A rejected)/register(B
ok)); Codex traced every lifecycle caller. No regressions, healthy traffic not
rejected, uint64-overflow/gen-0 not real hazards.

**Verified (v0.3.9):** `go vet` + `go test -race` green; `flutter analyze` clean
(Dart unchanged, 35 tests); example `flutter build ios --simulator` links the
rebuilt framework; published asset re-downloaded + SHA256-verified.

**Released (v0.3.9):** pubspec + podspec 0.3.9, framework **`framework-v1.92.5-9`**
(Framework.lock SHA256
`77ed155e5c47a4e7c6c009c6d86c17348b9ac14c17f7c7cea6fe81dec62fe3ab`), README
`ref: v0.3.9`. Consumers pin
`ref: v0.3.9` (supersedes v0.3.7/v0.3.8 — same feature set, tunnel registry now
lifetime-correct).

**Loop discipline that paid off:** the user asked to keep looping review→fix→
re-review with BOTH agents until both say ship. Round 1 (v0.3.7 forward review)
found the fix bundle; round 2 (self-review) found 2 StopProxy holes → v0.3.8;
round 3 (self-review of v0.3.8) found the cross-lifetime latch → v0.3.9; round 4
(review of the generation fix) → both SHIP. Each round caught something the prior
couldn't. Codex twice found the subtler lifetime race Fable missed; Fable twice
proved fixes by execution Codex couldn't run (read-only). Running both and
requiring unanimous SHIP is the process worth keeping.

### v0.3.8 — self-review of the v0.3.7 diff (both agents)

### v0.3.8 — self-review of the v0.3.7 diff (both agents, again)
After shipping v0.3.7 I ran the SAME two agents (Fable 5 subagent + Codex CLI)
adversarially over **the v0.3.7 diff itself** ("find regressions I introduced").
Both **independently converged on the same two real holes in my own StopProxy
changes** — strong signal, not noise — plus Codex added a third (a race the
STATUS_UNAVAILABLE change opened). All three were fixed in v0.3.8 (Go-only, so a
framework rebuild; no Dart/Swift change):

1. **[both] Plain-HTTP streams outlived stop.** The new tunnel registry closes
   only *hijacked CONNECT* conns; `handleHTTP` streams are ordinary handlers that
   `proxy.Shutdown` doesn't force-close — and v0.3.7 removed the `WriteTimeout`
   that used to reap them. A long plain-`http://` download to a *direct* (non-
   tailnet) host would keep its handler/fd/upstream conn alive past an identity
   switch. Fix: `if err := t.proxy.Shutdown(ctx); err != nil { t.proxy.Close() }`
   in StopProxy (force-close the graceful-timeout remainder). Fable verified by
   probe; Codex confirmed against net/http source.
2. **[both] register-after-closeTunnels race.** A CONNECT that hijacked+registered
   in the window AFTER `closeTunnels()` nil'd the map resurrected it with a
   tunnel no stop ever closed (Codex sharpened: a handler blocked in `dial`
   during stop registers after the sweep). Fix: `tunClosed` latch under `tunMu`
   — `registerTunnel` now returns bool, rejects+signals-caller-to-close when
   closing; `openTunnels()` re-arms it in StartProxy; handleConnect closes both
   conns and abandons the relay on a false return.
3. **[Codex] STATUS_UNAVAILABLE mislabeled a stop race.** A `status()` that fails
   *because StopProxy closed the server* between the top `IsRunning()` check and
   the call now (v0.3.7) read STATUS_UNAVAILABLE instead of the old NOT_RUNNING.
   Fix: on status error, recheck `IsRunning()` → NOT_RUNNING if now stopped, else
   STATUS_UNAVAILABLE.

Everything else in the v0.3.7 diff (#3–#10: half-close, bufrw drain,
healthNeedsRebind inversion, hop-by-hop strip, rollback-port propagation across
StandardMessageCodec, best-effort webview, stop() finally) **both agents cleared
explicitly** — half-close direction correct, bufrw drain preserves byte order
(Fable probed both), Swift bool/int survive the channel as Dart bool/int, no
lock inversion in the registry.

**Verified (v0.3.8):** `go vet` + `go test -race` green (TestCloseTunnels
extended: late-register rejected+map-not-resurrected, openTunnels re-arms);
`flutter analyze` clean (Dart unchanged, still 35 tests); example
`flutter build ios --simulator` links the rebuilt framework; published asset
re-downloaded + SHA256-verified.

**Released (v0.3.8):** pubspec + podspec 0.3.8, framework
**`framework-v1.92.5-8`** (Framework.lock SHA256
`070698ec8cec88d6d3b95ea244b84f30b5d99e369a4d11425fb1c4116b54c81f`), README
`ref: v0.3.8`. Consumers pin `ref: v0.3.8` (supersedes v0.3.7 — same feature
set, StopProxy lifecycle now leak-tight).

**Process note worth keeping:** reviewing your OWN just-shipped diff with the
same adversarial agents caught two real leaks the forward review couldn't (they
were regressions the fix *introduced*). The self-review round is cheap and paid
off — do it whenever a fix touches a concurrency/lifecycle path.

### v0.3.7 (the forward-review bundle)

**Ran two adversarial code reviews (Fable 5 subagent + Codex CLI) with a
defensive-maintainer prompt, then fixed the bundle both converged on.** The
prompt was framed as hardening my own package (trust model spelled out: single
tenant, loopback proxy, my-own-bugs not malicious-caller) — neither agent
refused. Both independently surfaced the same **NEW High** nobody had flagged,
which anchored the release.

### Reviews (both engaged, cross-validated)
- **Fable 5** ran the full toolchain green + wrote throwaway Go probes to prove
  findings by *execution*. **Codex** (read-only sandbox, couldn't run tests)
  verified by reading + checked the health-string scope against the cached
  tailscale v1.92.5 source. Prompts saved in the session scratchpad.
- **Headline NEW High (both):** proxy `ReadTimeout`/`WriteTimeout = 30s` armed a
  whole-request write deadline on the non-hijacked path, so any plain-`http://`
  transfer >30s (libmpv playback, background_downloader, large media) was killed
  mid-body with a truncated EOF. CONNECT is hijacked so it was invisible — which
  is why it never got pinned in the field. Fable *reproduced it* (died at exactly
  the timeout); Codex found it by reading.
- **Codex-only NEW Medium:** `healthNeedsRebind` matched any `magicsock`+`not
  running`, which also catches **ReceiveDERP** → pointless UDP-rebind churn every
  interval + inflated the recovery telemetry the #1 roadmap decision gates on.

### What shipped in v0.3.7 (Go framework rebuild + Swift + Dart)
Go (`go/main.go`, needs the framework rebuild):
1. **Timeouts**: dropped `ReadTimeout`/`WriteTimeout`; now `ReadHeaderTimeout:30s`
   + `IdleTimeout:90s` (slow-loris isn't in the loopback trust model).
2. **Hijacked-tunnel registry** (`connPair`/`tunnels`/`tunMu`): register in
   `handleConnect`, `closeTunnels()` in `StopProxy` so directly-dialed CONNECT
   tunnels + their goroutines/fds don't outlive the node across switch churn
   (tracked #4). Plus **half-close** (`halfClose` → `CloseWrite` after each copy
   dir, so a peer waiting for EOF can't hang the relay) and **bufrw drain**
   (forward bytes a client pipelined after CONNECT — Fable NEW, was a silent
   per-conn handshake hang).
3. **healthNeedsRebind** now requires `receiveipv4`/`receiveipv6` explicitly (not
   DERP) — Codex NEW.
4. **STATUS_UNAVAILABLE** new code: a running node whose `Status()` momentarily
   fails no longer codes `NOT_RUNNING` (was flashing status UIs "disconnected").
   Added to Dart `TailscaleErrorCodes` + `friendlyError`.
5. **Hop-by-hop header strip** on the plain-HTTP path (`removeHopHeaders`).

Swift (`ios/Classes/…`, compiled by the consumer, no framework rebuild):
6. **Rollback port propagation** (tracked #2): rollback rebinds the proxy on a
   fresh port; details now carry `proxyPort`.

Dart (`lib/src/embed.dart`):
7. `_start` catches the rollback `PlatformException` and **re-adopts the rollback
   port** before rethrowing (was advertising the dead pre-switch port → silent
   per-profile connectivity loss until next ensure()).
8. `_adoptPort` makes the **webview-proxy install best-effort** (tracked #5): an
   iOS<17 UNSUPPORTED no longer fails an otherwise-healthy start / strands
   `onKeyConsumed`.
9. `stop()` nulls `_proxyPort` in a **`finally`** (don't keep advertising a dead
   port if native stop threw).

**Verified:** `go vet` + `go test -race` green (+4 Go tests: DERP-exclusion,
closeTunnels, halfClose, removeHopHeaders); `flutter analyze` clean; `flutter
test` **35/35** (+2: rollback-port adoption, webview-fail-doesn't-break-start);
example `flutter build ios --simulator` links the rebuilt framework. Published
asset re-downloaded + SHA256-verified against the lock.

**Released:** version 0.3.7 (pubspec + podspec), framework
**`framework-v1.92.5-7`** (Framework.lock SHA256
`94322f6af3ce22736eecc99f6aa7ad80be14d3c122ab3e469ce9310164bbd9a1`). README
`ref: v0.3.7`, rollback doc notes the port re-adoption.

### Explicitly NOT bundled (still open / deferred)
- **Tracked #1 (queue poisoning / native `Up()` cancellation)** — both agents
  confirmed the exact mechanics (guard frees UI at 60s, queue stays poisoned).
  Still the big native change, still telemetry-gated. Unchanged.
- **Main-thread block on `isRunning()` during a ~45s `Up()`** (Codex sharpened
  tracked #6/#11): a status poll / NWPathMonitor callback blocks on Go's `t.mu`
  which `StartProxy` holds across `Up()`. Real, but its own focused
  Swift+Go change (needs a starting/stopping state machine or off-main
  discipline) — not a while-I'm-here fix. Left in backlog.
- **Rebind-races-stop telemetry noise** (tracked #9): a stop-racing rebind can
  tick `recordRebind` on a dead node — cosmetic, noted for when #1 is scoped.

### Next session, in order
1. **Await Tailarr's v0.3.7 pickup** — they re-pin `ref: v0.3.7`, rebuild (one
   build = timeout fix + tunnel-leak fix + rollback-port fix + telemetry
   cleanup). Soak: the 30s plain-HTTP truncation should be gone; `restarts`
   stays 0; DERP-only warnings no longer bump `rebinds`.
2. Telemetry green-light for tracked #1 native `Up()` cancellation (see
   `magicsock-receiveipv4-*` memories); if scoped, fold in #4-native + the
   main-thread `t.mu`/`Up()` block.
3. Real-key end-to-end (unchanged; needs user's fresh `tskey-auth-…` × 2). Sim
   `ts-browser-test` (9540842C-9F8C-4482-B159-85E4B2BC967C) still exists.
4. Follow up on Plezy adoption of v0.3.0 reply (not yet confirmed landed).
5. Gap 5 ("Android + TV input", incl. QR/pairing auth) — top roadmap item.

## Guard lockup + adversarial-review session (2026-07-26): v0.3.6

**Fixed the consumer-reported app-wide lockup** (Tailarr build 18: a
Delete-Profile dialog over server-owned profiles froze all input, screen
frozen underneath, across tailnets — `~/projects/build18-lockup-profiles-delete.jpg`).
Root cause in `lib/src/guard.dart`: `_TailscaleGuardState` rendered a
full-screen `AbsorbPointer` whenever `_connecting`, set around `embed.ensure()`
and reset only in that call's `finally` — with `if (_connecting) return;` also
blocking retries. A hung `ensure()` (node wedged in Starting after a burst of
serialized ensure/stop/deleteIdentity, or an across-tailnet switch) pinned the
overlay forever. No timeout, no escape.

**Fix (Dart-only, no xcframework rebuild — Framework.lock stays
`framework-v1.92.5-6`):**
- `connectTimeout` (default 60s, > native upTimeout ~45s): hard ceiling via
  `.timeout()`; on elapse overlay clears + input returns, ensure() keeps coming
  up in background. `TimeoutException` → onError.
- `escapeAfter` (default 8s): overlay grows a "Continue anyway / Retry" panel
  rendered ABOVE the AbsorbPointer (tappable — a consumer's overlayBuilder
  can't add it). Continue = dismiss block, keep connecting; Retry = fresh
  attempt.
- Attempt-generation counter (`_attempt`/`myAttempt`) so a Retry supersedes a
  wedged attempt without the stale one clobbering state; stale attempt's
  timeout is silenced (doesn't fire onError — Codex #7).
- **Non-blocking "connection stuck" notice** on timeout (`stuckNoticeBuilder`,
  default app-neutral "Tailscale isn't responding … reopen it to recover").
  The honest surfacing: because `embed` serializes ops, a genuinely-wedged
  native `ensure()` poisons the shared `_serial` queue — every later
  ensure()/stop() (Tailarr's profile switch, profile delete, Basic-mode "Leave
  Server") queues behind it and re-hangs; force-quit is the real recovery, so
  the notice says so instead of handing back a dead-looking-fine UI.
- Also landed **Codex #10** (free, isolated): `settings_panel.dart`
  `_deleteIdentity`/`_apply` now `mounted`-guard every post-await setState, and
  `_deleteIdentity` sets `_busy` (no overlapping deletes). N/A for Tailarr (own
  settings UI) but helps other consumers.

**Verified:** `flutter analyze` clean (lib + test); `flutter test` **33/33**
(+6 guard tests in new `test/guard_test.dart`: timeout clears wedged overlay,
escape/Continue frees input, Retry succeeds, stuck notice appears/dismissible,
success clears notice, stale-onError silenced). Test gotchas (both the zone
trap `embed.dart` documents): the fake's gate Completer is created lazily
INSIDE `ensure()` (FakeAsync zone) — a setUp-created one lives in the real zone
and completing it from the body never delivers under `tester.pump()`; and
`tearDown` has a real-timer `stop().timeout(2s)` backstop so a hung chain can't
deadlock the run. Run tests with `--timeout=Ns` so a stall fails fast (this
machine's cold `flutter test` compile is brutally slow).

### Codex adversarial review (read-only, this session)
Ran `codex exec --sandbox read-only` over the whole package. 12 findings;
triage validated against a Tailarr consumer lens. Dispositions:
- **#1 (Critical) — wedged ensure() poisons the `_serialized` queue**: REAL and
  the ask-#3 item. UI recovers (guard timeout) but the singleton is poisoned;
  Tailarr's every recovery path routes through the same queue, so a real wedge
  disables all in-app exits → force-quit only. Dart-side `_serialized` timeout
  is DANGEROUS (would race a new start() against a live native Up() → the
  two-instances-share-a-state-dir crash). Correct fix = native `Up()`
  cancellation (big). **Deferred, telemetry-gated**: Tailarr's Self-Heal card
  surfaces rebind/restart counters — if the TestFlight fleet shows real
  full-RESTARTS firing (the thing that caused the lockup), that graduates #1
  from roadmap to priority. The v0.3.6 stuck notice is the stopgap. Fold
  **#6 (sync stopProxy on iOS platform thread)** and **#9 (rebind races stop)**
  into this one native investigation.
- **#2 (High) — rollback port drift PROMOTED**: failed identity restart that
  successfully rolls back may rebind on a NEW port, but Swift's error carries
  only rolledBack/activeIdentity, not the port → Dart keeps advertising the
  dead one → silent per-profile connectivity loss until app restart. Edge case
  for single-identity, but Tailarr's MAIN path (per-profile identities, ~31
  call sites). Fix = Swift returns rollback port + Dart `_adoptPort`s it. NOT
  done yet.
- **#4 (High)** — hijacked CONNECT tunnels not closed by StopProxy (leak
  goroutines/fds, can outlive stop()/identity switch): real, matters for
  Tailarr's per-switch churn. Bundle with the native investigation.
- **#5 (High)** — `_adoptPort` sets port before awaiting installWebViewProxy, so
  a webview-proxy failure makes a successful start throw + skips onKeyConsumed.
  N/A Tailarr (no webViewProxy). Real for webview users; not done.
- **#10** — landed (see above).
- **#3/#12** — bare-short-name fail-open + broad short-name capture: DOCUMENTED
  intentional tradeoff (the `truenas-ts` feature); Tailarr's server-driven path
  FQDN-resolves everything. Docs-hardening note only, don't fail closed.
- **#8** (#1's testability face), **#11** (mid-flight configure()/unserialized
  reads) — minor/edge, N/A for Tailarr's usage.

### Released / handoff
- Version 0.3.6 (pubspec + podspec), README `ref: v0.3.6`, guard docs added.
  **RELEASED (git-verified on origin):** commit `9e2d08d` on `main`, annotated
  tag `v0.3.6` (`647e4a0`) pushed; tree clean. Dart-only — NO framework
  republish (the `framework-v1.92.5-6` asset is unchanged and still SHA-pinned
  in Framework.lock). Consumers pin `ref: v0.3.6`.
- Tailarr will `flutter pub upgrade` + re-pin `ref: v0.3.6`, wire
  `stuckNoticeBuilder` to name the app ("reopen Tailarr"). Tailarr in-flight:
  Quick Connect app half (pairing foundation committed+inert; self-config UI +
  Bearer wiring unfinished; open E2E finding awaiting a fresh key) — they'll
  either finish QC then bundle the embed rev, or ship Basic-mode + lockup
  debounce sooner and let QC ride the next build.
- Tailarr already app-side debounced `syncTailscaleToProfile()` 600ms (cuts the
  churn that wedges the node; can't un-poison an already-stuck queue — the
  guard fix is the real one).

### Next session, in order
1. Await Tailarr's telemetry read on whether full-RESTARTS fire in the wild
   (the green light for #1 native `Up()` cancellation — see memories
   `magicsock-receiveipv4-rootcause`, `-live-capture`). If yes, scope #1 + #4 +
   #6 + #9 as one native investigation.
2. Consider #2 (rollback port drift) — promoted; Swift+Dart, Tailarr main path.
3. Real-key end-to-end (unchanged; needs user's fresh `tskey-auth-…` × 2). Sim
   `ts-browser-test` (9540842C-9F8C-4482-B159-85E4B2BC967C) still exists.
4. Follow up on Plezy adoption of v0.3.0 reply (not yet confirmed landed).
5. Gap 5 ("Android + TV input", incl. QR/pairing auth) — top roadmap item.

## Diagnose-then-defang session (2026-07-25): v0.3.4 + v0.3.5

**Root-caused the ReceiveIPv4 warning for real, then found v0.3.3's restart was
the actual harm and removed it.** Two releases this session.

### Source proof (tailscale v1.92.5, module cache — cited in memory)
- Warning ⟺ receive goroutine **exited**. `Status.Health`
  (ipnlocal/local.go:1252) = `health.Strings()`, a LATCHED warnable. `f.missing`
  is recomputed ONLY by the 1-min `AfterFunc` timer `timerSelfCheck`
  (health.go:152/966/1350); status reads see the stale flag. `checkReceiveFuncs`
  marks a func healthy if numCalls rose OR `inCall==true` — a goroutine merely
  BLOCKED in ReadBatch reads healthy. So a live goroutine clears the warning
  within ≤60s even with zero traffic ⇒ persisting-many-minutes = goroutine dead.
- wireguard-go `RoutineReceiveIncoming` (tailscale/wireguard-go
  @20250716, device/receive.go:110-125) `return`s on net.ErrClosed /
  non-temporary errors (iOS socket teardown). `device.BindUpdate()`
  (device.go:471-529) is the ONLY thing that relaunches it — and **tailscale
  NEVER calls BindUpdate** (grep: 0 non-test refs). magicsock swaps sockets
  under live goroutines via `RebindingUDPConn`; `Conn.Rebind()` only helps if it
  wins the ~3.3s death-spiral race before the goroutine exits. So a truly-exited
  goroutine needs a full server recreation.

### Live capture (2026-07-25, "it's happening" — decisive)
This Mac (`stephens-macbook-air`, 100.104.98.91) is on the SAME tailnet as the
Tailarr iOS device (`tailarr-app-tailarr-g1upwm` / 100.91.220.64). While the
warning showed: `tailscale ping` = **DERP(sea) only, never upgrades** ("direct
connection not established") ⇒ **REAL, not cosmetic** — receive path degraded to
relay, traffic still worked. After ~4 min foregrounded it recovered to
**direct** (`10.10.10.108:...`) and the warning cleared — **with NO peer blink**
⇒ **no full restart fired**. So recovery came from rebind/natural, and the
v0.3.3 restart was never the hero.

### v0.3.4 — recovery telemetry (instrument, don't guess)
Since blind mechanism changes kept missing, added observability. `StatusJSON`
now carries `"recovery"` (needsRebind, healAttempts, cumulative rebinds/restarts
+ last reason + UTC RFC3339 timestamp), surfaced as
`TailscaleStatus.recovery` (`TailscaleRecovery`, null when stopped). Go
recordRebind/recordRestart + `recovery()`; +Dart model; +tests. Framework
**framework-v1.92.5-5**. NOTE: v0.3.4 still shipped the restart — superseded by
v0.3.5 below; do not pin v0.3.4.

### v0.3.5 — watchdog is REBIND-ONLY (the fix)
Tailarr reported app-wide outages (Users/Radarr failing, "Try Again didn't
work") — traced to v0.3.3's restart: `old.Close()` then new `Up()` (≤upTimeout
~45s); while down, `status()` throws and `dial()` falls back to a direct path
that can't route CGNAT/MagicDNS ⇒ EVERY tailnet host fails for ~45s. A hard
outage traded for clearing a benign relay-degradation warning. **Option A
chosen** (user strong lean): `maybeSelfHeal` now does the cheap non-disruptive
**rebind ONLY**, never auto-restarts. `restartServer` + telemetry +
`selfHealRestartInterval`/`lastRestart` RETAINED (unused) for a future Option B
(restart gated on real total-failure: backend not Running AND DERP down) — add
only if telemetry ever shows rebind can't recover; no such evidence today. Test
replaced: `TestMaybeSelfHealRebindOnlyNeverRestarts`. Framework
**framework-v1.92.5-6** (Framework.lock SHA256
`cba3bae617b134f02054e5b0460d2479ba6c55624f06552a2aba23f6407974ec`).

**Released (git-verified, pushed):** v0.3.4 (`b01ff0a`, tag v0.3.4) then v0.3.5
(`22b66c3`, tag v0.3.5) on main. Both: `go test -race` green, `flutter analyze`
clean, `flutter test` **27/27**, example `flutter build ios --simulator` links
the rebuilt framework; published assets re-downloaded + SHA256-verified. README
ref → v0.3.5, watchdog docs rewritten (rebind-only; warning = graceful DERP
degradation, not an outage).

### Consumer coordination (Tailarr)
Tailarr already pinned v0.3.4 and added a Self-Heal Telemetry card
(rebinds/restarts + timestamps, restarts front-and-center) to its Status page,
and softened the Status copy to "reconnecting, refreshes automatically." Handoff
sent: **re-pin v0.3.4 → `ref: v0.3.5`** (framework-v1.92.5-6) before their next
build — one build = telemetry + outage fix. Soak proof: when the warning
appears/clears, `restarts` stays **0**, `rebinds` increments, no app-wide stalls.

### Next session, in order
1. Await Tailarr v0.3.5 soak report. On next "it's happening": read the phone's
   recovery telemetry (restarts should be 0) AND run the Mac `tailscale ping`
   capture — see memory [[magicsock-receiveipv4-live-capture]]. If telemetry
   ever shows the warning persisting with rebinds climbing and traffic genuinely
   dead (not just DERP), THAT is the evidence to build Option B.
2. Real-key end-to-end (unchanged, needs user's fresh `tskey-auth-…` × 2). Sim
   `ts-browser-test` (9540842C-9F8C-4482-B159-85E4B2BC967C) still exists.
3. Follow up on Plezy adoption of v0.3.0 reply (not yet confirmed landed).
4. Gap 5 ("Android + TV input", incl. QR/pairing auth) — top roadmap item.

Memory files added this session:
`magicsock-receiveipv4-rootcause`, `magicsock-receiveipv4-live-capture`.

## Watchdog restart-escalation session (2026-07-24): v0.3.3

**v0.3.2 FAILED closing verification** — third field sighting
(`~/projects/magicsock-receiveipv4-v032-build15.jpg`): real device on
v0.3.2/framework-v1.92.5-3, warning persisted across 30+ seconds of status
refreshes, so all three v0.3.2 layers demonstrably fired and Rebind()+ReSTUN()
still didn't clear it. Source investigation of tailscale v1.92.5 (module
cache) proved WHY, with citations:

- The warning only fires when wireguard-go's receive goroutine has
  **permanently exited**: `health.checkReceiveFuncsLocked()`
  (health/health.go:1350) marks a func "missing" only if it made zero calls
  in ~60s AND isn't blocked mid-call — a live-but-stuck goroutine reads
  healthy. So warning ⇒ goroutine dead.
- wireguard-go `RoutineReceiveIncoming` (device/receive.go:112-124) exits on
  `net.ErrClosed` or persistent non-temporary errors — which iOS socket
  teardown produces.
- `magicsock.Conn.Rebind()` (magicsock.go:3614) only swaps the pconn inside
  `RebindingUDPConn` — under a loop that no longer runs. **Nothing respawns
  the goroutine except `device.BindUpdate()`** (bind close+open), reachable
  only via device Down/Up — NOT exposed by tsnet/wgengine/localapi. No
  middle path exists; minimal reliable recovery = full server Close + new
  Server. Matches the only field-observed recovery (stop/start).

**Fix (v0.3.3, Go-only, no Dart/Swift changes):** the watchdog now
**escalates**. `maybeSelfHeal` heal ladder: attempt 1 → rebind (unchanged);
attempt 2+ (warning survived ≥30s past a rebind) → `restartServer()`: close
the tsnet server, build a fresh one on the same state dir (`newServer()` from
retained hostname/authKey/ephemeral), `Up()` (keep the server even if Up
times out — Up only watches an already-Started backend; it converges when the
network allows), re-apply RouteAll. **Proxy listener/port untouched** —
consumers never see the restart; while the node is down status() errors so
proxied dials fall back to direct, keeping public traffic flowing. Restarts
rate-limited by `selfHealRestartInterval` (2min) on top of the 30s heal
interval; healthy status resets the ladder. Server pointer swap guarded by
`srvMu` (dial/status/rebind read via `t.srv()`); StopProxy race handled (a
restart landing after StopProxy closes the new server instead of resurrecting
the node). Test seams `rebindFn`/`restartFn`.

**Verified:** `go vet` + `go test -race` green (+3 tests: escalation ladder,
restartServer not-running/zero-value safety, newServer config carry),
`flutter analyze` clean, `flutter test` 24/24, example `flutter build ios
--simulator` links the rebuilt framework. Published asset re-downloaded and
SHA256-verified against Framework.lock.

**Released:** version 0.3.3 (pubspec + podspec), tag `v0.3.3`, framework
**`framework-v1.92.5-4`** (Framework.lock SHA256
`2fdb6e41232a647ada30bd1edd67017ec4a793d0f35190ca67d350efb2796b03`). README
ref bumped to `ref: v0.3.3`; README now documents the watchdog escalation.

**Closing verification (real device, only valid test for this class):**
Tailarr bumps to v0.3.3 + framework-v1.92.5-4, reproduces (hours of uptime,
WiFi↔cellular transition, warning appears), then keeps the Status page open:
attempt 1 rebind at first status read, attempt 2 full restart ≥30s later —
warning should clear within ~60-90s of first surfacing. Watch for the node
briefly restarting (peers drop/reappear) — expected, once.

### Next session, in order
1. Relay v0.3.3 to Tailarr (bump + soak per closing verification above).
   Supersedes the v0.3.2 roam check.
2. Real-key end-to-end (unchanged, needs user's fresh `tskey-auth-…` × 2).
   Sim `ts-browser-test` (9540842C-9F8C-4482-B159-85E4B2BC967C) still exists.
3. Follow up on Plezy adoption of v0.3.0 reply (not yet confirmed landed).
4. Gap 5 ("Android + TV input", incl. QR/pairing auth) — top roadmap item.

## Magicsock path-change rebind session (2026-07-23 evening): v0.3.2

**v0.3.1's resume rebind FAILED real-device verification** — the ReceiveIPv4
warning recurred twice on 2026-07-23 (screenshots in
`~/projects/magicsock-receiveipv4-*.jpg`): morning on WiFi (~3.6h uptime,
pre-fix build) and afternoon on **mobile data** with TestFlight build 14
running v0.3.1/framework-v1.92.5-2 (CI-confirmed). Root cause of the miss:
the v0.3.1 rebind only runs from `EnsureProxy()` (app resume), but iOS also
invalidates UDP sockets on **network path changes** — WiFi↔cellular handoff,
band changes, radio power management — which happen while foregrounded, with
no resume event. tsnet's built-in netmon doesn't catch these in the gomobile
sandbox. The official iOS client pairs the wake rebind with an
NWPathMonitor-driven rebind; we now do the same, in three layers:

1. **Go `RebindNetwork()`** (exported): no-op unless running, calls
   `rebindMagicsock(reason)` (now takes a reason string:
   tsembed-resume / tsembed-pathchange / tsembed-selfheal).
2. **Swift NWPathMonitor** (`startPathMonitorIfNeeded()`): started lazily on
   first successful start (incl. rollback path), kept for plugin lifetime
   (NWPathMonitor can't restart after cancel; isRunning guard makes it inert
   when stopped). Path signature = status + interface type:name list; first
   callback records the baseline only; rebind runs off-main after
   snapshotting the instance on main.
3. **Go self-heal watchdog** (`maybeSelfHeal`, called from `status()` on
   every FRESH fetch — i.e. every proxied dial / StatusJSON past the 3s
   cache): if health contains the magicsock "not running" warning
   (`healthNeedsRebind`, case-insensitive), rebind async, rate-limited to
   one per 30s (`selfHealInterval`). Observable-state-driven — catches
   whatever the resume hook and path monitor miss.

The v0.3.1 resume rebind is kept (correct, just not sufficient).

**Verified:** `go test` green (+3 tests: RebindNetwork nil-safety,
healthNeedsRebind matrix, maybeSelfHeal rate limit), `flutter analyze`
clean, `flutter test` 24/24, example `flutter build ios --simulator` links
the rebuilt framework (proves the new gomobile symbol resolves from Swift).

**Released:** version 0.3.2 (pubspec + podspec), tag `v0.3.2`, framework
**`framework-v1.92.5-3`** (Framework.lock SHA256
`6e7c5d9f1d66c2e47ebfa2a10d10cb642c60325fb98879051ab9bdc8f3e9655c`, asset
re-downloaded + checksum-verified). README ref bumped to `ref: v0.3.2`.

**Closing verification (still open, and unit/sim CANNOT catch this class):**
both failures were long-uptime real-device runs with radio transitions. The
real test: phone foregrounded, roam WiFi↔cellular (toggle WiFi off/on works),
then check Tailarr's Settings > General > Network > Tailscale Status — the
warning should clear within ~30s even if the path monitor misses (watchdog
fires on the status page's own reads). Needs Tailarr to bump to v0.3.2 +
framework-v1.92.5-3 and a TestFlight soak.

### Next session, in order
1. Relay v0.3.2 to Tailarr (bump + real-device roam/soak verification per
   above). This supersedes the v0.3.1 suspend/resume check.
2. Real-key end-to-end (unchanged, needs user's fresh `tskey-auth-…` × 2).
   Sim `ts-browser-test` (9540842C-9F8C-4482-B159-85E4B2BC967C) still exists.
3. Follow up on Plezy adoption of v0.3.0 reply (not yet confirmed landed).
4. Gap 5 ("Android + TV input", incl. QR/pairing auth) — top roadmap item.

## Magicsock resume-rebind session (2026-07-23 morning): v0.3.1

**Bug (Tailarr, confirmed twice on real devices):** after iOS suspend/resume
the node reported the health warning "The MagicSock function ReceiveIPv4 is
not running" (tailscale#10976 class). Traffic still worked but silently
degraded to DERP relay; only a stop/start cleared it. Root cause: the resume
path (`TailscaleGuard` → `ensure()` → Go `EnsureProxy()`) only health-checked
the local proxy listener — it never rebound magicsock's UDP sockets, which
iOS parks independently.

**Fix (Go-only, `go/main.go`):** `EnsureProxy()` now calls a new
`rebindMagicsock()` unconditionally (even when the proxy listener survived):
`server.Sys().MagicSock.GetOK()` → `Conn.Rebind()` + `ReSTUN("tsembed-resume")`
(Rebind's doc requires the follow-up ReSTUN; matches the official iOS
client's wake path), then drops the 3s status cache so the next StatusJSON
re-reads health instead of serving the stale warning. Nil-safe pre-start
(`Sys()` is nil until tsnet starts). Note: `tsnet.Server.Sys()` is
documented as "not a stable API" — re-check it on tailscale bumps.

**Verified:** `go test` green (+2 tests: rebind nil-safety, EnsureProxy
NOT_RUNNING), `flutter analyze` clean, `flutter test` 24/24, example
`flutter build ios --simulator` links the rebuilt framework. The real
health-warning-clears-on-resume check needs a running node with a real auth
key — NOT yet done (same blocker as the standing real-key e2e item); Tailarr
can confirm via its Status page after bumping.

**Released (git-verified on origin):** version 0.3.1 (pubspec + podspec),
commit `38c814a` on main, annotated tag `v0.3.1` pushed. Framework
republished as **`framework-v1.92.5-2`** (Framework.lock: SHA256
`9b974294b4776fee20a8c1f7bc1fdd8f9a645af4f3701c39ab893031297fc9d8`; asset
re-downloaded and checksum-verified against the lock). README ref bumped to
`ref: v0.3.1`. A full bump-and-verify handoff prompt was written for the
Tailarr session (includes the suspend/resume verification steps) — Tailarr's
real-device run is the closing verification; awaiting their report.

**build.sh gotcha (fixed this session):** the publish step's TS_VERSION grep
(`awk '{print $2}'` on the go.mod require line) broke when `go mod tidy`
collapsed the require block to single-line form — it published a bogus
`framework-vtailscale.com` release (deleted immediately; safe, nothing ever
pinned it — the never-delete rule protects tags committed in Framework.lock
history, which this never was). Now uses
`go list -m -f '{{.Version}}' tailscale.com` + a sanity check.

**Consumer FYIs from Tailarr (2026-07-23):**
- Bare-short-name routing fix (39b8afd) passed a real-device smoke test
  2026-07-22 — that standing verification item is CLOSED (the
  system-DNS-fallback half for non-peer dotless names remains untested).
- `FakeTailscaleBackend` has its first external consumer: Tailarr's
  `integration_test/tailscale_status_page_test.dart`. Its API is now a
  compatibility surface — keep stable or version bumps deliberately.
- Tailarr has a Tailscale Status page surfacing `status()` health warnings
  (that's what caught this bug).

### Next session, in order
1. Real-key end-to-end (unchanged, needs user's fresh `tskey-auth-…` × 2) —
   now also covers the suspend/resume health-clear check for this fix. Sim
   `ts-browser-test` (9540842C-9F8C-4482-B159-85E4B2BC967C) still exists.
2. Follow up on Plezy adoption of v0.3.0 reply (not yet confirmed landed).
3. Gap 5 ("Android + TV input", incl. QR/pairing auth) — top roadmap item.

## Plezy feedback session (2026-07-20): drop-in DX gaps, v0.3.0

**State (git-verified, RELEASED):** v0.3.0 is **merged + tagged**. PR #1
squash-merged to `main` as `def930c`; annotated tag **`v0.3.0`** pushed at
that commit; branch `feat/plezy-dx-v0.3.0` deleted; README install snippet
bumped to `ref: v0.3.0` (inside the tag). Tree clean, `main` in sync. Both
Plezy round-2 riders shipped *inside* v0.3.0 (the tag wasn't cut yet when
they arrived — lucky timing). Consumers pin `ref: v0.3.0`.

**Process note:** I told the Plezy session v0.3.0 had "shipped" before it was
merged — a break-time note had wrongly claimed the commit was on main. It
wasn't; it was still a PR. Acknowledged the slip to them. No harm (riders
folded in pre-tag), but the lesson: **git-verify origin/main before saying
"shipped"; don't trust a prior session's break-time note over `git log`.**

### Riders from Plezy verification round 2 (2026-07-20, same day)
Plezy traced all three decisions against real data paths — all three land
right, no design change. Two follow-ups landed on the branch:
- **Rider 1 (code):** `TailscaleClient`'s internal tunnel now sets
  `maxConnectionsPerHost` (default `6`, `TailscaleClient.defaultMaxConnectionsPerHost`)
  and `.custom(maxConnectionsPerHost:)` exposes it. dart:io's default is
  unbounded → a poster/artwork grid over one tailnet host opened a connection
  per request; now HTTP/1.1 keep-alive with a bounded pool. Grid-heavy apps
  raise to ~12. Test added (24/24). Confirmed: large media never rides the
  Dart http path in Plezy (playback→libmpv http-proxy, offline→
  background_downloader, only API/artwork→Dart client), so the delegating
  wrapper's loss of native HTTP/2 only touches small requests — acceptable.
- **Rider 2 (docs):** native **downloaders** (background_downloader:
  URLSession/WorkManager) are a THIRD native egress sink, not modeled before —
  an offline download from a tailnet-only server fails unless routed. Media
  doc section is now "…players and downloaders"; `proxyPortListenable` feeds
  all three sinks (strongest vote that Gap 2 is the keystone). Roadmap note:
  scope the Android effort as **"Android + TV input"** (QR/pairing auth, not
  pasting tskey on a leanback remote — media center of gravity is Android TV).
- Gap 7 confirmed skip (Plezy has its own SettingsService; a package-shipped
  shared_prefs store would be a second island serious apps route around).
  They'll adopt `SingleIdentityTailscaleStore`.

Plezy (edde746/plezy, ~2900★ cross-platform Plex/Jellyfin client) integrated
v0.2.0 and filed 7 gaps. Gatekeeper triage (kept surface crisp): built the
pure-Dart / DX ones, deferred the big platform work. **No xcframework
rebuild** — all changes are Dart + docs. `flutter analyze` clean (pkg +
example), `flutter test` **24/24** green (23 + rider-1 pooling test). Version
bumped 0.2.0 → **0.3.0** (additive API, non-breaking) in pubspec + podspec.
Committed on branch `feat/plezy-dx-v0.3.0` (PR #1, unmerged) — see State above.

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
1. ~~Commit + push + tag v0.3.0~~ **DONE** (see State above). A full Plezy
   reply was drafted this session (acknowledged the "shipped" slip; gave
   adoption: hand `TailscaleClient` their CupertinoClient + `maxConnectionsPerHost:
   12`, wire libmpv **and background_downloader** to `proxyPortListenable`,
   drop the tvOS onError swallow, adopt `SingleIdentityTailscaleStore`). Not
   yet confirmed landed in Plezy — follow up if they report back.
2. Still-open older item: **real-key end-to-end** (needs user's fresh
   `tskey-auth-…` × 2) — sim `ts-browser-test`
   (9540842C-9F8C-4482-B159-85E4B2BC967C) still exists. Also the untested
   real-device short-name/system-DNS-fallback smoke test from Tailarr.
3. Gap 5 (**"Android + TV input"**, incl. QR/pairing auth) when there's
   appetite for a multi-session platform push. Top roadmap item.

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
