import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'platform.dart';
import '../ui/floating_surface.dart';
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

  /// What a toast keeps above, such as a phone's bar and its +, or the
  /// format bar over the keyboard: whichever reaches highest.
  static final Set<_ToastClearanceState> _clearances = {};

  /// Widget tests usually call `pumpAndSettle` before inspecting a toast. A
  /// production lifetime animation would make that helper advance all the way
  /// through dismissal, so tests keep transient messages still unless the
  /// toast-specific suite opts in to exercising their lifetime.
  @visibleForTesting
  static bool debugAnimateLifetimeInTests = false;

  /// How long a toast with an action stays: time enough to reach it.
  static const Duration actionLifetime = Duration(seconds: 4);

  /// How wide a phone's card grows: the width of its bar and +, which on a
  /// tablet stops here.
  static const double _cardMaxWidth = 480;

  /// The action's height, which a phone's card lines its icon and first
  /// line up with.
  static const double _actionHeight = 28;

  /// [action] names a button at the toast's end that runs [onAction], such
  /// as View after a note is filed away. A toast with one stays a little
  /// longer, so there is time to reach it.
  static void show(
    BuildContext context,
    String message, {
    KapyIconData? icon,
    bool isError = false,
    String? action,
    VoidCallback? onAction,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    showOn(
      overlay,
      message,
      icon: icon,
      isError: isError,
      action: action,
      onAction: onAction,
    );
  }

  /// [show] on an overlay held from earlier, for a result that comes after
  /// the sheet or page that started the work has closed.
  static void showOn(
    OverlayState overlay,
    String message, {
    KapyIconData? icon,
    bool isError = false,
    String? action,
    VoidCallback? onAction,
  }) {
    if (!overlay.mounted) return;
    _showOn(
      overlay,
      message,
      icon: icon,
      isError: isError,
      progress: false,
      duration: action == null
          ? const Duration(milliseconds: 1800)
          : actionLifetime,
      action: action == null || onAction == null ? null : (action, onAction),
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
      icon: KapyIcons.hourglassRounded,
      isError: false,
      progress: true,
      duration: null,
    );
    return ToastProgress._(overlay, generation);
  }

  static int _showOn(
    OverlayState overlay,
    String message, {
    required KapyIconData? icon,
    required bool isError,
    required bool progress,
    required Duration? duration,
    (String, VoidCallback)? action,
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
        action: action == null
            ? null
            : (
                action.$1,
                () {
                  if (_generation == generation) _dismiss();
                  action.$2();
                },
              ),
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
    required KapyIconData? icon,
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

  void success(String message, {KapyIconData? icon}) => Toast._complete(
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
    icon: KapyIcons.errorOutlined,
    isError: true,
  );

  /// Removes the waiting state without replacing it, for a cancelled picker or
  /// a route that went away before the work had a result to announce.
  void dismiss() => Toast._dismissProgress(_generation);
}

class _ToastBody extends StatefulWidget {
  const _ToastBody({
    required this.message,
    this.icon,
    required this.isError,
    required this.progress,
    required this.duration,
    required this.onElapsed,
    required this.onDisposed,
    this.action,
  });

  final String message;

  /// Null for the notice's own: a tick, or a warning for an error, on a
  /// desktop, and on a phone a warning for an error and nothing otherwise.
  final KapyIconData? icon;
  final bool isError;
  final bool progress;
  final (String, VoidCallback)? action;
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
      _lifetimeController =
          AnimationController(
              vsync: this,
              duration: duration,
              animationBehavior: AnimationBehavior.preserve,
            )
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
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    final dark = Theme.of(context).brightness == Brightness.dark;
    // A desktop's toast is a pill sized to its words. A phone's is a card as
    // wide as the bar and its +, with an icon only where the notice brings
    // one and no colour for an error but its words.
    final desktop = AppPlatform.hasPointer;
    final statusColor = widget.isError ? scheme.error : scheme.primary;
    final surfaceColor = Color.alphaBlend(
      palette.textPrimary.withValues(alpha: dark ? 0.055 : 0.035),
      palette.surfaceBackground,
    );

    final media = MediaQuery.of(context);
    var clear = 0.0;
    for (final below in Toast._clearances) {
      final box = below.context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      clear = math.max(
        clear,
        media.size.height - box.localToGlobal(Offset.zero).dy + 16,
      );
    }
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontSize: AppTypeScale.body,
      color: palette.textPrimary,
      fontWeight: AppWeight.font(AppWeight.body),
      fontVariations: AppWeight.wght(AppWeight.body),
      height: 1.2,
    );
    final text = Text(
      widget.message,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: textStyle,
    );
    final button = switch (widget.action) {
      (final label, final onPressed) => TextButton(
        key: const ValueKey('toast-action'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: palette.accentText,
          minimumSize: const Size(0, Toast._actionHeight),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: TextStyle(
            fontSize: AppTypeScale.body,
            fontWeight: AppWeight.font(AppWeight.button),
            fontVariations: AppWeight.wght(AppWeight.button),
          ),
        ),
        child: Text(label),
      ),
      null => null,
    };

    final Widget content;
    if (desktop) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor.withValues(alpha: dark ? 0.14 : 0.10),
            ),
            child: widget.progress
                ? SizedBox.square(
                    key: const ValueKey('toast-progress-indicator'),
                    dimension: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.75,
                      color: statusColor,
                    ),
                  )
                : KapyIcon(
                    widget.icon ??
                        (widget.isError
                            ? KapyIcons.errorOutlined
                            : KapyIcons.checkRounded),
                    key: const ValueKey('toast-status-icon'),
                    size: 14,
                    color: statusColor,
                  ),
          ),
          const SizedBox(width: 9),
          Flexible(child: text),
          if (button != null) ...[
            const SizedBox(width: 4),
            button,
          ] else
            const SizedBox(width: 3),
        ],
      );
    } else {
      final icon =
          widget.icon ?? (widget.isError ? KapyIcons.errorOutlined : null);
      // The icon and the first line of words sit level with the action, so
      // words that wrap keep the action at the top.
      final line = media.textScaler.scale(AppTypeScale.body) * 1.2;
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.progress || icon != null) ...[
            SizedBox(
              height: Toast._actionHeight,
              child: Center(
                child: widget.progress
                    ? SizedBox.square(
                        key: const ValueKey('toast-progress-indicator'),
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.75,
                          color: palette.textSecondary,
                        ),
                      )
                    : KapyIcon(
                        icon!,
                        key: const ValueKey('toast-status-icon'),
                        size: 18,
                        color: palette.textSecondary,
                      ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                top: math.max(0, (Toast._actionHeight - line) / 2),
              ),
              child: text,
            ),
          ),
          if (button != null) ...[const SizedBox(width: 8), button],
        ],
      );
    }

    return Positioned(
      bottom: math.max(
        clear,
        (desktop ? 24 : 16) +
            math.max(media.padding.bottom, media.viewInsets.bottom),
      ),
      left: 16,
      right: 16,
      child: IgnorePointer(
        ignoring: widget.action == null,
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
                    minHeight: desktop ? 40 : 52,
                    maxWidth: math.max(
                      0,
                      math.min(
                        desktop ? 400 : Toast._cardMaxWidth,
                        media.size.width - 32,
                      ),
                    ),
                  ),
                  child: RepaintBoundary(
                    key: const ValueKey('toast-repaint-boundary'),
                    // The toast is an overlay entry too, with no route above
                    // it to hand its text a style: see [FloatingSurface]. Its
                    // own is complete enough today, and this is what keeps
                    // the next line added here from arriving underlined.
                    child: DefaultTextStyle(
                      style: FloatingSurface.textStyle(context),
                      child: Container(
                        key: const ValueKey('toast-surface'),
                        padding: desktop
                            ? const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              )
                            : EdgeInsets.fromLTRB(
                                16,
                                12,
                                button == null ? 16 : 8,
                                12,
                              ),
                        decoration: BoxDecoration(
                          color: surfaceColor,
                          borderRadius: BorderRadius.circular(
                            desktop ? AppRadii.pill : AppRadii.surface,
                          ),
                          border: Border.all(
                            color: palette.controlBorder.withValues(
                              alpha: dark ? 0.95 : 0.72,
                            ),
                            width: 0.75,
                          ),
                        ),
                        child: content,
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

/// Keeps toasts above [child], such as a phone's bar and its + or the format
/// bar over the keyboard, the highest of them on screen, while its
/// route is the one on top, and the page around its navigator too when a
/// [ToastClearanceScope] marks one. A sheet over it takes the toast back down
/// to the bottom edge, over the sheet's footer.
class ToastClearance extends StatefulWidget {
  const ToastClearance({super.key, required this.child});

  final Widget child;

  @override
  State<ToastClearance> createState() => _ToastClearanceState();
}

class _ToastClearanceState extends State<ToastClearance> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_OnTop.of(context) && (ModalRoute.of(context)?.isCurrent ?? true)) {
      Toast._clearances.add(this);
    } else {
      Toast._clearances.remove(this);
    }
  }

  @override
  void dispose() {
    Toast._clearances.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Wraps a navigator nested in a page, so a [ToastClearance] inside it also
/// steps aside while a sheet from an outer navigator covers that page.
class ToastClearanceScope extends StatelessWidget {
  const ToastClearanceScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _OnTop(
    onTop: _OnTop.of(context) && (ModalRoute.of(context)?.isCurrent ?? true),
    child: child,
  );
}

class _OnTop extends InheritedWidget {
  const _OnTop({required this.onTop, required super.child});

  final bool onTop;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_OnTop>()?.onTop ?? true;

  @override
  bool updateShouldNotify(_OnTop old) => onTop != old.onTop;
}
