import 'dart:io';

import 'embed.dart';

/// Returns true if [host] is a tailnet destination: a MagicDNS FQDN
/// (*.ts.net), a Tailscale IPv4 address (CGNAT range 100.64.0.0/10), or a
/// Tailscale IPv6 address (fd7a:115c:a1e0::/48).
bool isTailscaleHost(String host) {
  if (host.endsWith('.ts.net')) return true;

  final ip = InternetAddress.tryParse(host);
  if (ip == null) return false;

  if (ip.type == InternetAddressType.IPv4) {
    final octets = ip.rawAddress;
    // 100.64.0.0/10 -> first octet 100, second octet 64-127
    return octets[0] == 100 && (octets[1] & 0xC0) == 0x40;
  }

  // fd7a:115c:a1e0::/48
  final v6 = ip.rawAddress;
  return v6[0] == 0xfd &&
      v6[1] == 0x7a &&
      v6[2] == 0x11 &&
      v6[3] == 0x5c &&
      v6[4] == 0xa1 &&
      v6[5] == 0xe0;
}

/// A `findProxy` callback that sends tailnet destinations to the embedded
/// node's local proxy and everything else direct. The port is read on every
/// request so clients created before the proxy started (or across a rebind)
/// always use the current port.
String tailscaleFindProxy(Uri uri) {
  final port = TailscaleEmbed.instance.proxyPort;
  if (port != null && isTailscaleHost(uri.host)) {
    return 'PROXY 127.0.0.1:$port';
  }
  return 'DIRECT';
}

/// Global [HttpOverrides] that routes tailnet traffic through the embedded
/// node. [configureClient] lets the host app apply its own client settings
/// (user agent, TLS validation, …) on top.
class TailscaleHttpOverrides extends HttpOverrides {
  final void Function(HttpClient client)? configureClient;

  TailscaleHttpOverrides({this.configureClient});

  /// Install these overrides globally. Captures every `dart:io HttpClient`
  /// in the app — including `package:http` and Dio on mobile — with no
  /// changes to request code.
  static void install({void Function(HttpClient client)? configureClient}) {
    HttpOverrides.global =
        TailscaleHttpOverrides(configureClient: configureClient);
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = tailscaleFindProxy;
    configureClient?.call(client);
    return client;
  }
}
