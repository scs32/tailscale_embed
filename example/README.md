# tailscale_browser

Example app for [`tailscale_embed`](../README.md): a minimal in-app browser
whose traffic — including WKWebView — flows through the embedded Tailscale
node, so it can reach `*.ts.net` hosts, tailnet IPs, and subnet-routed LANs.

Run it like any Flutter app (`flutter run` from this directory). To actually
join a tailnet, open the in-app settings and paste a `tskey-auth-…` auth key;
without one it still runs and browses the public web through the proxy. The
prebuilt Tailscale framework downloads automatically on first build.
