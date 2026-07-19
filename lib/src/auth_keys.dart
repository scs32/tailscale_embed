import 'package:flutter/services.dart';

/// Stable error codes emitted by the native side (originating in the Go
/// layer as `tsembed:CODE:` prefixes, parsed into `PlatformException.code`).
/// Match on these, not on error message text.
class TailscaleErrorCodes {
  const TailscaleErrorCodes._();

  /// Control plane unreachable or authentication timed out.
  static const authTimeout = 'AUTH_TIMEOUT';

  /// The auth key is invalid, expired, or already used.
  static const authKeyInvalid = 'AUTH_KEY_INVALID';

  /// An API token / OAuth secret was supplied instead of a node auth key.
  static const authKeyWrongType = 'AUTH_KEY_WRONG_TYPE';

  /// Any other tsnet startup failure.
  static const startFailed = 'START_FAILED';

  /// The local proxy listener could not be bound.
  static const proxyBindFailed = 'PROXY_BIND_FAILED';

  /// The operation requires a running node.
  static const notRunning = 'NOT_RUNNING';
}

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
  /// Prefers the stable [TailscaleErrorCodes] carried in
  /// [PlatformException.code]; falls back to matching error text for errors
  /// that didn't come through the platform channel.
  static String friendlyError(Object error) {
    final code = error is PlatformException ? error.code : null;
    final raw = error.toString();

    if (code == TailscaleErrorCodes.authKeyWrongType ||
        raw.contains('cannot be used for node auth')) {
      return 'That key cannot register a device — use an Auth key '
          '(tskey-auth-…) from Settings > Keys. Toggle again to retry.';
    }
    if (code == TailscaleErrorCodes.authKeyInvalid ||
        raw.contains('invalid key')) {
      return 'The auth key is invalid, expired, or already used. Generate a '
          'new one and toggle again.';
    }
    if (code == TailscaleErrorCodes.authTimeout ||
        raw.contains('timeout') ||
        raw.contains('deadline')) {
      return 'Timed out reaching Tailscale — check your connection and '
          'toggle again.';
    }
    if (code == TailscaleErrorCodes.notRunning) {
      return 'The embedded Tailscale node is not running. Toggle it on '
          'to reconnect.';
    }
    final detail =
        error is PlatformException ? (error.message ?? raw) : raw;
    return 'Could not connect ($detail). Toggle again to retry with a new key.';
  }
}
