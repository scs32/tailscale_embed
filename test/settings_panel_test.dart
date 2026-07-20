import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

/// In-memory [TailscaleSettingsStore] — the shape a consumer's store takes
/// in widget tests.
class MemoryStore implements TailscaleSettingsStore {
  @override
  bool enabled = false;
  @override
  String identity = 'default';
  final Map<String, String> _keys = {};
  final Map<String, String> _hostnames = {};

  @override
  String authKeyFor(String identity) => _keys[identity] ?? '';
  @override
  void setAuthKey(String identity, String value) => _keys[identity] = value;
  @override
  String hostnameFor(String identity) => _hostnames[identity] ?? 'test-host';
  @override
  void setHostname(String identity, String value) =>
      _hostnames[identity] = value;
}

void main() {
  late FakeTailscaleBackend backend;
  late MemoryStore store;

  setUp(() {
    backend = FakeTailscaleBackend();
    store = MemoryStore();
    TailscaleEmbed.instance.configure(
      config: () => TailscaleConfig(
        enabled: store.enabled,
        authKey: store.authKeyFor(store.identity),
        hostname: store.hostnameFor(store.identity),
        identity: store.identity,
      ),
      backend: backend,
      // Consumed keys are deleted from the store; the panel re-reads the
      // store after apply, so the field should empty itself.
      onKeyConsumed: (identity) => store.setAuthKey(identity, ''),
    );
  });

  tearDown(() => TailscaleEmbed.instance.stop());

  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: ListView(children: [child])),
      );

  testWidgets('apply starts the node, shows status, and clears the used key',
      (tester) async {
    await tester.pumpWidget(wrap(TailscaleSettingsPanel(store: store)));

    await tester.tap(find.byType(SwitchListTile));
    await tester.enterText(
        find.widgetWithText(TextField, 'Auth key'), 'tskey-auth-abc');
    await tester.tap(find.text('Apply'));
    await tester.pump();

    expect(store.enabled, isTrue);
    expect(backend.runningIdentity, 'default');
    expect(backend.startedConfigs.single.authKey, 'tskey-auth-abc');
    expect(find.textContaining('Connected'), findsOneWidget);
    // onKeyConsumed cleared the store; the panel re-read it into the field.
    expect(store.authKeyFor('default'), isEmpty);
    expect(tester
        .widget<TextField>(find.widgetWithText(TextField, 'Auth key'))
        .controller!
        .text, isEmpty);
  });

  testWidgets('rejects an API token before starting', (tester) async {
    await tester.pumpWidget(wrap(TailscaleSettingsPanel(store: store)));

    await tester.tap(find.byType(SwitchListTile));
    await tester.enterText(
        find.widgetWithText(TextField, 'Auth key'), 'tskey-api-xyz');
    await tester.tap(find.text('Apply'));
    await tester.pump();

    expect(backend.startedConfigs, isEmpty);
    expect(find.textContaining('API access token'), findsOneWidget);
  });

  testWidgets('apply with the switch off stops the node', (tester) async {
    store.enabled = true;
    store.setAuthKey('default', 'tskey-auth-abc');
    await TailscaleEmbed.instance.start();

    await tester.pumpWidget(wrap(TailscaleSettingsPanel(store: store)));
    await tester.tap(find.byType(SwitchListTile)); // on -> off
    await tester.tap(find.text('Apply'));
    await tester.pump();

    expect(backend.runningIdentity, isNull);
    expect(store.enabled, isFalse);
    expect(find.text('Tailscale disabled'), findsOneWidget);
  });

  testWidgets('showIdentity: false hides identity UI', (tester) async {
    backend.enrolled.add('work');
    await tester.pumpWidget(
        wrap(TailscaleSettingsPanel(store: store, showIdentity: false)));
    await tester.pump();

    expect(find.text('Identity (profile)'), findsNothing);
    expect(find.text('Enrolled identities'), findsNothing);
  });

  testWidgets('enrolled identities list selects and deletes', (tester) async {
    backend.enrolled.addAll(['default', 'work']);
    store.setAuthKey('work', 'tskey-auth-work');
    await tester.pumpWidget(wrap(TailscaleSettingsPanel(store: store)));
    await tester.pump();

    // Tap 'work' -> fields re-point at its stored settings.
    await tester.tap(find.text('work'));
    await tester.pump();
    expect(store.identity, 'work');
    expect(tester
        .widget<TextField>(find.widgetWithText(TextField, 'Auth key'))
        .controller!
        .text, 'tskey-auth-work');

    // Delete 'default'.
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();
    expect(backend.enrolled, {'work'});
    expect(find.textContaining('Deleted identity'), findsOneWidget);
  });
}
