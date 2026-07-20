/// `package:http` half of tailscale_embed: [TailscaleClient], a client-agnostic
/// wrapper that routes tailnet requests through the embedded node's local proxy
/// while leaving every other request on your own `http.Client` — including a
/// native one (`cupertino_http`, `cronet_http`, `win_http`).
///
/// Global [TailscaleHttpOverrides] only captures clients built on `dart:io`'s
/// `HttpClient` (`IOClient`, and `package:http`/Dio *when they use it*). Apps
/// that pick a native client for HTTP/2, background sessions, or connection
/// pooling ride `NSURLSession`/Cronet/WinHTTP instead, so `HttpOverrides`
/// captures none of their traffic. Wrap that client in a [TailscaleClient] and
/// tailnet hosts get the proxy while public traffic keeps the native stack.
///
/// Import this only from `dart:io` platforms (mobile/desktop), typically via a
/// conditional import.
library tailscale_embed_http;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'src/overrides_io.dart';

export 'src/overrides_io.dart' show isTailscaleHost, isPossibleTailnetShortName;

/// An [http.Client] that sends tailnet destinations (`*.ts.net`, the
/// `100.64.0.0/10` / `fd7a:115c:a1e0::/48` ranges, and bare MagicDNS short
/// names like `truenas-ts`) through the embedded node's local HTTP CONNECT
/// proxy, and forwards everything else to [inner] unchanged.
///
/// This is the drop-in for apps that don't ride `dart:io` — a native client
/// (`CupertinoClient`, `CronetClient`, …) or any custom [http.Client] that
/// global [TailscaleHttpOverrides] can't reach. Non-tailnet requests keep
/// [inner]'s behavior (HTTP/2, native connection pooling, TLS pinning, …);
/// only tailnet requests are diverted, over a small `dart:io` client whose
/// proxy port is read live per request, so an iOS socket rebind needs no
/// reconfiguration.
///
/// ```dart
/// // Keep your native client for the public internet; tailnet Just Works.
/// final http.Client client = TailscaleClient(CupertinoClient.defaultSessionConfiguration());
/// await client.get(Uri.parse('http://truenas-ts/'));       // → embedded proxy
/// await client.get(Uri.parse('https://example.com/'));     // → CupertinoClient
/// ```
///
/// The routing decision is by host only, independent of whether the node is
/// currently up: a tailnet host is unreachable without the node regardless, so
/// it always takes the proxy path (which fails fast, and MagicDNS short names
/// can only ever resolve there).
class TailscaleClient extends http.BaseClient {
  /// The client every non-tailnet request is forwarded to. Defaults to a
  /// plain [http.Client] (an `IOClient` on `dart:io`); pass your native or
  /// pre-configured client to preserve its behavior for public traffic.
  final http.Client inner;

  /// Whether [close] also closes [inner]. Default true. Set false when [inner]
  /// is shared and owned elsewhere.
  final bool closeInner;

  /// Bound on concurrent connections the internal tunnel [HttpClient] opens to
  /// a single host, applied before [configureTunnelClient]. The tunnel is
  /// HTTP/1.1 with keep-alive, so requests past this cap queue and reuse
  /// pooled connections instead of opening one per request — which matters for
  /// bursts of many small requests to the same tailnet host (a poster/artwork
  /// grid hitting one media server). Raise it for grid-heavy apps; `dart:io`'s
  /// own default is unbounded, which is the footgun this replaces.
  final int maxConnectionsPerHost;

  /// A sane default per-host connection cap for the tunnel. Grid/thumbnail-
  /// heavy apps (media libraries) may want to raise this via
  /// [TailscaleClient.custom] — e.g. `maxConnectionsPerHost: 12`.
  static const int defaultMaxConnectionsPerHost = 6;

  /// Applied to the internal `dart:io` [HttpClient] that carries tailnet
  /// requests — mirror any [inner]-side settings that must also hold on the
  /// tailnet path (user agent header hooks, `badCertificateCallback`, …). Runs
  /// after [maxConnectionsPerHost] is set, so it can override it too.
  final void Function(HttpClient client)? configureTunnelClient;

  IOClient? _tunnel;
  bool _closed = false;

  TailscaleClient([
    http.Client? inner,
  ])  : inner = inner ?? http.Client(),
        closeInner = true,
        maxConnectionsPerHost = defaultMaxConnectionsPerHost,
        configureTunnelClient = null;

  /// Full-control constructor: choose whether [close] cascades to [inner], tune
  /// the tunnel's [maxConnectionsPerHost], and configure its [HttpClient].
  TailscaleClient.custom({
    required this.inner,
    this.closeInner = true,
    this.maxConnectionsPerHost = defaultMaxConnectionsPerHost,
    this.configureTunnelClient,
  });

  /// Whether [url] would be routed through the embedded proxy rather than
  /// [inner]. Exposed so callers can reason about a request before sending.
  static bool routesThroughTailnet(Uri url) =>
      isTailscaleHost(url.host) || isPossibleTailnetShortName(url.host);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_closed) {
      throw StateError('TailscaleClient has been closed');
    }
    if (routesThroughTailnet(request.url)) {
      return (_tunnel ??= _buildTunnel()).send(request);
    }
    return inner.send(request);
  }

  IOClient _buildTunnel() {
    final httpClient = HttpClient()
      ..findProxy = tailscaleFindProxy
      ..maxConnectionsPerHost = maxConnectionsPerHost;
    configureTunnelClient?.call(httpClient);
    return IOClient(httpClient);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _tunnel?.close();
    if (closeInner) inner.close();
  }
}
