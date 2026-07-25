/// A snapshot of the embedded node's state, for consumer UIs (settings
/// pages, connection indicators, peer pickers). Produced by
/// `TailscaleEmbed.status()`.
class TailscaleStatus {
  /// Whether the embedded node and its local proxy are running.
  final bool running;

  /// The logical identity name this node's state belongs to, if known.
  final String? identity;

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

  /// Self-heal telemetry for the "ReceiveIPv4 not running" recovery path.
  /// Null when the node isn't running. Diagnostic — most apps can ignore it.
  final TailscaleRecovery? recovery;

  const TailscaleStatus({
    required this.running,
    this.identity,
    this.proxyPort = 0,
    this.backendState = '',
    this.health = const [],
    this.tailnetName,
    this.magicDnsSuffix,
    this.self,
    this.peers = const [],
    this.recovery,
  });

  bool get isHealthy => running && backendState == 'Running' && health.isEmpty;

  int get onlinePeerCount => peers.where((p) => p.online).length;

  factory TailscaleStatus.fromJson(Map<String, dynamic> json) {
    return TailscaleStatus(
      running: json['running'] as bool? ?? false,
      identity: json['identity'] as String?,
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
      recovery: json['recovery'] != null
          ? TailscaleRecovery.fromJson((json['recovery'] as Map).cast())
          : null,
    );
  }
}

/// Self-heal telemetry for the magicsock "ReceiveIPv4 not running" warning.
///
/// The dead-receive-path state only reproduces on real devices (iOS parks UDP
/// sockets on suspend/roam), so these counters exist to *attribute* a field
/// occurrence: when the warning clears, they say whether a magicsock rebind
/// and/or a full in-place node restart actually fired, and when. Timestamps are
/// UTC RFC 3339 strings; counts are cumulative over the current node's lifetime.
class TailscaleRecovery {
  /// Whether the health snapshot at read time still carries the dead-receive
  /// warning (the watchdog's trigger condition).
  final bool needsRebind;

  /// How many self-heal attempts the watchdog has made this episode (resets to
  /// 0 on a healthy read).
  final int healAttempts;

  /// Total magicsock rebinds performed (resume + path-change + self-heal).
  final int rebinds;

  /// UTC RFC 3339 timestamp of the last rebind, or null if none.
  final String? lastRebindAt;

  /// Reason string of the last rebind (`tsembed-resume`, `tsembed-pathchange`,
  /// `tsembed-selfheal`), or null.
  final String? lastRebindReason;

  /// Total full node restarts the watchdog has performed.
  final int restarts;

  /// UTC RFC 3339 timestamp of the last restart, or null if none.
  final String? lastRestartAt;

  /// Reason string of the last restart, or null.
  final String? lastRestartReason;

  const TailscaleRecovery({
    this.needsRebind = false,
    this.healAttempts = 0,
    this.rebinds = 0,
    this.lastRebindAt,
    this.lastRebindReason,
    this.restarts = 0,
    this.lastRestartAt,
    this.lastRestartReason,
  });

  factory TailscaleRecovery.fromJson(Map<String, dynamic> json) {
    return TailscaleRecovery(
      needsRebind: json['needsRebind'] as bool? ?? false,
      healAttempts: json['healAttempts'] as int? ?? 0,
      rebinds: json['rebinds'] as int? ?? 0,
      lastRebindAt: json['lastRebindAt'] as String?,
      lastRebindReason: json['lastRebindReason'] as String?,
      restarts: json['restarts'] as int? ?? 0,
      lastRestartAt: json['lastRestartAt'] as String?,
      lastRestartReason: json['lastRestartReason'] as String?,
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
