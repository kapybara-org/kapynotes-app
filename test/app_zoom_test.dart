import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/app_zoom.dart';

/// The binding the desktop app runs on, rather than the test binding: what
/// is pinned down here is the edge where the system's positions meet the
/// zoomed window, which the test binding stands in for.
void main() {
  AppZoomBinding.ensureInitialized();
  final binding = WidgetsBinding.instance as AppZoomBinding;
  final zoom = ValueNotifier<double>(1);
  binding.follow(zoom);
  final view = binding.platformDispatcher.implicitView!;

  tearDown(() => zoom.value = 1);

  test(
    'the main window lays out smaller and paints at a higher pixel ratio',
    () {
      final renderView = RenderView(view: view);
      final plain = ViewConfiguration.fromView(view);
      expect(binding.createViewConfigurationFor(renderView), plain);

      zoom.value = 1.5;
      final zoomed = binding.createViewConfigurationFor(renderView);
      expect(zoomed.devicePixelRatio, view.devicePixelRatio * 1.5);
      expect(zoomed.physicalConstraints, plain.physicalConstraints);
      expect(
        zoomed.logicalConstraints.biggest,
        view.physicalSize / (view.devicePixelRatio * 1.5),
      );
      expect(zoomedSizeOf(view), zoomed.logicalConstraints.biggest);
    },
  );

  test('a click lands where the zoomed window draws it', () {
    final events = <PointerEvent>[];
    binding.pointerRouter.addGlobalRoute(events.add);
    addTearDown(() => binding.pointerRouter.removeGlobalRoute(events.add));
    ui.PointerData at(
      ui.PointerChange change,
      double x,
      double y, {
      double moved = 0,
    }) => ui.PointerData(
      viewId: view.viewId,
      change: change,
      physicalX: x,
      physicalY: y,
      physicalDeltaX: moved,
      physicalDeltaY: moved,
      buttons: change == ui.PointerChange.up ? 0 : kPrimaryButton,
    );

    zoom.value = 1.5;
    binding.platformDispatcher.onPointerDataPacket!(
      ui.PointerDataPacket(
        data: [
          at(ui.PointerChange.add, 300, 150),
          at(ui.PointerChange.down, 300, 150),
          at(ui.PointerChange.move, 330, 180, moved: 30),
          at(ui.PointerChange.up, 330, 180),
        ],
      ),
    );

    final ratio = view.devicePixelRatio * 1.5;
    final down = events.whereType<PointerDownEvent>().single;
    expect(down.position, const Offset(300, 150) / ratio);
    final move = events.whereType<PointerMoveEvent>().single;
    expect(move.position, const Offset(330, 180) / ratio);
    expect(move.delta, const Offset(30, 30) / ratio);
  });

  test('the app sees the window at its zoomed size and pixel ratio', () {
    const media = MediaQueryData(
      size: Size(1200, 900),
      devicePixelRatio: 2,
      padding: EdgeInsets.only(top: 30),
    );
    expect(zoomedMediaQuery(media, view), media);

    zoom.value = 1.5;
    final zoomed = zoomedMediaQuery(media, view);
    expect(zoomed.size, const Size(800, 600));
    expect(zoomed.devicePixelRatio, 3);
    expect(zoomed.padding, const EdgeInsets.only(top: 20));
  });

  group('messages', () {
    late List<(String, ByteData?)> sent;
    late Map<String, MessageHandler?> handlers;
    late AppZoomMessenger messenger;
    const json = JSONMethodCodec();
    const standard = StandardMethodCodec();

    setUp(() {
      sent = [];
      handlers = {};
      messenger = AppZoomMessenger(
        _Recorder(sent, handlers),
        (viewId) => viewId == null || viewId == view.viewId ? zoom.value : 1,
      );
    });

    List<double> transformSent() {
      final call = json.decodeMethodCall(sent.last.$2);
      expect(call.method, 'TextInput.setEditableSizeAndTransform');
      return [
        for (final value in (call.arguments as Map)['transform'] as List)
          (value as num).toDouble(),
      ];
    }

    void setClient(int viewId) => messenger.send(
      'flutter/textinput',
      json.encodeMethodCall(
        MethodCall('TextInput.setClient', [
          1,
          {'viewId': viewId},
        ]),
      ),
    );

    void sendTransform() => messenger.send(
      'flutter/textinput',
      json.encodeMethodCall(
        MethodCall('TextInput.setEditableSizeAndTransform', {
          'width': 200.0,
          'height': 40.0,
          'transform': (Matrix4.identity()..setTranslationRaw(100, 50, 0))
              .storage
              .toList(),
        }),
      ),
    );

    test('the caret goes out to input methods where it is on screen', () {
      zoom.value = 1.5;
      setClient(view.viewId);
      sendTransform();
      final transform = Matrix4.fromList(transformSent());
      expect(
        MatrixUtils.transformPoint(transform, const Offset(10, 4)),
        const Offset(165, 81),
      );
    });

    test('a field in another window, or at 100%, goes out untouched', () {
      zoom.value = 1.5;
      setClient(view.viewId + 1);
      sendTransform();
      expect(transformSent()[12], 100);

      zoom.value = 1;
      setClient(view.viewId);
      sendTransform();
      expect(transformSent()[12], 100);
    });

    test('a file dragged in lands where it is drawn', () async {
      final received = <MethodCall>[];
      messenger.setMessageHandler('desktop_drop', (message) async {
        received.add(standard.decodeMethodCall(message));
        return null;
      });
      zoom.value = 2;
      for (final method in ['entered', 'updated']) {
        await handlers['desktop_drop']!(
          standard.encodeMethodCall(MethodCall(method, [300.0, 120.0])),
        );
      }
      await handlers['desktop_drop']!(
        standard.encodeMethodCall(const MethodCall('performOperation', ['/a'])),
      );
      expect(received.map((call) => call.arguments), [
        [150.0, 60.0],
        [150.0, 60.0],
        ['/a'],
      ]);
    });
  });
}

class _Recorder extends BinaryMessenger {
  _Recorder(this.sent, this.handlers);

  final List<(String, ByteData?)> sent;
  final Map<String, MessageHandler?> handlers;

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) async {}

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    sent.add((channel, message));
    return null;
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      handlers[channel] = handler;
}
