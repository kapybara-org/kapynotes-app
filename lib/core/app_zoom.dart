import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'linux_wheel.dart';
import 'platform.dart';

/// Zooms the main window the way a browser zooms a page: text, icons,
/// spacing and panels together.
///
/// The window is drawn as though its screen had [zoomFor] times the pixel
/// density. Everything lays out in a window that many times smaller and is
/// painted at the screen's full resolution, so it stays as sharp as at 100%,
/// and a narrow window wraps and folds exactly as a window that size would.
/// Every position inside the app is in that one zoomed space, which leaves
/// only the edges where positions cross to and from the system: pointers
/// coming in, the caret going out to the system's input methods, and files
/// dragged in from other apps.
///
/// Only the main window zooms. The menu bar panel is a window of its own, at
/// the size the system gives it.
class AppZoomBinding extends WidgetsFlutterBinding {
  AppZoomBinding._();

  /// Installs the binding. Call it first thing, in place of
  /// [WidgetsFlutterBinding.ensureInitialized].
  static void ensureInitialized() {
    if (!_initialized) {
      AppPlatform.isLinux ? _LinuxZoomBinding._() : AppZoomBinding._();
    }
    _initialized = true;
  }

  static bool _initialized = false;

  ValueListenable<double>? _zoom;
  final Queue<PointerEvent> _pointers = Queue();

  /// Zooms the main window to [zoom] from now on, and again whenever it
  /// changes.
  void follow(ValueListenable<double> zoom) {
    _zoom?.removeListener(handleMetricsChanged);
    _zoom = zoom..addListener(handleMetricsChanged);
    handleMetricsChanged();
  }

  /// How much larger [view] is drawn: the zoom for the main window, 1 for
  /// any other.
  double zoomFor(ui.FlutterView view) => _zoomForView(view.viewId);

  double _zoomForView(int? viewId) =>
      viewId == null || viewId == platformDispatcher.implicitView?.viewId
      ? _zoom?.value ?? 1
      : 1;

  @override
  void initInstances() {
    super.initInstances();
    platformDispatcher.onPointerDataPacket = _handlePointerDataPacket;
  }

  @override
  BinaryMessenger createBinaryMessenger() =>
      AppZoomMessenger(super.createBinaryMessenger(), _zoomForView);

  @override
  ViewConfiguration createViewConfigurationFor(RenderView renderView) {
    final view = renderView.flutterView;
    final zoom = zoomFor(view);
    if (zoom == 1) return super.createViewConfigurationFor(renderView);
    final physical = BoxConstraints.fromViewConstraints(
      view.physicalConstraints,
    );
    final ratio = view.devicePixelRatio * zoom;
    return ViewConfiguration(
      physicalConstraints: physical,
      logicalConstraints: physical / ratio,
      devicePixelRatio: ratio,
    );
  }

  /// The framework's own conversion, at the zoomed pixel ratio, so a click
  /// lands on what is drawn under it.
  void _handlePointerDataPacket(ui.PointerDataPacket packet) {
    try {
      _pointers.addAll(
        PointerEventConverter.expand(packet.data, (viewId) {
          final view = platformDispatcher.view(id: viewId);
          return view == null
              ? null
              : view.devicePixelRatio * _zoomForView(viewId);
        }),
      );
      if (!locked) _flushPointers();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'gestures library',
          context: ErrorDescription('while handling a pointer data packet'),
        ),
      );
    }
  }

  @override
  void unlocked() {
    super.unlocked();
    _flushPointers();
  }

  void _flushPointers() {
    while (_pointers.isNotEmpty) {
      handlePointerEvent(_pointers.removeFirst());
    }
  }
}

/// The binding on Linux, where a notch of a mouse wheel also scrolls as far as
/// it does in GTK apps. [GtkWheelSteps] goes by the window's own height, so a
/// notch moves a note as far on screen at every zoom.
class _LinuxZoomBinding extends AppZoomBinding with GtkWheelSteps {
  _LinuxZoomBinding._() : super._();
}

/// The size the app lays [view] out at: its size on screen, made smaller by
/// the zoom it is drawn at.
Size zoomedSizeOf(ui.FlutterView view) {
  final binding = WidgetsBinding.instance;
  final zoom = binding is AppZoomBinding ? binding.zoomFor(view) : 1.0;
  return view.physicalSize / (view.devicePixelRatio * zoom);
}

/// [mediaQuery] as the app sees [view] once it is zoomed.
MediaQueryData zoomedMediaQuery(
  MediaQueryData mediaQuery,
  ui.FlutterView view,
) {
  final binding = WidgetsBinding.instance;
  final zoom = binding is AppZoomBinding ? binding.zoomFor(view) : 1.0;
  if (zoom == 1) return mediaQuery;
  return mediaQuery.copyWith(
    size: mediaQuery.size / zoom,
    devicePixelRatio: mediaQuery.devicePixelRatio * zoom,
    padding: mediaQuery.padding / zoom,
    viewPadding: mediaQuery.viewPadding / zoom,
    viewInsets: mediaQuery.viewInsets / zoom,
    systemGestureInsets: mediaQuery.systemGestureInsets / zoom,
  );
}

/// The system's messages, with the positions in them moved between the
/// window's size on screen and its zoomed size: the caret's place, which
/// input methods and the emoji picker open beside, on its way out, and where
/// a file dragged in from another app is, on its way in.
@visibleForTesting
class AppZoomMessenger extends BinaryMessenger {
  AppZoomMessenger(this._inner, this._zoomForView);

  final BinaryMessenger _inner;
  final double Function(int? viewId) _zoomForView;

  /// The window whose text field the system is typing into.
  int? _typingIn;

  static const _textInput = 'flutter/textinput';
  static const _drop = 'desktop_drop';
  static const _json = JSONMethodCodec();
  static const _standard = StandardMethodCodec();

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) =>
      // ignore: deprecated_member_use
      _inner.handlePlatformMessage(channel, data, callback);

  @override
  Future<ByteData?>? send(String channel, ByteData? message) => _inner.send(
    channel,
    channel == _textInput ? _outgoingTextInput(message) : message,
  );

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      _inner.setMessageHandler(
        channel,
        channel == _drop && handler != null
            ? (message) => handler(_incomingDrop(message))
            : handler,
      );

  ByteData? _outgoingTextInput(ByteData? message) {
    if (message == null) return message;
    // Only these two are read. The rest carry the whole note as it is typed,
    // so their name is read from the first bytes rather than the message
    // decoded on every key.
    final head = utf8.decode(
      message.buffer.asUint8List(
        message.offsetInBytes,
        math.min(message.lengthInBytes, 64),
      ),
      allowMalformed: true,
    );
    if (!head.contains('TextInput.setClient"') &&
        !head.contains('TextInput.setEditableSizeAndTransform"')) {
      return message;
    }
    final call = _json.decodeMethodCall(message);
    switch (call.method) {
      case 'TextInput.setClient':
        final config = (call.arguments as List)[1] as Map;
        _typingIn = config['viewId'] as int?;
        return message;
      case 'TextInput.setEditableSizeAndTransform':
        final zoom = _zoomForView(_typingIn);
        if (zoom == 1) return message;
        final arguments = Map<String, Object?>.of(
          (call.arguments as Map).cast(),
        );
        final transform = [
          for (final value in arguments['transform']! as List)
            (value as num).toDouble(),
        ];
        for (var column = 0; column < 4; column++) {
          transform[column * 4] *= zoom;
          transform[column * 4 + 1] *= zoom;
        }
        arguments['transform'] = transform;
        return _json.encodeMethodCall(MethodCall(call.method, arguments));
    }
    return message;
  }

  ByteData? _incomingDrop(ByteData? message) {
    final zoom = _zoomForView(null);
    if (message == null || zoom == 1) return message;
    final call = _standard.decodeMethodCall(message);
    if (call.method != 'entered' && call.method != 'updated') return message;
    final position = (call.arguments as List).cast<double>();
    return _standard.encodeMethodCall(
      MethodCall(call.method, [position[0] / zoom, position[1] / zoom]),
    );
  }
}
