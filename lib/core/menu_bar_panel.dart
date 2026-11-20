import 'dart:async';
import 'dart:ui' show FlutterView;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What the menu bar panel and the icon's menu ask of the window. The home
/// page answers while it is mounted; each is called with the window already
/// brought forward.
typedef MenuBarWindowActions = ({
  ValueChanged<String> openNote,
  VoidCallback openTasks,
  VoidCallback find,
  VoidCallback newTask,
  VoidCallback openSettings,
  VoidCallback explainNoteLimit,
});

/// The menu bar panel's native half, and what it holds between openings.
///
/// The panel is a second view on this engine (macos/Runner/MenuBarPanel.swift),
/// so it is drawn by the same isolate and writes through the same stores as
/// the window. This opens and closes it; [MenuBarPanelView] draws into it.
class MenuBarPanelController extends ChangeNotifier
    with WidgetsBindingObserver {
  MenuBarPanelController({
    MethodChannel channel = const MethodChannel('kapynotes/menubar_panel'),
    this.takesKey = true,
  }) : _channel = channel {
    _channel.setMethodCallHandler(_onNativeCall);
    WidgetsBinding.instance.addObserver(this);
    _routeSemanticsActions();
  }

  static bool _routingActions = false;

  /// The macOS engine sends every accessibility action to the window's view,
  /// whichever view the element is in, so a VoiceOver press on the panel's
  /// Tasks tab looked for that node in the window and did nothing. Node ids
  /// are unique across views, except each view's root, so an action on a node
  /// its view does not have goes to the view that has it.
  static void _routeSemanticsActions() {
    if (_routingActions) return;
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    final handle = dispatcher.onSemanticsActionEvent;
    if (handle == null) return;
    _routingActions = true;
    dispatcher.onSemanticsActionEvent = (event) {
      if (event.nodeId == 0 || _viewHas(event.viewId, event.nodeId)) {
        return handle(event);
      }
      for (final view in RendererBinding.instance.renderViews) {
        final viewId = view.flutterView.viewId;
        if (viewId != event.viewId && _viewHas(viewId, event.nodeId)) {
          return handle(event.copyWith(viewId: viewId));
        }
      }
      handle(event);
    };
  }

  static bool _viewHas(int viewId, int nodeId) {
    bool has(SemanticsNode node) {
      if (node.id == nodeId) return true;
      var found = false;
      node.visitChildren((child) => !(found = has(child)));
      return found;
    }

    for (final view in RendererBinding.instance.renderViews) {
      if (view.flutterView.viewId != viewId) continue;
      final root = view.owner?.semanticsOwner?.rootSemanticsNode;
      return root != null && has(root);
    }
    return false;
  }

  static const double maxHeight = 600;

  /// How long the engine has to put the panel's view on screen and draw it.
  /// A showing that takes longer gives that click the menu instead.
  static const Duration showTimeout = Duration(seconds: 2);

  /// Showings that may fail in a row before the icon keeps its menu for the
  /// rest of the session. One slow showing on a busy Mac is not a broken
  /// engine, so the next click tries the panel again.
  static const int maxFailedShows = 3;

  final MethodChannel _channel;

  /// False only where nothing may take the keyboard: the panel then opens
  /// without becoming key, and a click elsewhere does not close it.
  final bool takesKey;

  /// The drafts, one per tab. They live here rather than in the panel so that
  /// closing it, by Esc or a click elsewhere, never loses a word.
  final TextEditingController noteDraft = TextEditingController();
  final TextEditingController taskDraft = TextEditingController();

  /// The note the Tasks field adds to, kept until the app quits, so several
  /// tasks in a row land in the same note. Null is "No note".
  String? taskNoteId;

  Future<bool>? _supported;
  int? _viewId;
  bool _open = false;
  bool _resized = false;
  double _height = 420;
  int _openings = 0;
  int _failedShows = 0;
  Completer<void>? _arrival;

  bool get isOpen => _open;

  /// Counts openings, so that what lasts only while the panel is open, such
  /// as a task checked in place, starts over each time.
  int get openings => _openings;

  FlutterView? get view {
    final id = _viewId;
    if (id == null) return null;
    for (final view in WidgetsBinding.instance.platformDispatcher.views) {
      if (view.viewId == id) return view;
    }
    return null;
  }

  /// Whether this engine can host the panel at all. False off macOS, and on
  /// an engine without the switch the panel needs, where the icon keeps its
  /// menu.
  Future<bool> get isSupported => _supported ??= _ask<bool>(
    'isSupported',
  ).then((supported) => supported ?? false);

  /// What a plain click on the icon does: opens or closes the panel, and
  /// answers true; or answers false when the menu should open instead,
  /// because there is no panel here, ⌃ is held, or the panel never showed.
  Future<bool> click() async {
    if (!await isSupported) return false;
    if (await _ask<bool>('isControlPressed') ?? false) return false;
    if (!_open) return open();
    await close();
    return true;
  }

  Future<void> toggle() async {
    if (_open) return close();
    await open();
  }

  /// Opens the panel, and answers whether it is showing.
  Future<bool> open() async {
    if (_open) return true;
    if (!await isSupported) return false;
    _open = true;
    _openings++;
    final id = await _ask<int>('show', {'height': _height, 'key': takesKey});
    if (id == null) {
      _open = false;
      return false;
    }
    _viewId = id;
    final shown = await _drawAndReveal().timeout(
      showTimeout,
      onTimeout: () => false,
    );
    if (shown) {
      _failedShows = 0;
      return true;
    }
    _open = false;
    if (++_failedShows >= maxFailedShows) _supported = Future.value(false);
    notifyListeners();
    await _ask<void>('hide');
    return false;
  }

  Future<bool> _drawAndReveal() async {
    if (view == null) {
      _arrival = Completer<void>();
      await _arrival!.future;
    }
    _resized = false;
    notifyListeners();
    await WidgetsBinding.instance.endOfFrame;
    // A first frame that found the panel the wrong height has asked for the
    // right one; the frame after it is the one to show.
    if (_resized) await WidgetsBinding.instance.endOfFrame;
    if (_open) await _ask<void>('reveal');
    return true;
  }

  Future<void> close() async {
    if (!_open) return;
    _open = false;
    notifyListeners();
    await _ask<void>('hide');
  }

  /// The height the panel's content wants, up to [maxHeight].
  void fitHeight(double height) {
    final fitted = height.clamp(0, maxHeight).ceilToDouble();
    if (fitted == _height) return;
    _height = fitted;
    _resized = true;
    if (_open) unawaited(_ask<void>('resize', {'height': fitted}));
  }

  @override
  void didChangeMetrics() {
    if (view != null && !(_arrival?.isCompleted ?? true)) _arrival!.complete();
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method == 'dismissed' && _open) {
      _open = false;
      notifyListeners();
    }
    return null;
  }

  Future<T?> _ask<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    noteDraft.dispose();
    taskDraft.dispose();
    super.dispose();
  }
}
