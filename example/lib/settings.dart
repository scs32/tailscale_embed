import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

/// App settings backed by SharedPreferences. The tailscale_embed package
/// never owns storage — this implements [TailscaleSettingsStore] so the
/// package's settings panel reads/writes here, and the config provider in
/// main.dart reads the same values.
class Settings implements TailscaleSettingsStore {
  Settings._(this._prefs);
  static late Settings instance;

  final SharedPreferences _prefs;

  static Future<void> load() async {
    instance = Settings._(await SharedPreferences.getInstance());
  }

  @override
  bool get enabled => _prefs.getBool('ts_enabled') ?? false;
  @override
  set enabled(bool v) => _prefs.setBool('ts_enabled', v);

  /// The selected identity (profile). Auth key and hostname are stored per
  /// identity; 'default' keeps the original un-suffixed pref keys so
  /// pre-identity installs keep their settings.
  @override
  String get identity => _prefs.getString('ts_identity') ?? 'default';
  @override
  set identity(String v) => _prefs.setString('ts_identity', v);

  String _keyFor(String base, String id) =>
      id == 'default' ? base : '$base.$id';

  @override
  String authKeyFor(String id) =>
      _prefs.getString(_keyFor('ts_auth_key', id)) ?? '';
  @override
  void setAuthKey(String id, String v) =>
      _prefs.setString(_keyFor('ts_auth_key', id), v);

  /// Clears the stored auth key for [id] regardless of which identity is
  /// currently selected — onKeyConsumed may fire for a start that raced a
  /// profile switch.
  void clearAuthKey(String id) => _prefs.remove(_keyFor('ts_auth_key', id));

  @override
  String hostnameFor(String id) =>
      _prefs.getString(_keyFor('ts_hostname', id)) ??
      (id == 'default' ? 'ts-browser' : 'ts-browser-$id');
  @override
  void setHostname(String id, String v) =>
      _prefs.setString(_keyFor('ts_hostname', id), v);

  String get authKey => authKeyFor(identity);
  String get hostname => hostnameFor(identity);

  String get lastUrl => _prefs.getString('last_url') ?? '';
  set lastUrl(String v) => _prefs.setString('last_url', v);
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tailscale')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // The package's ready-made panel: switch, per-identity key +
          // hostname fields, Apply (restart/stop semantics), status line,
          // enrolled-identities list.
          TailscaleSettingsPanel(store: Settings.instance),
        ],
      ),
    );
  }
}
