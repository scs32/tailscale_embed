import 'package:flutter/material.dart';

import 'embed.dart';

/// Watches app lifecycle and ensures the embedded Tailscale node and its
/// local proxy are healthy whenever the app launches or returns to the
/// foreground (iOS reclaims the proxy's listener socket during suspension).
/// While (re)connecting, a blocking overlay is shown so requests aren't
/// fired into a dead proxy.
///
/// Mount it in your MaterialApp `builder`:
/// ```dart
/// builder: (context, child) => TailscaleGuard(child: child),
/// ```
class TailscaleGuard extends StatefulWidget {
  final Widget? child;

  /// Called when connecting fails (log it, show a snackbar, …).
  final void Function(Object error, StackTrace stack)? onError;

  /// Replaces the default "Connecting to Tailscale…" overlay.
  final WidgetBuilder? overlayBuilder;

  const TailscaleGuard({
    super.key,
    required this.child,
    this.onError,
    this.overlayBuilder,
  });

  @override
  State<TailscaleGuard> createState() => _TailscaleGuardState();
}

class _TailscaleGuardState extends State<TailscaleGuard>
    with WidgetsBindingObserver {
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ensure();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _ensure();
  }

  Future<void> _ensure() async {
    final embed = TailscaleEmbed.instance;
    if (!embed.isEnabled) return;
    if (_connecting) return;

    setState(() => _connecting = true);
    try {
      await embed.ensure();
    } catch (error, stack) {
      widget.onError?.call(error, stack);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (widget.child != null) widget.child!,
        if (_connecting)
          Positioned.fill(
            child: AbsorbPointer(
              child: widget.overlayBuilder?.call(context) ?? _defaultOverlay(),
            ),
          ),
      ],
    );
  }

  Widget _defaultOverlay() {
    return Material(
      color: Colors.black.withOpacity(0.65),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text(
            'Connecting to Tailscale…',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
    );
  }
}
