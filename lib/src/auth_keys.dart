/// Auth-key validation and human-readable error mapping for tsnet failures.
class TailscaleAuthKeys {
  const TailscaleAuthKeys._();

  /// Returns an error message if [key] is recognizably NOT a node auth key,
  /// or null if it looks usable. API tokens and OAuth secrets share the
  /// `tskey-` prefix but cannot register devices — catch them before
  /// dialing out.
  static String? typeError(String key) {
    if (key.startsWith('tskey-api-')) {
      return 'That is an API access token. Generate an "Auth key" instead '
          '(starts with tskey-auth-) at login.tailscale.com under '
          'Settings > Keys.';
    }
    if (key.startsWith('tskey-client-')) {
      return 'That is an OAuth client secret. Generate an "Auth key" instead '
          '(starts with tskey-auth-) at login.tailscale.com under '
          'Settings > Keys.';
    }
    return null;
  }

  /// Translates tsnet/platform errors into something a person can act on.
  static String friendlyError(Object error) {
    final raw = error.toString();
    if (raw.contains('cannot be used for node auth')) {
      return 'That key cannot register a device — use an Auth key '
          '(tskey-auth-…) from Settings > Keys. Toggle again to retry.';
    }
    if (raw.contains('invalid key')) {
      return 'The auth key is invalid, expired, or already used. Generate a '
          'new one and toggle again.';
    }
    if (raw.contains('timeout') || raw.contains('deadline')) {
      return 'Timed out reaching Tailscale — check your connection and '
          'toggle again.';
    }
    return 'Could not connect ($raw). Toggle again to retry with a new key.';
  }
}
