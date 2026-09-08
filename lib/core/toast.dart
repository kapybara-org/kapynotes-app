import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'platform.dart';
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

  /// Widget tests usually call `pumpAndSettle` before inspecting a toast. A
  /// production lifetime animation would make that helper advance all the way
  /// through dismissal, so tests keep transient messages still unless the
  /// toast-specific suite opts in to exercising their lifetime.
  @visibleForTesting
  static bool debugAnimateLifetimeInTests = false;

  static void show(
    BuildContext context,
    String message, {
    IconData icon = Icons.check_rounded,
    bool isError = false,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _showOn(
      overlay,
      message,
      icon: icon,
      isError: isError,
      progress: false,
      duration: const Duration(milliseconds: 1800),
    );
  }

  /// Shows a persistent waiting state that the caller resolves explicitly.
  ///
  /// Holding the overlay rather than the caller's [BuildContext] matters for
  /// file pickers and dialogs: either can replace the route that started the
  /// work before the result comes back. A stale handle also cannot overwrite a
  /// newer toast, which keeps two overlapping actions from reporting in the
  /// wrong order.
  static ToastProgress showProgress(BuildContext context, String message) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return const ToastProgress._(null, -1);
    final generation = _showOn(
      overlay,
      message,
      icon: Icons.hourglass_top_rounded,
      isError: false,
      progress: true,
      duration: null,
    );
    return ToastProgress._(overlay, generation);
  }

  static int _showOn(
    OverlayState overlay,
    String message, {
    required IconData icon,
    required bool isError,
    required bool progress,
    required Duration? duration,
  }) {
    _dismiss();
    final generation = ++_generation;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _ToastBody(
        message: message,
        icon: icon,
        isError: isError,
        progress: progress,
        duration: AppPlatform.isFlutterTest && !debugAnimateLifetimeInTests
            ? null
            : duration,
        onElapsed: () {
          if (_generation == generation) _dismiss();
        },
        onDisposed: () {
          if (identical(_current, entry)) _current = null;
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
    return generation;
  }

  static void _complete(
    OverlayState? overlay,
    int generation,
    String message, {
    required IconData icon,
    required bool isError,
  }) {
    if (overlay == null || !overlay.mounted || generation != _generation) {
      return;
    }
    _showOn(
      overlay,
      message,
      icon: icon,
      isError: isError,
      progress: false,
      duration: const Duration(milliseconds: 1800),
    );
  }

  static void _dismissProgress(int generation) {
    if (generation != _generation) return;
    _generation++;
    _dismiss();
  }

  static void _dismiss() {
    final entry = _current;
    // An entry inserted and completed in the same event turn is not `mounted`
    // yet, but it is already owned by the overlay and still must be removed.
    // Checking `mounted` here strands exactly those fast progress states as an
    // invisible, endlessly animating spinner.
    entry?.remove();
    _current = null;
  }
}

/// The lifecycle of one user-visible asynchronous action.
class ToastProgress {
  const ToastProgress._(this._overlay, this._generation);

  final OverlayState? _overlay;
  final int _generation;

  void success(String message, {IconData icon = Icons.check_rounded}) =>
      Toast._complete(
        _overlay,
        _generation,
        message,
        icon: icon,
        isError: false,
      );

  void error(String message) => Toast._complete(
    _overlay,
    _generation,
    message,
    icon: Icons.error_outline_rounded,
    isError: true,
  );

  /// Removes the waiting state without replacing it, for a cancelled picker or
  /// a route that went away before the work had a result to announce.
  void dismiss() => Toast._dismissProgress(_generation);
}

class _ToastBody extends StatefulWidget {
  const _ToastBody({
    required this.message,
    required this.icon,
    required this.isError,
    required this.progress,
    required this.duration,
    required this.onElapsed,
    required this.onDisposed,
  });

  final String message;
  final IconData icon;
  final bool isError;
  final bool progress;
  final Duration? duration;
  final VoidCallback onElapsed;
  final VoidCallback onDisposed;

  @override
  State<_ToastBody> createState() => _ToastBodyState();
}

class _ToastBodyState extends State<_ToastBody> with TickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  )..forward();
  AnimationController? _lifetimeController;

  @override
  void initState() {
    super.initState();
    final duration = widget.duration;
    if (duration != null) {
      _lifetimeController = AnimationController(vsync: this, duration: duration)
        ..forward().then((_) {
          if (mounted) widget.onElapsed();
        });
    }
  }

  @override
  void dispose() {
    _lifetimeController?.dispose();
    _controller.dispose();
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    final dark = Theme.of(context).brightness == Brightness.dark;

    final media = MediaQuery.of(context);
    return Positioned(
      bottom: 28 + math.max(media.padding.bottom, media.viewInsets.bottom),
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
              child: Semantics(
                liveRegion: true,
                label: widget.message,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.max(0, math.min(420, media.size.width - 32)),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: palette.surfaceBackground,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: palette.controlBorder,
                        width: 0.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: dark ? 0.20 : 0.08,
                          ),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.progress)
                          SizedBox.square(
                            key: const ValueKey('toast-progress-indicator'),
                            dimension: AppControlMetrics.iconAdornment,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: palette.chipCurrency,
                            ),
                          )
                        else
                          Icon(
                            widget.icon,
                            size: AppControlMetrics.iconAdornment,
                            color: widget.isError
                                ? Theme.of(context).colorScheme.error
                                : palette.chipCurrency,
                          ),
                        const SizedBox(width: 8),
                        Flexible(
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
        ),
      ),
    );
  }
}
