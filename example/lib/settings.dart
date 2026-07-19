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

  String get authKey => _prefs.getString('ts_auth_key') ?? '';
  set authKey(String v) => _prefs.setString('ts_auth_key', v);

  String get hostname => _prefs.getString('ts_hostname') ?? 'ts-browser';
  set hostname(String v) => _prefs.setString('ts_hostname', v);

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
  late final _keyController =
      TextEditingController(text: Settings.instance.authKey);
  late final _hostnameController =
      TextEditingController(text: Settings.instance.hostname);
  bool _busy = false;
  String? _status;

  @override
  void dispose() {
    _keyController.dispose();
    _hostnameController.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final key = _keyController.text.trim();
    final typeError = TailscaleAuthKeys.typeError(key);
    if (_enabled && typeError != null) {
      setState(() => _status = typeError);
      return;
    }

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
        // Restart so a changed key/hostname takes effect. The auth key is
        // only consumed on first registration; afterwards the persisted
        // node identity is reused and the key may even be left empty.
        await embed.stop();
        final port = await embed.start();
        setState(() => _status = 'Connected — local proxy on port $port');
      } else {
        await embed.stop();
        setState(() => _status = 'Tailscale disabled');
      }
    } catch (error) {
      setState(() => _status = TailscaleAuthKeys.friendlyError(error));
    } finally {
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
        ],
      ),
    );
  }
}
