import 'dart:async';

import 'package:flutter/material.dart';

import 'embed.dart';

/// Watches app lifecycle and ensures the embedded Tailscale node and its
/// local proxy are healthy whenever the app launches or returns to the
/// foreground (iOS reclaims the proxy's listener socket during suspension).
/// While (re)connecting, a blocking overlay is shown so requests aren't
/// fired into a dead proxy.
///
/// The blocking overlay is bounded so a wedged connect can never lock the app
/// out permanently:
///  * [connectTimeout] is a hard ceiling on each attempt — when it elapses the
///    overlay clears and input returns while the connect keeps running in the
///    background (a slow tunnel finishing later is fine; a frozen UI is not).
///  * [escapeAfter] is the earlier, softer bound: once an attempt has run this
///    long the overlay grows a "Continue anyway / Retry" affordance so the user
///    can dismiss the block without waiting for the full timeout. Because the
///    `AbsorbPointer` wrapping the overlay is owned by this widget, this
///    affordance has to live here — a consumer's [overlayBuilder] can't add it.
///
/// When an attempt hits the [connectTimeout] ceiling the guard also shows a
/// **non-blocking** "connection stuck" notice (see [stuckNoticeBuilder]). This
/// is deliberately honest: a Dart-side timeout cannot cancel a wedged native
/// `Up()`, and because `TailscaleEmbed` serializes its operations, a genuinely
/// stuck connect poisons the shared queue — every later `ensure()`/`stop()`
/// (profile switches, "disconnect" buttons, this guard's own retries) queues
/// behind it and never runs. Input is restored, but anything that needs the
/// node will re-hang, so the true recovery is to reopen the app. The notice
/// says so rather than silently returning a UI that looks fine but isn't.
///
/// Mount it in your MaterialApp `builder`:
/// ```dart
/// builder: (context, child) => TailscaleGuard(child: child),
/// ```
class TailscaleGuard extends StatefulWidget {
  final Widget? child;

  /// Called when connecting fails or times out (log it, show a snackbar, …).
  /// A [TimeoutException] here means [connectTimeout] elapsed; the connect may
  /// still complete in the background.
  final void Function(Object error, StackTrace stack)? onError;

  /// Replaces the default "Connecting to Tailscale…" overlay. The
  /// "Continue anyway / Retry" escape affordance is layered on top of this by
  /// the guard once [escapeAfter] elapses, so a custom overlay still gets it.
  final WidgetBuilder? overlayBuilder;

  /// Hard ceiling on a single connect attempt. When it elapses the blocking
  /// overlay clears and input returns; the underlying `ensure()` keeps running
  /// in the background (a Dart-side timeout can't cancel the native start, and
  /// a tunnel that comes up a little later is harmless). Set above the native
  /// `upTimeout` (~45s) so a legitimately slow enroll isn't cut short.
  final Duration connectTimeout;

  /// How long an attempt may block the UI before the overlay offers a
  /// "Continue anyway / Retry" escape. The far earlier, user-driven bound —
  /// [connectTimeout] is the automatic backstop if they don't act.
  final Duration escapeAfter;

  /// Replaces the default non-blocking "connection stuck" notice shown after a
  /// [connectTimeout]. `onRetry` starts a fresh connect attempt; `onDismiss`
  /// hides the notice until the next timeout. Use it to word the message for
  /// your app (e.g. name the app to reopen) or to match your design. Return an
  /// empty `SizedBox.shrink()` to suppress the notice entirely.
  final Widget Function(
    BuildContext context,
    VoidCallback onRetry,
    VoidCallback onDismiss,
  )? stuckNoticeBuilder;

  const TailscaleGuard({
    super.key,
    required this.child,
    this.onError,
    this.overlayBuilder,
    this.connectTimeout = const Duration(seconds: 60),
    this.escapeAfter = const Duration(seconds: 8),
    this.stuckNoticeBuilder,
  });

  @override
  State<TailscaleGuard> createState() => _TailscaleGuardState();
}

class _TailscaleGuardState extends State<TailscaleGuard>
    with WidgetsBindingObserver {
  bool _connecting = false;

  /// Whether the "Continue anyway / Retry" affordance is showing (set once
  /// [TailscaleGuard.escapeAfter] elapses on the current attempt).
  bool _showEscape = false;

  /// Set by "Continue anyway": hides the blocking overlay while the current
  /// attempt keeps running in the background. Cleared when a fresh attempt
  /// starts.
  bool _dismissed = false;

  /// Set when an attempt hit the [TailscaleGuard.connectTimeout] ceiling — the
  /// connect is (likely) wedged, so a non-blocking "reopen the app" notice is
  /// shown. Cleared when any attempt succeeds.
  bool _stuck = false;

  /// Set by dismissing the stuck notice; reset when a fresh attempt starts so a
  /// second timeout re-surfaces it.
  bool _stuckDismissed = false;

  Timer? _escapeTimer;

  /// Bumps on every attempt. A Retry (or a resume) supersedes an in-flight,
  /// possibly-wedged attempt by starting a new one; the stale attempt's
  /// timeout/finally checks this so it doesn't clobber the new attempt's state.
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ensure();
  }

  @override
  void dispose() {
    _escapeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _ensure();
  }

  Future<void> _ensure() async {
    final embed = TailscaleEmbed.instance;
    if (!embed.isEnabled) return;
    if (_connecting) return;

    final myAttempt = ++_attempt;
    _escapeTimer?.cancel();
    setState(() {
      _connecting = true;
      _showEscape = false;
      _dismissed = false;
      _stuckDismissed = false;
    });
    _escapeTimer = Timer(widget.escapeAfter, () {
      if (mounted && _connecting && _attempt == myAttempt) {
        setState(() => _showEscape = true);
      }
    });

    try {
      await embed.ensure().timeout(widget.connectTimeout);
      // Success clears any lingering stuck state from an earlier timeout.
      if (_attempt == myAttempt) _stuck = false;
    } catch (error, stack) {
      // Includes TimeoutException — the overlay still clears in `finally` so
      // input returns; the ensure() future keeps running in the background.
      // Only report if this attempt is still the current one: a Retry (or a
      // later resume) supersedes us, and a stale attempt's timeout must not
      // surface a failure while the fresh attempt is still in flight.
      if (_attempt == myAttempt) {
        // A timeout means the connect is (likely) wedged — surface the honest
        // "reopen the app" notice, since the serialized queue may now be
        // poisoned and further node-dependent actions will re-hang.
        if (error is TimeoutException) _stuck = true;
        widget.onError?.call(error, stack);
      }
    } finally {
      // A Retry may have superseded this attempt while our (possibly wedged)
      // ensure() was still pending — if so, leave the newer attempt's state
      // and its escape timer alone.
      if (_attempt == myAttempt) {
        _escapeTimer?.cancel();
        if (mounted) {
          setState(() {
            _connecting = false;
            _showEscape = false;
          });
        }
      }
    }
  }

  /// Dismiss the blocking overlay but let the current attempt keep running in
  /// the background; the next resume (or its own completion/timeout) settles
  /// the state.
  void _continueAnyway() {
    setState(() {
      _dismissed = true;
      _showEscape = false;
    });
  }

  /// Abandon tracking the current (possibly wedged) attempt and start a fresh,
  /// separately-bounded one. The underlying `ensure()` is serialized in the
  /// embed, so this queues behind a stuck native call — but the new attempt
  /// carries its own timeout, so the UI still recovers.
  void _retry() {
    _escapeTimer?.cancel();
    // Clear the gate so _ensure() proceeds; it re-does the setState.
    _connecting = false;
    _ensure();
  }

  void _dismissStuck() => setState(() => _stuckDismissed = true);

  @override
  Widget build(BuildContext context) {
    final showOverlay = _connecting && !_dismissed;
    // Non-blocking: only while nothing is actively connecting/blocking.
    final showStuck = _stuck && !_stuckDismissed && !showOverlay;
    return Stack(
      children: [
        if (widget.child != null) widget.child!,
        if (showOverlay)
          Positioned.fill(
            child: AbsorbPointer(
              child: widget.overlayBuilder?.call(context) ?? _defaultOverlay(),
            ),
          ),
        // Sits ABOVE the AbsorbPointer so its buttons receive taps.
        if (showOverlay && _showEscape)
          Positioned.fill(child: _escapePanel(context)),
        // NOT wrapped in AbsorbPointer — the app stays usable; this only warns.
        if (showStuck)
          widget.stuckNoticeBuilder?.call(context, _retry, _dismissStuck) ??
              _defaultStuckNotice(context),
      ],
    );
  }

  Widget _defaultOverlay() {
    return Material(
      color: Colors.black.withValues(alpha: 0.65),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text(
            'Connecting to Tailscale…',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _defaultStuckNotice(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(12),
              color: scheme.errorContainer,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Tailscale isn't responding",
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: scheme.onErrorContainer),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Anything that needs it may not work. If the app becomes '
                      'unresponsive, reopen it to recover.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onErrorContainer),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _dismissStuck,
                          child: const Text('Dismiss'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _retry,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _escapePanel(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Still connecting to Tailscale…',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _continueAnyway,
                          child: const Text('Continue anyway'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _retry,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
