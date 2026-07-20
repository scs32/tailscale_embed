@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tailscale_embed/tailscale_embed_http.dart';

void main() {
  group('TailscaleClient routing', () {
    test('routesThroughTailnet matches tailnet hosts and short names only', () {
      expect(
          TailscaleClient.routesThroughTailnet(
              Uri.parse('http://host.tail1234.ts.net/')),
          isTrue);
      expect(
          TailscaleClient.routesThroughTailnet(Uri.parse('http://truenas-ts/')),
          isTrue);
      expect(
          TailscaleClient.routesThroughTailnet(Uri.parse('http://100.100.1.1/')),
          isTrue);
      expect(
          TailscaleClient.routesThroughTailnet(
              Uri.parse('https://example.com/')),
          isFalse);
      expect(
          TailscaleClient.routesThroughTailnet(Uri.parse('http://8.8.8.8/')),
          isFalse);
    });

    test('non-tailnet requests are forwarded to the inner client', () async {
      final seen = <Uri>[];
      final inner = MockClient((req) async {
        seen.add(req.url);
        return http.Response('ok', 200);
      });
      final client = TailscaleClient.custom(inner: inner);

      final res = await client.get(Uri.parse('https://example.com/api'));

      expect(res.statusCode, 200);
      expect(res.body, 'ok');
      expect(seen, [Uri.parse('https://example.com/api')]);
    });

    test('tailnet requests are diverted away from the inner client', () async {
      final seen = <Uri>[];
      final inner = MockClient((req) async {
        seen.add(req.url);
        return http.Response('ok', 200);
      });
      final client = TailscaleClient.custom(inner: inner);

      // With no node running, the tunnel path dials directly and fails DNS —
      // the point under test is that it never reaches the inner client.
      await expectLater(
        client.get(Uri.parse('http://does-not-exist.tail4321.ts.net/')),
        throwsA(anything),
      );
      expect(seen, isEmpty);
    });

    test('tunnel client is bounded per host and stays configurable', () async {
      int? seenCap;
      final client = TailscaleClient.custom(
        inner: MockClient((_) async => http.Response('', 200)),
        maxConnectionsPerHost: 9,
        configureTunnelClient: (c) => seenCap = c.maxConnectionsPerHost,
      );

      // A tailnet request builds the tunnel (the connect then fails DNS).
      await expectLater(
        client.get(Uri.parse('http://x.tail9999.ts.net/')),
        throwsA(anything),
      );

      // The cap was applied before the hook ran, and the hook saw/could
      // override it.
      expect(seenCap, 9);
    });

    test('close does not close a borrowed inner client', () {
      var closed = false;
      final inner = _ClosableMock(() => closed = true);
      TailscaleClient.custom(inner: inner, closeInner: false).close();
      expect(closed, isFalse);

      closed = false;
      TailscaleClient.custom(inner: _ClosableMock(() => closed = true)).close();
      expect(closed, isTrue);
    });
  });
}

class _ClosableMock extends http.BaseClient {
  final void Function() onClose;
  _ClosableMock(this.onClose);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream.empty(), 200);

  @override
  void close() => onClose();
}
