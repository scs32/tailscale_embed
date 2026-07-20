import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tailscale_embed/tailscale_embed.dart';
import 'package:tailscale_embed/tailscale_embed_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final embed = TailscaleEmbed.instance;
  late FakeTailscaleBackend backend;
  late TailscaleConfig config;

  setUp(() {
    backend = FakeTailscaleBackend();
    config = const TailscaleConfig(enabled: true, authKey: 'tskey-auth-x');
    embed.configure(config: () => config, backend: backend);
  });

  tearDown(() => embed.stop());

  test('start returns the proxy port and records the config used', () async {
    final port = await embed.start();
    expect(port, backend.port);
    expect(embed.proxyPort, backend.port);
    expect(backend.startedConfigs.single.authKey, 'tskey-auth-x');
    expect(await embed.isRunning(), isTrue);
  });

  test('proxyPortListenable fires on start and clears on stop', () async {
    final events = <int?>[];
    void listener() => events.add(embed.proxyPort);
    embed.proxyPortListenable.addListener(listener);
    addTearDown(() => embed.proxyPortListenable.removeListener(listener));

    await embed.start();
    await embed.stop();

    expect(events, [backend.port, null]);
  });

  test('onKeyConsumed fires with the identity for persistent nodes',
      () async {
    String? consumed;
    embed.configure(
      config: () => config,
      backend: backend,
      onKeyConsumed: (identity) => consumed = identity,
    );
    config = const TailscaleConfig(
        enabled: true, authKey: 'tskey-auth-x', identity: 'work');
    await embed.start();
    expect(consumed, 'work');
  });

  test('onKeyConsumed does not fire for ephemeral nodes or empty keys',
      () async {
    String? consumed;
    embed.configure(
      config: () => config,
      backend: backend,
      onKeyConsumed: (identity) => consumed = identity,
    );
    config = const TailscaleConfig(
        enabled: true, authKey: 'tskey-auth-x', ephemeral: true);
    await embed.start();
    expect(consumed, isNull);

    config = const TailscaleConfig(enabled: true, authKey: '');
    await embed.start();
    expect(consumed, isNull);
  });

  test('ensure starts when stopped and switches on identity change',
      () async {
    await embed.ensure();
    expect(backend.runningIdentity, 'default');

    // Same identity, already running: ensure health-checks, no new start.
    await embed.ensure();
    expect(backend.startedConfigs, hasLength(1));

    // Provider now names a different identity: ensure switches the node.
    config = const TailscaleConfig(
        enabled: true, authKey: 'tskey-auth-x', identity: 'work');
    await embed.ensure();
    expect(backend.runningIdentity, 'work');
    expect(backend.startedConfigs, hasLength(2));
  });

  test('restart applies a config change on the same identity', () async {
    await embed.start();
    config = const TailscaleConfig(
        enabled: true, authKey: '', hostname: 'renamed');
    await embed.restart();
    expect(backend.startedConfigs.last.hostname, 'renamed');
    expect(backend.runningIdentity, 'default');
  });

  test('isEnrolled reflects persisted identities', () async {
    expect(await embed.isEnrolled('default'), isFalse);
    await embed.start();
    expect(await embed.isEnrolled('default'), isTrue);
    expect(await embed.isEnrolled('work'), isFalse);
  });

  test('deleteIdentity refuses the active identity', () async {
    await embed.start();
    expect(
      () => embed.deleteIdentity('default'),
      throwsA(isA<PlatformException>().having(
          (e) => e.code, 'code', TailscaleErrorCodes.identityActive)),
    );
    await embed.stop();
    await embed.deleteIdentity('default');
    expect(await embed.isEnrolled('default'), isFalse);
  });

  test('start failure surfaces and leaves the backend stopped', () async {
    backend.startError = PlatformException(
        code: TailscaleErrorCodes.authKeyInvalid, message: 'invalid key');
    expect(
      () => embed.start(),
      throwsA(isA<PlatformException>().having(
          (e) => e.code, 'code', TailscaleErrorCodes.authKeyInvalid)),
    );
  });

  group('proxy routing (findProxy)', () {
    test('routes tailnet hosts and short names via the proxy when running',
        () async {
      await embed.start();
      final proxy = 'PROXY 127.0.0.1:${backend.port}';
      expect(tailscaleFindProxy(Uri.parse('http://host.tail1234.ts.net/')),
          proxy);
      expect(tailscaleFindProxy(Uri.parse('http://100.108.88.87/')), proxy);
      // Bare MagicDNS short name — only the embedded node can resolve it.
      expect(tailscaleFindProxy(Uri.parse('http://truenas-ts/')), proxy);
      // Public names and non-tailnet IPs go direct.
      expect(tailscaleFindProxy(Uri.parse('https://example.com/')), 'DIRECT');
      expect(tailscaleFindProxy(Uri.parse('http://8.8.8.8/')), 'DIRECT');
    });

    test('everything goes direct when the node is stopped', () async {
      expect(tailscaleFindProxy(Uri.parse('http://host.tail1234.ts.net/')),
          'DIRECT');
      expect(tailscaleFindProxy(Uri.parse('http://truenas-ts/')), 'DIRECT');
    });

    test('short-name detection excludes IPs and dotted names', () {
      expect(isPossibleTailnetShortName('truenas-ts'), isTrue);
      expect(isPossibleTailnetShortName('truenas.local'), isFalse);
      expect(isPossibleTailnetShortName('192.168.1.10'), isFalse);
      expect(isPossibleTailnetShortName('fd7a::1'), isFalse);
      expect(isPossibleTailnetShortName('localhost'), isTrue);
      expect(isPossibleTailnetShortName(''), isFalse);
    });
  });

  group('SingleIdentityTailscaleStore', () {
    test('collapses the per-identity API onto three plain values', () {
      final store = _FakeSingleStore()
        ..enabled = true
        ..authKey = 'tskey-auth-x'
        ..hostname = 'my-app';

      // Identity is pinned and unswitchable.
      expect(store.identity, 'default');
      store.identity = 'ignored';
      expect(store.identity, 'default');

      // Per-identity accessors ignore the identity arg and hit the plain slot.
      expect(store.authKeyFor('whatever'), 'tskey-auth-x');
      expect(store.hostnameFor('whatever'), 'my-app');
      store.setAuthKey('whatever', 'tskey-auth-y');
      store.setHostname('whatever', 'renamed');
      expect(store.authKey, 'tskey-auth-y');
      expect(store.hostname, 'renamed');
    });
  });

  group('unsupported platform (missing native plugin)', () {
    // The default MethodChannel backend has no registered handler in tests, so
    // invokeMethod throws MissingPluginException — exactly the tvOS situation.
    test('latches to unsupported and surfaces a typed UNSUPPORTED error',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      const channelBackend = MethodChannelTailscaleBackend();
      // Optimistic on the iOS-family target until a call proves otherwise.
      expect(channelBackend.isSupported, isTrue);

      // Lifecycle probes degrade to a quiet no-op (no throw) and latch.
      expect(await channelBackend.isRunning(), isFalse);
      expect(channelBackend.isSupported, isFalse);
      expect(await channelBackend.status(), isNull);
      expect(await channelBackend.listIdentities(), isEmpty);

      // An explicit start now fails with the stable UNSUPPORTED code.
      expect(
        () => channelBackend
            .start(const TailscaleConfig(enabled: true, authKey: '')),
        throwsA(isA<PlatformException>().having(
            (e) => e.code, 'code', TailscaleErrorCodes.unsupported)),
      );
      expect(
        TailscaleAuthKeys.friendlyError(
            PlatformException(code: TailscaleErrorCodes.unsupported)),
        contains('not available on this device'),
      );
    });
  });
}

class _FakeSingleStore extends SingleIdentityTailscaleStore {
  @override
  bool enabled = false;
  @override
  String authKey = '';
  @override
  String hostname = '';
}
