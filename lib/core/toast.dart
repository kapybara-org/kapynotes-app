import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// A small, transient confirmation that floats above the app.
///
/// Deliberately not a [SnackBar]: on desktop a full-width bar sliding up from
/// the bottom edge reads as a phone pattern, and copying a result should be
/// acknowledged as quietly as possible.
class Toast {
  const Toast._();

  static OverlayEntry? _current;
  static int _generation = 0;

  static void show(
    BuildContext context,
    String message, {
    IconData icon = Icons.check_rounded,
    bool isError = false,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _dismiss();
    final generation = ++_generation;
    final entry = OverlayEntry(
      builder: (context) =>
          _ToastBody(message: message, icon: icon, isError: isError),
    );
    _current = entry;
    overlay.insert(entry);

    Future.delayed(const Duration(milliseconds: 1800), () {
      if (_generation == generation) _dismiss();
    });
  }

  static void _dismiss() {
    _current?.remove();
    _current = null;
  }
}

class _ToastBody extends StatefulWidget {
  const _ToastBody({
    required this.message,
    required this.icon,
    required this.isError,
  });

  final String message;
  final IconData icon;
  final bool isError;

  @override
  State<_ToastBody> createState() => _ToastBodyState();
}

class _ToastBodyState extends State<_ToastBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Positioned(
      bottom: 28 + MediaQuery.of(context).padding.bottom,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.35),
              end: Offset.zero,
            ).animate(curve),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: palette.surfaceBackground,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: palette.controlBorder, width: 0.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? 0.20 : 0.08),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.icon,
                      size: AppControlMetrics.iconAdornment,
                      color: widget.isError
                          ? Theme.of(context).colorScheme.error
                          : palette.chipCurrency,
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Text(
                        widget.message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTypeScale.body,
                          color: palette.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
