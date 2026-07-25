import 'package:flutter_test/flutter_test.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

void main() {
  group('TailscaleStatus.fromJson', () {
    test('parses recovery telemetry when present', () {
      final st = TailscaleStatus.fromJson({
        'running': true,
        'backendState': 'Running',
        'health': ['The MagicSock function ReceiveIPv4 is not running'],
        'peers': [],
        'recovery': {
          'needsRebind': true,
          'healAttempts': 2,
          'rebinds': 3,
          'lastRebindAt': '2026-07-25T18:47:00Z',
          'lastRebindReason': 'tsembed-selfheal',
          'restarts': 1,
          'lastRestartAt': '2026-07-25T18:48:00Z',
          'lastRestartReason': 'tsembed-selfheal-restart',
        },
      });
      final r = st.recovery;
      expect(r, isNotNull);
      expect(r!.needsRebind, isTrue);
      expect(r.healAttempts, 2);
      expect(r.rebinds, 3);
      expect(r.lastRebindReason, 'tsembed-selfheal');
      expect(r.restarts, 1);
      expect(r.lastRestartAt, '2026-07-25T18:48:00Z');
      expect(r.lastRestartReason, 'tsembed-selfheal-restart');
    });

    test('recovery is null when absent (node not running)', () {
      final st = TailscaleStatus.fromJson({'running': false});
      expect(st.recovery, isNull);
      expect(st.running, isFalse);
    });

    test('recovery defaults are safe when fields are missing', () {
      final st = TailscaleStatus.fromJson({
        'running': true,
        'peers': [],
        'recovery': {'needsRebind': false},
      });
      expect(st.recovery, isNotNull);
      expect(st.recovery!.rebinds, 0);
      expect(st.recovery!.restarts, 0);
      expect(st.recovery!.lastRebindAt, isNull);
    });
  });
}
