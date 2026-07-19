/// The host app's Tailscale settings, read on demand so the package never
/// owns storage — supply values from your own settings store.
class TailscaleConfig {
  /// Whether the user has enabled the embedded node.
  final bool enabled;

  /// One-time node auth key (`tskey-auth-…`). Only needed until the node's
  /// persisted identity exists; may be empty afterwards. Listen for
  /// `onKeyConsumed` (see `TailscaleEmbed.configure`) to know when it is
  /// safe to delete the key from your settings store.
  final String authKey;

  /// The tailnet hostname the embedded node registers as.
  final String hostname;

  /// Register the node as ephemeral: it deregisters from the tailnet when
  /// it disconnects, and its identity does not persist. Default false —
  /// a persistent identity means the auth key is only needed once.
  final bool ephemeral;

  /// How long `start()` may block waiting for the node to authenticate and
  /// come up before failing with a timeout.
  final Duration upTimeout;

  /// Dial destinations inside peer-advertised subnet routes (e.g.
  /// `192.168.1.0/24` behind a subnet router) through the tailnet. Default
  /// true: always correct — at worst a same-LAN destination hairpins
  /// through its subnet router. Set false to dial LAN-looking IPs directly.
  final bool acceptRoutes;

  /// Logical name of the node identity this config uses. Each identity has
  /// its own tailscaled state — its own node, auth key, and possibly a
  /// different tailnet. When the provider starts returning a different
  /// identity, the next `ensure()`/`start()` stops the running node and
  /// starts the new identity's (fresh enroll via [authKey] if that identity
  /// has no state yet).
  ///
  /// A logical label, not a path — the plugin owns the on-disk layout. Must
  /// match `[A-Za-z0-9][A-Za-z0-9._-]*` (max 64 chars); slugify free-form
  /// profile names before passing them here. The default `'default'` maps
  /// to the pre-identity state location, so existing single-identity
  /// installs keep their node across the upgrade.
  final String identity;

  const TailscaleConfig({
    required this.enabled,
    required this.authKey,
    this.hostname = 'tailscale-embed',
    this.ephemeral = false,
    this.upTimeout = const Duration(seconds: 45),
    this.acceptRoutes = true,
    this.identity = 'default',
  });
}

typedef TailscaleConfigProvider = TailscaleConfig Function();
