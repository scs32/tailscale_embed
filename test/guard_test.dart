import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

/// A backend whose `ensure()` never resolves until [complete] is called — the
/// node that wedges in "Starting" and is the whole reason the guard needs a
/// timeout + escape hatch.
///
/// The gate is created lazily on the first `ensure()` call so its `await`
/// continuations are registered in the caller's (FakeAsync) zone; a gate made
/// in `setUp` lives in the real zone and completing it from the test body
/// would never deliver under `tester.pump()` (the zone trap `embed.dart`
/// documents).
class _HangingBackend extends FakeTailscaleBackend {
  Completer<int?>? _gate;

  @override
  Future<int?> ensure() => (_gate ??= Completer<int?>()).future;

  bool get gateCompleted => _gate?.isCompleted ?? false;

  void complete(int port) {
    if (!(_gate?.isCompleted ?? true)) _gate!.complete(port);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final embed = TailscaleEmbed.instance;
  late _HangingBackend backend;

  setUp(() {
    backend = _HangingBackend();
    embed.configure(
      config: () => const TailscaleConfig(enabled: true, authKey: 'k'),
      backend: backend,
    );
  });

  tearDown(() async {
    // Belt-and-suspenders: each test drains the gate in-body, but if one bails
    // before that, stop() would serialize behind the still-hung ensure() whose
    // continuation is pinned to the dead FakeAsync zone. A real-timer timeout
    // here guarantees teardown can't deadlock the whole run.
    backend.complete(backend.port);
    await embed.stop().timeout(const Duration(seconds: 2), onTimeout: () {});
  });

  Widget wrap({
    Duration escapeAfter = const Duration(seconds: 8),
    Duration connectTimeout = const Duration(seconds: 30),
    void Function(Object, StackTrace)? onError,
  }) =>
      MaterialApp(
        home: TailscaleGuard(
          escapeAfter: escapeAfter,
          connectTimeout: connectTimeout,
          onError: onError,
          child: const Scaffold(body: Center(child: Text('app'))),
        ),
      );

  // The default overlay's text — unambiguous, unlike AbsorbPointer, which
  // MaterialApp's own route machinery also uses.
  final overlay = find.text('Connecting to Tailscale…');
  bool up(Finder f) => f.evaluate().isNotEmpty;

  // Let the hung ensure() resolve and drain the embed's serial chain *inside*
  // the FakeAsync zone — its continuations are pinned here, so this has to run
  // before the test ends (even on failure) or tearDown's stop() deadlocks
  // behind the still-hung chain.
  Future<void> drain(WidgetTester tester) async {
    backend.complete(backend.port);
    // A Retry's ensure() is serialized behind the first attempt, so unwinding
    // that chain takes more than one frame — pump a few times to settle it
    // (can't pumpAndSettle: the overlay's spinner never stops animating).
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  testWidgets('a wedged ensure() blocks input, then the timeout clears it',
      (tester) async {
    try {
      final errors = <Object>[];
      await tester.pumpWidget(wrap(onError: (e, _) => errors.add(e)));
      await tester.pump();

      // Overlay is up — input is blocked.
      expect(up(overlay), isTrue);

      // Past the hard ceiling: overlay clears even though ensure() is still
      // hung, and the timeout is surfaced to onError.
      await tester.pump(const Duration(seconds: 31));
      expect(up(overlay), isFalse);
      expect(errors.single, isA<TimeoutException>());
      expect(backend.gateCompleted, isFalse); // still hung in the background
    } finally {
      await drain(tester);
    }
  });

  testWidgets('escape hatch appears after escapeAfter; Continue anyway frees UI',
      (tester) async {
    try {
      await tester.pumpWidget(wrap());
      await tester.pump();

      // Not yet — overlay is blocking with no escape.
      expect(find.text('Continue anyway'), findsNothing);
      expect(up(overlay), isTrue);

      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Continue anyway'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Continue anyway'));
      await tester.pump();

      // Overlay gone — input restored — while the connect keeps running.
      expect(up(overlay), isFalse);
      expect(find.text('Continue anyway'), findsNothing);
      expect(backend.gateCompleted, isFalse);
    } finally {
      // Fire the still-pending connect timeout, then drain the hung ensure().
      await tester.pump(const Duration(seconds: 31));
      await drain(tester);
    }
  });

  testWidgets('Retry starts a fresh attempt that can succeed', (tester) async {
    try {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));

      await tester.tap(find.text('Retry'));
      await tester.pump();

      // Still connecting (fresh attempt), escape hidden again.
      expect(up(overlay), isTrue);
      expect(find.text('Continue anyway'), findsNothing);

      // The node finally comes up — the fresh attempt resolves, overlay clears.
      await drain(tester);
      expect(up(overlay), isFalse);
      expect(embed.proxyPort, backend.port);
    } finally {
      await drain(tester);
    }
  });

  testWidgets('connectTimeout surfaces a non-blocking, dismissible stuck notice',
      (tester) async {
    final stuck = find.text("Tailscale isn't responding");
    try {
      await tester.pumpWidget(wrap());
      await tester.pump();

      // No notice while connecting.
      expect(stuck, findsNothing);

      // Hit the hard ceiling: overlay clears (input free) and the notice shows.
      await tester.pump(const Duration(seconds: 31));
      expect(up(overlay), isFalse);
      expect(stuck, findsOneWidget);
      // The underlying app child is still present (notice is non-blocking).
      expect(find.text('app'), findsOneWidget);

      // Dismiss hides it without reconnecting.
      await tester.tap(find.text('Dismiss'));
      await tester.pump();
      expect(stuck, findsNothing);
      expect(backend.gateCompleted, isFalse);
    } finally {
      await drain(tester);
    }
  });

  testWidgets('a successful connect clears the stuck notice', (tester) async {
    final stuck = find.text("Tailscale isn't responding");
    try {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.pump(const Duration(seconds: 31)); // stuck
      expect(stuck, findsOneWidget);

      // Retry from the notice, then the node comes up — notice clears.
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pump();
      await drain(tester);
      expect(stuck, findsNothing);
      expect(up(overlay), isFalse);
      expect(embed.proxyPort, backend.port);
    } finally {
      await drain(tester);
    }
  });

  testWidgets("a superseded attempt's timeout does not fire onError",
      (tester) async {
    final errors = <Object>[];
    try {
      // Attempt 1 hangs; connectTimeout 30s, escape at 8s.
      await tester.pumpWidget(wrap(onError: (e, _) => errors.add(e)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 9)); // escape shows

      // Retry supersedes attempt 1 with attempt 2 (its own fresh 30s timeout).
      await tester.tap(find.text('Retry'));
      await tester.pump();

      // Cross attempt 1's original 30s ceiling (now ~t=31s) but not attempt 2's
      // (armed at ~t=9s, fires ~t=39s). Attempt 1's stale timeout must stay
      // silent.
      await tester.pump(const Duration(seconds: 22));
      expect(errors, isEmpty);
      expect(up(overlay), isTrue); // attempt 2 still connecting
    } finally {
      await drain(tester);
    }
    // Attempt 2 succeeded on drain — still no spurious error.
    expect(errors, isEmpty);
  });
}
