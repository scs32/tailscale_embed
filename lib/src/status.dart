/// A snapshot of the embedded node's state, for consumer UIs (settings
/// pages, connection indicators, peer pickers). Produced by
/// `TailscaleEmbed.status()`.
class TailscaleStatus {
  /// Whether the embedded node and its local proxy are running.
  final bool running;

  /// The local proxy port, or 0 when not running.
  final int proxyPort;

  /// The ipn backend state string: `Running`, `Starting`, `NeedsLogin`,
  /// `Stopped`, …
  final String backendState;

  /// Health warnings reported by the node (empty when healthy).
  final List<String> health;

  /// Tailnet name (e.g. `example.com`), if known.
  final String? tailnetName;

  /// MagicDNS suffix (e.g. `tail1234.ts.net`), if known.
  final String? magicDnsSuffix;

  /// This node, if the backend has one.
  final TailscaleNode? self;

  /// All peers visible to this node.
  final List<TailscaleNode> peers;

  const TailscaleStatus({
    required this.running,
    this.proxyPort = 0,
    this.backendState = '',
    this.health = const [],
    this.tailnetName,
    this.magicDnsSuffix,
    this.self,
    this.peers = const [],
  });

  bool get isHealthy => running && backendState == 'Running' && health.isEmpty;

  int get onlinePeerCount => peers.where((p) => p.online).length;

  factory TailscaleStatus.fromJson(Map<String, dynamic> json) {
    return TailscaleStatus(
      running: json['running'] as bool? ?? false,
      proxyPort: json['proxyPort'] as int? ?? 0,
      backendState: json['backendState'] as String? ?? '',
      health: (json['health'] as List?)?.cast<String>() ?? const [],
      tailnetName: (json['tailnet'] as Map?)?['name'] as String?,
      magicDnsSuffix: (json['tailnet'] as Map?)?['magicDNSSuffix'] as String?,
      self: json['self'] != null
          ? TailscaleNode.fromJson((json['self'] as Map).cast())
          : null,
      peers: (json['peers'] as List?)
              ?.map((p) => TailscaleNode.fromJson((p as Map).cast()))
              .toList() ??
          const [],
    );
  }
}

/// One node (self or peer) on the tailnet.
class TailscaleNode {
  /// The node's hostname.
  final String hostName;

  /// The node's MagicDNS FQDN without trailing dot, e.g.
  /// `truenas.tail1234.ts.net`.
  final String dnsName;

  /// The node's tailnet IPs as strings (IPv4 first when present).
  final List<String> ips;

  /// Whether the node is connected to the control plane.
  final bool online;

  /// Subnet routes this node currently serves (subnet routers only).
  final List<String> routes;

  const TailscaleNode({
    required this.hostName,
    required this.dnsName,
    required this.ips,
    required this.online,
    this.routes = const [],
  });

  factory TailscaleNode.fromJson(Map<String, dynamic> json) {
    return TailscaleNode(
      hostName: json['hostName'] as String? ?? '',
      dnsName: json['dnsName'] as String? ?? '',
      ips: (json['ips'] as List?)?.cast<String>() ?? const [],
      online: json['online'] as bool? ?? false,
      routes: (json['routes'] as List?)?.cast<String>() ?? const [],
    );
  }
}
