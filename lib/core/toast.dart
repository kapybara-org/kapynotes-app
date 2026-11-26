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

  /// What the toast showing does once it goes without its action: see
  /// [show]'s onGone.
  static VoidCallback? _whenGone;

  /// What a toast keeps clear of: above a phone's bar and its +, or the
  /// format bar over the keyboard, whichever reaches highest, and on a
  /// desktop beside the notes list and Kapy AI's panel.
  static final Set<_ToastClearanceState> _clearances = {};

  /// The height a [ToastClearance.room] opens while a toast shows: the
  /// card's own, and 8 above and below it.
  static final ValueNotifier<double> _room = ValueNotifier(0);

  static final ValueNotifier<bool> _hidden = ValueNotifier(false);

  /// Hides the toast showing, its time paused, while [hidden]: a row's menu
  /// does while it is open, so the menu never sits under the toast nor uses
  /// up its Undo. A new toast shows, so a menu's own notice replaces it.
  static void hide(bool hidden) => _hidden.value = hidden;

  /// Builds the toast on screen again once the frame has laid out what it
  /// keeps clear of, which has just come or gone: a clearance changes
  /// mid-build or as it goes, too soon to rebuild anything then.
  static void _clearancesChanged() => WidgetsBinding.instance
      .addPostFrameCallback((_) => _current?.markNeedsBuild());

  /// Widget tests usually call `pumpAndSettle` before inspecting a toast. A
  /// production lifetime animation would make that helper advance all the way
  /// through dismissal, so tests keep transient messages still unless the
  /// toast-specific suite opts in to exercising their lifetime.
  @visibleForTesting
  static bool debugAnimateLifetimeInTests = false;

  /// How long a toast with an action stays: time enough to reach it.
  static const Duration actionLifetime = Duration(seconds: 4);

  /// How wide a phone's card grows. A phone's is narrower, so its card runs
  /// the width of its bar and +; from 720 pt, two panes and no bar, the card
  /// stops here, centred.
  static const double _cardMaxWidth = 480;

  /// The least room between what a desktop's toast keeps beside that it
  /// centres in: as much as the notes list always leaves the page beside it,
  /// so beside the list a toast always centres on the page. Where there is
  /// less, as beside the list or Kapy AI over a narrow window's page, it
  /// centres on the window instead.
  static const double _minRoomBeside = 320;

  /// The action's height, which a phone's card lines its icon and first
  /// line up with, and which its words keep to at least, so every card is
  /// the same height.
  static const double _actionHeight = 28;

  /// [action] names a button at the toast's end that runs [onAction], such
  /// as View after a note is filed away. A toast with one stays a little
  /// longer, so there is time to reach it.
  ///
  /// [onGone] runs once the toast goes without its action: its time up, or
  /// another toast in its place. A toast still showing when the app closes
  /// never goes that way, so what [onGone] would have done stays undone.
  static void show(
    BuildContext context,
    String message, {
    KapyIconData? icon,
    bool isError = false,
    String? action,
    VoidCallback? onAction,
    VoidCallback? onGone,
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
      onGone: onGone,
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
    VoidCallback? onGone,
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
      onGone: onGone,
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
    VoidCallback? onGone,
  }) {
    _current?.remove();
    _hidden.value = false;
    _gone();
    _whenGone = onGone;
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
                  if (_generation == generation) {
                    _whenGone = null;
                    _dismiss();
                  }
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
          if (!identical(_current, entry)) return;
          _current = null;
          _whenGone = null;
          // Its overlay went without [_dismiss], so its room goes once the
          // frame is done, for the next toast to open its own.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_current == null) _room.value = 0;
          });
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
    _room.value = 0;
    _gone();
  }

  static void _gone() {
    final whenGone = _whenGone;
    _whenGone = null;
    whenGone?.call();
  }

  /// Ends the toast showing as its time running out does, for a test that
  /// keeps toasts still: see [debugAnimateLifetimeInTests].
  @visibleForTesting
  static void debugTimeUp() => _dismiss();
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
  final _card = GlobalKey();
  bool _hidden = Toast._hidden.value;

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
            ..addStatusListener((status) {
              if (status == AnimationStatus.completed) widget.onElapsed();
            })
            ..forward();
    }
    Toast._hidden.addListener(_hiddenChanged);
  }

  void _hiddenChanged() {
    final lifetime = _lifetimeController;
    if (Toast._hidden.value) {
      lifetime?.stop();
      setState(() => _hidden = true);
      return;
    }
    if (lifetime != null && !lifetime.isCompleted) lifetime.forward();
    // What it keeps clear of comes back with the route under the menu in
    // the next frame, so the card shows the frame after, in its place.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (mounted) setState(() => _hidden = false);
      })
      ..scheduleFrame();
  }

  @override
  void dispose() {
    Toast._hidden.removeListener(_hiddenChanged);
    _lifetimeController?.dispose();
    _controller.dispose();
    widget.onDisposed();
    super.dispose();
  }

  /// Where the toast keeps: above the highest of what it keeps clear of,
  /// such as a phone's bar or the format bar, or in the room a sheet opens
  /// for it at its foot, by that room's bottom; and on a desktop, from left
  /// to right, the page between what it keeps beside: right of one on the
  /// window's left, as the notes list is, and left of one on its right, as
  /// Kapy AI's panel and a folder's Add notes are. The list slid shut keeps
  /// it nowhere. What it keeps clear of inside what it keeps beside, as the
  /// list's Notes and Folders switch, it keeps above only where it centres
  /// on the window over it.
  ({double clear, double? room, double left, double right}) _clear(
    MediaQueryData media,
  ) {
    final width = media.size.width;
    var clear = 0.0;
    var inside = 0.0;
    var left = 0.0;
    var right = width;
    for (final clearance in Toast._clearances) {
      final box = clearance.context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (clearance.widget.room) {
        return (clear: 0, room: rect.bottom, left: 0, right: width);
      }
      if (!clearance.widget.beside) {
        final above = media.size.height - rect.top + 16;
        final outer = clearance.context
            .findAncestorStateOfType<_ToastClearanceState>();
        if (outer == null || !outer.widget.beside) {
          clear = math.max(clear, above);
        } else if (outer.context.findRenderObject() case final RenderBox list
            when list.hasSize && list.size.width > 0) {
          inside = math.max(inside, above);
        }
      } else if (AppPlatform.hasPointer && rect.width > 0) {
        if (rect.center.dx < width / 2) {
          left = math.max(left, rect.right);
        } else {
          right = math.min(right, rect.left);
        }
      }
    }
    if (right - left < Toast._minRoomBeside) {
      return (
        clear: math.max(clear, inside),
        room: null,
        left: 0,
        right: width,
      );
    }
    return (clear: clear, room: null, left: left, right: right);
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
    final place = _clear(media);
    final (:clear, :room, :left, :right) = place;
    // What it keeps clear of was laid out a frame ago, so once this frame is,
    // a toast whose clearance moved under it, as a format bar does with the
    // keyboard and the notes list as it slides open, takes its new place. A
    // sheet's room opens to the card's height once the card has one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final card = _card.currentContext?.size?.height;
      if (card != null) Toast._room.value = card + 16;
      if (_clear(MediaQuery.of(context)) != place) setState(() {});
    });
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
          textStyle: textStyle?.copyWith(
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
      content = ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Toast._actionHeight),
        child: Row(
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
        ),
      );
    }

    // The card takes every tap on it, so none lands on what is under it,
    // and it keeps clear of what can be tapped instead.
    return Positioned(
      top: room == null ? null : 0,
      bottom: room == null
          ? math.max(
              clear,
              (desktop ? 24 : 16) +
                  math.max(media.padding.bottom, media.viewInsets.bottom),
            )
          : 0,
      left: left + 16,
      right: media.size.width - right + 16,
      child: Offstage(
        offstage: _hidden,
        child: _placed(
          room,
          FadeTransition(
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
                    key: _card,
                    constraints: BoxConstraints(
                      minHeight: desktop ? 40 : 0,
                      maxWidth: desktop ? 400 : Toast._cardMaxWidth,
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
                              color: desktop
                                  ? palette.controlBorder.withValues(
                                      alpha: dark ? 0.95 : 0.72,
                                    )
                                  : palette.edge,
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
      ),
    );
  }

  /// Sets the card in the room a sheet opens for it, 8 above that room's
  /// [bottom].
  static Widget _placed(double? bottom, Widget toast) => bottom == null
      ? toast
      : CustomSingleChildLayout(delegate: _InRoom(bottom), child: toast);
}

class _InRoom extends SingleChildLayoutDelegate {
  const _InRoom(this.bottom);

  final double bottom;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(maxWidth: constraints.maxWidth);

  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      Offset(0, bottom - 8 - childSize.height);

  @override
  bool shouldRelayout(_InRoom old) => bottom != old.bottom;
}

/// Keeps toasts above [child], such as a phone's bar and its + or the format
/// bar over the keyboard, the highest of them on screen, while its
/// route is the one on top, and the page around its navigator too when a
/// [ToastClearanceScope] marks one. A sheet over it takes the toast back down
/// to the bottom edge.
///
/// [ToastClearance.room] instead opens room for the toast at a sheet's foot
/// while one shows, under its last controls, and the toast sits in it.
///
/// [ToastClearance.beside] keeps a desktop's toasts beside [child] instead,
/// as the notes list, Kapy AI's panel and a folder's Add notes do, so a
/// toast centres on the page between them and follows the list as it slides
/// open or shut. A dialog or a menu over them takes it back to the middle of
/// the window, and so does a page too narrow between them, where a toast
/// also keeps above a [ToastClearance] inside [child], as the list's Notes
/// and Folders switch.
///
/// It lets go as its route starts to leave, so a toast still showing goes
/// straight to its next place rather than follow a closing sheet.
class ToastClearance extends StatefulWidget {
  const ToastClearance({super.key, required Widget this.child})
    : room = false,
      beside = false;

  const ToastClearance.room({super.key})
    : room = true,
      beside = false,
      child = null;

  const ToastClearance.beside({super.key, required Widget this.child})
    : room = false,
      beside = true;

  final bool room;
  final bool beside;
  final Widget? child;

  @override
  State<ToastClearance> createState() => _ToastClearanceState();
}

class _ToastClearanceState extends State<ToastClearance> {
  bool _onTop = true;
  ModalRoute<Object?>? _route;
  double _height = 0;

  double get _room => Toast._current == null ? 0 : Toast._room.value;

  @override
  void initState() {
    super.initState();
    if (widget.room) Toast._room.addListener(_roomChanged);
  }

  /// A room under another route keeps its height until its own is on top
  /// again, so nothing moves behind the scrim.
  void _roomChanged() {
    if (!Toast._clearances.contains(this)) return;
    setState(() => _height = _room);
    Toast._clearancesChanged();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _onTop = _OnTop.of(context);
    final route = ModalRoute.of(context);
    if (route != _route) {
      _route?.animation?.removeStatusListener(_update);
      _route = route?..animation?.addStatusListener(_update);
    }
    _update();
  }

  void _update([AnimationStatus? _]) {
    final route = _route;
    final keep =
        _onTop &&
        (route == null ||
            route.isCurrent &&
                route.animation?.status != AnimationStatus.reverse);
    if (keep) _height = _room;
    if (keep ? Toast._clearances.add(this) : Toast._clearances.remove(this)) {
      Toast._clearancesChanged();
    }
  }

  @override
  void dispose() {
    Toast._room.removeListener(_roomChanged);
    _route?.animation?.removeStatusListener(_update);
    if (Toast._clearances.remove(this)) Toast._clearancesChanged();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (widget.child) {
    final child? when widget.beside =>
      NotificationListener<SizeChangedLayoutNotification>(
        onNotification: (_) {
          if (Toast._clearances.contains(this)) Toast._clearancesChanged();
          return true;
        },
        child: SizeChangedLayoutNotifier(child: child),
      ),
    final child? => child,
    null => AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      height: _height,
    ),
  };
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
