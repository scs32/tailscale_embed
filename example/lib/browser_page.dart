import 'package:flutter/material.dart';
import 'package:tailscale_embed/tailscale_embed.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'settings.dart';

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  late final WebViewController _controller;
  final _urlController = TextEditingController();
  final _urlFocus = FocusNode();

  int _progress = 100;
  bool _hasPage = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => setState(() => _progress = p),
          onPageStarted: (url) {
            setState(() {
              _hasPage = true;
              if (!_urlFocus.hasFocus) _urlController.text = url;
            });
          },
          onPageFinished: (url) {
            Settings.instance.lastUrl = url;
            if (!_urlFocus.hasFocus) _urlController.text = url;
          },
          onWebResourceError: (error) {
            // Only surface main-frame failures; subresource noise is common.
            if (error.isForMainFrame ?? false) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Load failed: ${error.description}')),
              );
            }
          },
        ),
      );

    final last = Settings.instance.lastUrl;
    if (last.isNotEmpty && Settings.instance.enabled) {
      _urlController.text = last;
      _hasPage = true;
      _controller.loadRequest(Uri.parse(last));
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  /// Bare tailnet destinations (MagicDNS short names, *.ts.net, 100.x IPs)
  /// usually serve plain HTTP on a LAN-style setup; the public web wants
  /// HTTPS. Pick a scheme accordingly when the user omits one.
  Uri _normalize(String input) {
    var text = input.trim();
    if (text.contains('://')) return Uri.parse(text);
    final host = text.split('/').first.split(':').first;
    final looksTailnet = !host.contains('.') ||
        host.endsWith('.ts.net') ||
        RegExp(r'^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.').hasMatch(host);
    return Uri.parse('${looksTailnet ? 'http' : 'https'}://$text');
  }

  void _go(String input) {
    if (input.trim().isEmpty) return;
    _urlFocus.unfocus();
    setState(() => _hasPage = true);
    _controller.loadRequest(_normalize(input));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    setState(() {}); // refresh the connection indicator
  }

  @override
  Widget build(BuildContext context) {
    final connected = TailscaleEmbed.instance.proxyPort != null;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: TextField(
          controller: _urlController,
          focusNode: _urlFocus,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: _go,
          decoration: InputDecoration(
            hintText: 'hostname, name.ts.net, or URL',
            isDense: true,
            filled: true,
            prefixIcon: Icon(
              connected ? Icons.lock : Icons.lock_open,
              size: 18,
              color: connected ? Colors.greenAccent : Colors.orangeAccent,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: () async {
              if (await _controller.canGoBack()) _controller.goBack();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
        bottom: _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress / 100),
              )
            : null,
      ),
      body: _hasPage ? WebViewWidget(controller: _controller) : _landing(),
    );
  }

  Widget _landing() {
    final embed = TailscaleEmbed.instance;
    final configured = embed.isEnabled;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.travel_explore, size: 64),
            const SizedBox(height: 16),
            Text(
              configured
                  ? 'Enter a tailnet hostname or any URL above.'
                  : 'Set up the embedded Tailscale node first —\n'
                      'you\'ll need a one-time auth key (tskey-auth-…).',
              textAlign: TextAlign.center,
            ),
            if (!configured) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _openSettings,
                icon: const Icon(Icons.settings),
                label: const Text('Configure Tailscale'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
