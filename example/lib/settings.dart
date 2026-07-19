import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

/// App settings backed by SharedPreferences. The tailscale_embed package
/// never owns storage — this is the app-side store its config provider
/// reads from.
class Settings {
  Settings._(this._prefs);
  static late Settings instance;

  final SharedPreferences _prefs;

  static Future<void> load() async {
    instance = Settings._(await SharedPreferences.getInstance());
  }

  bool get enabled => _prefs.getBool('ts_enabled') ?? false;
  set enabled(bool v) => _prefs.setBool('ts_enabled', v);

  /// The selected identity (profile). Auth key and hostname are stored per
  /// identity; 'default' keeps the original un-suffixed pref keys so
  /// pre-identity installs keep their settings.
  String get identity => _prefs.getString('ts_identity') ?? 'default';
  set identity(String v) => _prefs.setString('ts_identity', v);

  String _keyFor(String base, String id) =>
      id == 'default' ? base : '$base.$id';

  String get authKey =>
      _prefs.getString(_keyFor('ts_auth_key', identity)) ?? '';
  set authKey(String v) =>
      _prefs.setString(_keyFor('ts_auth_key', identity), v);

  /// Clears the stored auth key for [id] regardless of which identity is
  /// currently selected — onKeyConsumed may fire for a start that raced a
  /// profile switch.
  void clearAuthKey(String id) => _prefs.remove(_keyFor('ts_auth_key', id));

  String get hostname =>
      _prefs.getString(_keyFor('ts_hostname', identity)) ??
      (identity == 'default' ? 'ts-browser' : 'ts-browser-$identity');
  set hostname(String v) =>
      _prefs.setString(_keyFor('ts_hostname', identity), v);

  String get lastUrl => _prefs.getString('last_url') ?? '';
  set lastUrl(String v) => _prefs.setString('last_url', v);
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late bool _enabled = Settings.instance.enabled;
  late final _identityController =
      TextEditingController(text: Settings.instance.identity);
  late final _keyController =
      TextEditingController(text: Settings.instance.authKey);
  late final _hostnameController =
      TextEditingController(text: Settings.instance.hostname);
  bool _busy = false;
  String? _status;
  List<String> _identities = const [];

  @override
  void initState() {
    super.initState();
    _refreshIdentities();
  }

  @override
  void dispose() {
    _identityController.dispose();
    _keyController.dispose();
    _hostnameController.dispose();
    super.dispose();
  }

  Future<void> _refreshIdentities() async {
    final names = await TailscaleEmbed.instance.listIdentities();
    if (mounted) setState(() => _identities = names);
  }

  /// Re-point the key/hostname fields at [identity]'s stored settings.
  void _selectIdentity(String identity) {
    Settings.instance.identity = identity;
    setState(() {
      _identityController.text = identity;
      _keyController.text = Settings.instance.authKey;
      _hostnameController.text = Settings.instance.hostname;
    });
  }

  Future<void> _deleteIdentity(String identity) async {
    try {
      await TailscaleEmbed.instance.deleteIdentity(identity);
      setState(() => _status = 'Deleted identity "$identity"');
    } catch (error) {
      setState(() => _status = TailscaleAuthKeys.friendlyError(error));
    }
    await _refreshIdentities();
  }

  Future<void> _apply() async {
    final key = _keyController.text.trim();
    final typeError = TailscaleAuthKeys.typeError(key);
    if (_enabled && typeError != null) {
      setState(() => _status = typeError);
      return;
    }

    final identity = _identityController.text.trim();
    Settings.instance.identity = identity.isEmpty ? 'default' : identity;
    Settings.instance
      ..enabled = _enabled
      ..authKey = key
      ..hostname = _hostnameController.text.trim();

    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final embed = TailscaleEmbed.instance;
      if (_enabled) {
        final int port;
        if (await embed.activeIdentity() != Settings.instance.identity) {
          // Identity switch (or first start): ensure() notices the config
          // now names a different identity and swaps the running node.
          port = await embed.ensure();
        } else {
          // Same identity — restart so a changed key/hostname takes
          // effect. The auth key is only consumed on first registration;
          // afterwards the persisted node identity is reused and the key
          // may even be left empty.
          await embed.stop();
          port = await embed.start();
        }
        final st = await embed.status();
        final self = st?.self;
        setState(() {
          _status = self != null
              ? 'Connected as '
                  '${self.dnsName.isNotEmpty ? self.dnsName : self.hostName} '
                  '(${self.ips.join(', ')}) — identity '
                  '"${st!.identity ?? '?'}" — '
                  '${st.onlinePeerCount}/${st.peers.length} peers online, '
                  'proxy on port $port'
              : 'Connected — local proxy on port $port';
          // onKeyConsumed cleared the stored key; reflect that in the field.
          _keyController.text = Settings.instance.authKey;
        });
      } else {
        await embed.stop();
        setState(() => _status = 'Tailscale disabled');
      }
    } catch (error) {
      setState(() => _status = TailscaleAuthKeys.friendlyError(error));
    } finally {
      await _refreshIdentities();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tailscale')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('Embedded Tailscale node'),
            subtitle: const Text(
                'Browser traffic to tailnet hosts is tunneled through it'),
            value: _enabled,
            onChanged: _busy ? null : (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _identityController,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Identity (profile)',
              helperText: 'Each identity is its own node with its own state '
                  'and auth key — switching identities switches the node.',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => _selectIdentity(v.trim()),
            onEditingComplete: () {
              _selectIdentity(_identityController.text.trim());
              FocusScope.of(context).unfocus();
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _keyController,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Auth key',
              hintText: 'tskey-auth-…',
              helperText: 'Needed once — the node identity persists across '
                  'restarts, so a single-use key is fine.',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _hostnameController,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Device hostname on the tailnet',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _apply,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Apply'),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _status!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ),
          if (_identities.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'Enrolled identities',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            for (final name in _identities)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(name),
                leading: const Icon(Icons.badge_outlined),
                onTap: _busy ? null : () => _selectIdentity(name),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _busy ? null : () => _deleteIdentity(name),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
