import 'package:flutter/material.dart';

import 'auth_keys.dart';
import 'embed.dart';

/// The settings the panel reads and writes. The package never owns storage —
/// implement this over your own store (SharedPreferences, a profile object,
/// …). Auth key and hostname are per identity, because each identity is its
/// own node with its own key.
///
/// Writes happen when the user taps Apply (and on identity selection for
/// [identity] itself); your `TailscaleConfigProvider` should read from the
/// same store so the applied config matches what was saved.
abstract class TailscaleSettingsStore {
  bool get enabled;
  set enabled(bool value);

  /// The selected identity. See `TailscaleConfig.identity` for the allowed
  /// name shape.
  String get identity;
  set identity(String value);

  String authKeyFor(String identity);
  void setAuthKey(String identity, String value);

  String hostnameFor(String identity);
  void setHostname(String identity, String value);
}

/// A ready-made Tailscale settings panel: enabled switch, per-identity auth
/// key and hostname fields with key-type validation, an Apply button with
/// the right apply semantics (`restart()` when enabled — which covers both
/// same-identity settings changes and identity switches — `stop()` when
/// disabled), a connection status line, and the enrolled-identities list
/// (tap to select, trash to delete).
///
/// It renders as a plain [Column], so embed it in your own page/ListView:
///
/// ```dart
/// ListView(children: const [TailscaleSettingsPanel(store: myStore)])
/// ```
///
/// The auth-key field re-reads the store after a successful apply, so a key
/// cleared by your `onKeyConsumed` handler empties on screen by itself.
class TailscaleSettingsPanel extends StatefulWidget {
  final TailscaleSettingsStore store;

  /// Hide the identity field (and the enrolled-identities list) when your
  /// app drives [TailscaleSettingsStore.identity] itself, e.g. from a
  /// profile switcher.
  final bool showIdentity;

  /// Called after a successful apply (also when applying "disabled").
  final VoidCallback? onApplied;

  const TailscaleSettingsPanel({
    super.key,
    required this.store,
    this.showIdentity = true,
    this.onApplied,
  });

  @override
  State<TailscaleSettingsPanel> createState() => _TailscaleSettingsPanelState();
}

class _TailscaleSettingsPanelState extends State<TailscaleSettingsPanel> {
  late bool _enabled = widget.store.enabled;
  late final _identityController =
      TextEditingController(text: widget.store.identity);
  late final _keyController =
      TextEditingController(text: widget.store.authKeyFor(widget.store.identity));
  late final _hostnameController = TextEditingController(
      text: widget.store.hostnameFor(widget.store.identity));
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
    widget.store.identity = identity;
    setState(() {
      _identityController.text = identity;
      _keyController.text = widget.store.authKeyFor(identity);
      _hostnameController.text = widget.store.hostnameFor(identity);
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

    final store = widget.store;
    final identity = _identityController.text.trim();
    store.identity = identity.isEmpty ? 'default' : identity;
    store.enabled = _enabled;
    store.setAuthKey(store.identity, key);
    store.setHostname(store.identity, _hostnameController.text.trim());

    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final embed = TailscaleEmbed.instance;
      if (_enabled) {
        // restart() applies the provider's current config whatever changed:
        // it stops any running node (same identity or not) and starts from
        // the new config, rolling back to the old one on failure.
        final port = await embed.restart();
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
          // onKeyConsumed may have cleared the stored key; reflect that.
          _keyController.text = store.authKeyFor(store.identity);
        });
      } else {
        await embed.stop();
        setState(() => _status = 'Tailscale disabled');
      }
      widget.onApplied?.call();
    } catch (error) {
      setState(() => _status = TailscaleAuthKeys.friendlyError(error));
    } finally {
      await _refreshIdentities();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          title: const Text('Embedded Tailscale node'),
          subtitle:
              const Text('Traffic to tailnet hosts is tunneled through it'),
          value: _enabled,
          onChanged: _busy ? null : (v) => setState(() => _enabled = v),
        ),
        if (widget.showIdentity) ...[
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
        ],
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
        if (widget.showIdentity && _identities.isNotEmpty) ...[
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
    );
  }
}
