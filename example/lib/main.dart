import 'package:flutter/material.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

import 'browser_page.dart';
import 'settings.dart';

final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.load();

  TailscaleEmbed.instance.configure(
    config: () => TailscaleConfig(
      enabled: Settings.instance.enabled,
      authKey: Settings.instance.authKey,
      hostname: Settings.instance.hostname,
    ),
    // Route WKWebView traffic through the embedded node's local proxy
    // (re-applied automatically whenever the node starts or rebinds).
    webViewProxy: true,
    // The node identity persists after first registration, so the plaintext
    // auth key is no longer needed — delete it from storage.
    onKeyConsumed: () => Settings.instance.authKey = '',
  );

  runApp(const BrowserApp());
}

class BrowserApp extends StatelessWidget {
  const BrowserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tailscale Browser',
      scaffoldMessengerKey: scaffoldMessengerKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4B70CC),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      builder: (context, child) => TailscaleGuard(
        onError: (error, stack) {
          scaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(content: Text(TailscaleAuthKeys.friendlyError(error))),
          );
        },
        child: child,
      ),
      home: const BrowserPage(),
    );
  }
}
