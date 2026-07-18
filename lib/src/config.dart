/// The host app's Tailscale settings, read on demand so the package never
/// owns storage — supply values from your own settings store.
class TailscaleConfig {
  /// Whether the user has enabled the embedded node.
  final bool enabled;

  /// One-time node auth key (`tskey-auth-…`). Only needed until the node's
  /// persisted identity exists; may be empty afterwards.
  final String authKey;

  /// The tailnet hostname the embedded node registers as.
  final String hostname;

  const TailscaleConfig({
    required this.enabled,
    required this.authKey,
    this.hostname = 'tailscale-embed',
  });
}

typedef TailscaleConfigProvider = TailscaleConfig Function();
