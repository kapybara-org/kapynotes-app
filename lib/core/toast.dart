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
    IconData? icon,
    bool isError = false,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _showOn(
      overlay,
      message,
      icon:
          icon ?? (isError ? Icons.error_outline_rounded : Icons.check_rounded),
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
    final scheme = Theme.of(context).colorScheme;
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final compact = AppPlatform.hasPointer;
    final statusColor = widget.isError ? scheme.error : scheme.primary;
    final surfaceColor = Color.alphaBlend(
      palette.textPrimary.withValues(alpha: dark ? 0.055 : 0.035),
      palette.surfaceBackground,
    );

    final media = MediaQuery.of(context);
    return Positioned(
      bottom:
          (compact ? 24 : 16) +
          math.max(media.padding.bottom, media.viewInsets.bottom),
      left: 16,
      right: 16,
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
                    minHeight: compact ? 40 : 44,
                    maxWidth: math.max(0, math.min(400, media.size.width - 32)),
                  ),
                  child: RepaintBoundary(
                    key: const ValueKey('toast-repaint-boundary'),
                    child: Container(
                      key: const ValueKey('toast-surface'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: surfaceColor,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: palette.controlBorder.withValues(
                            alpha: dark ? 0.95 : 0.72,
                          ),
                          width: 0.75,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: compact ? 22 : 24,
                            height: compact ? 22 : 24,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: statusColor.withValues(
                                alpha: dark ? 0.14 : 0.10,
                              ),
                            ),
                            child: widget.progress
                                ? SizedBox.square(
                                    key: const ValueKey(
                                      'toast-progress-indicator',
                                    ),
                                    dimension: compact ? 12 : 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.75,
                                      color: statusColor,
                                    ),
                                  )
                                : Icon(
                                    widget.icon,
                                    key: const ValueKey('toast-status-icon'),
                                    size: compact ? 14 : 16,
                                    color: statusColor,
                                  ),
                          ),
                          const SizedBox(width: 9),
                          Flexible(
                            child: Text(
                              widget.message,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    fontSize: AppTypeScale.body,
                                    color: palette.textPrimary,
                                    fontWeight: FontWeight.w400,
                                    height: 1.2,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 3),
                        ],
                      ),
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
