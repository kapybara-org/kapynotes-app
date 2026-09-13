import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/window_placement.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'window-placement-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowChannel = MethodChannel('window_manager');
  const screenChannel = MethodChannel(
    'dev.leanflutter.plugins/screen_retriever',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Rect nativeBounds;
  late List<MethodCall> windowCalls;
  late Map<String, Object?> display;

  setUp(() {
    nativeBounds = const Rect.fromLTWH(100, 100, 600, 720);
    windowCalls = [];
    display = {
      'id': 'primary',
      'name': 'Primary',
      'size': {'width': 1440.0, 'height': 900.0},
      'visiblePosition': {'dx': 0.0, 'dy': 24.0},
      'visibleSize': {'width': 1440.0, 'height': 876.0},
      'scaleFactor': 1.0,
    };

    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call);
      if (call.method == 'getBounds') {
        return {
          'x': nativeBounds.left,
          'y': nativeBounds.top,
          'width': nativeBounds.width,
          'height': nativeBounds.height,
        };
      }
      if (call.method == 'setBounds') {
        final args = (call.arguments as Map).cast<String, Object?>();
        nativeBounds = Rect.fromLTWH(
          (args['x'] as num?)?.toDouble() ?? nativeBounds.left,
          (args['y'] as num?)?.toDouble() ?? nativeBounds.top,
          (args['width'] as num?)?.toDouble() ?? nativeBounds.width,
          (args['height'] as num?)?.toDouble() ?? nativeBounds.height,
        );
      }
      return true;
    });
    messenger.setMockMethodCallHandler(screenChannel, (call) async {
      return switch (call.method) {
        'getPrimaryDisplay' => display,
        'getAllDisplays' => {
          'displays': [display],
        },
        'getCursorScreenPoint' => {'dx': 720.0, 'dy': 450.0},
        _ => null,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(windowChannel, null);
    messenger.setMockMethodCallHandler(screenChannel, null);
  });

  test('a first launch opens tall and centered on the right edge', () async {
    final prefs = LayoutPrefs(_MemoryStore())..load();

    await placeInitialDesktopWindow(prefs);

    expect(nativeBounds, const Rect.fromLTWH(840, 102, 600, 720));
    expect(prefs.windowBounds, nativeBounds);
    expect(
      windowCalls.where((call) => call.method == 'setBounds').single.arguments,
      allOf(containsPair('x', 840.0), containsPair('y', 102.0)),
    );
  });

  test('a reachable saved position is restored exactly', () async {
    final prefs = LayoutPrefs(_MemoryStore())..load();
    prefs.rememberWindowBounds(const Rect.fromLTWH(118, 76, 600, 720));
    nativeBounds = const Rect.fromLTWH(400, 200, 600, 720);

    await placeInitialDesktopWindow(prefs);

    expect(nativeBounds, const Rect.fromLTWH(118, 76, 600, 720));
    expect(prefs.windowBounds, nativeBounds);
  });

  test('a position on a disconnected display returns to the right', () async {
    final prefs = LayoutPrefs(_MemoryStore())..load();
    prefs.rememberWindowBounds(const Rect.fromLTWH(2600, 80, 600, 720));

    await placeInitialDesktopWindow(prefs);

    expect(nativeBounds, const Rect.fromLTWH(840, 102, 600, 720));
    expect(prefs.windowBounds, nativeBounds);
  });

  test('a partly clipped window stays exact while its top is reachable', () {
    const workArea = Rect.fromLTWH(0, 24, 1440, 876);

    expect(
      isWindowPlacementReachable(
        const Rect.fromLTWH(1360, 10, 600, 720),
        const [workArea],
      ),
      isTrue,
    );
    expect(
      isWindowPlacementReachable(
        const Rect.fromLTWH(1500, 10, 600, 720),
        const [workArea],
      ),
      isFalse,
    );
  });
}
