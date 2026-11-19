import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/app_tray.dart';
import 'package:kapy_notes/core/platform.dart';

/// The tray icon's menu, which is easy to break and impossible to notice.
///
/// Everything here rides on one argument. A menu that will not close is not a
/// crash and not a failing test; it is a report from somebody on Windows, days
/// later, holding a screenshot of a menu stuck over their taskbar.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('tray_manager'), (
          call,
        ) async {
          calls.add(call);
          return true;
        });
  });

  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('tray_manager'), null);
  });

  AppTray tray({Future<bool> Function()? onClick}) => AppTray(
    onOpen: () {},
    onNewNote: () {},
    onNewTask: () {},
    onSettings: () {},
    onQuit: () {},
    onClick: onClick ?? () async => false,
  );

  Object? frontArgOf(MethodCall call) =>
      (call.arguments as Map)['bringAppToFront'];

  test('a right-click on Windows opens a menu that a click elsewhere closes', () async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;

    tray().onTrayIconRightMouseDown();
    await Future<void>.delayed(Duration.zero);

    expect(calls.single.method, 'popUpContextMenu');
    // The whole fix. `TrackPopupMenu` ignores clicks outside itself unless the
    // owning window is foreground, and this is what asks for that.
    expect(
      frontArgOf(calls.single),
      isTrue,
      reason: 'without this the Windows tray menu cannot be dismissed',
    );
  });

  test('macOS is left alone, since the parameter is Windows-only', () async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;

    // A right-click is the menu on macOS as well, and there is no foreground
    // rule to satisfy: asking would be noise the platform ignores. It never
    // reaches the menu bar panel.
    tray(
      onClick: () async => fail('a right-click is the menu'),
    ).onTrayIconRightMouseDown();
    await Future<void>.delayed(Duration.zero);

    expect(calls.single.method, 'popUpContextMenu');
    expect(frontArgOf(calls.single), isFalse);
  });

  test('a plain click on Windows opens the app rather than the menu', () async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
    var opened = 0;

    AppTray(
      onOpen: () => opened++,
      onNewNote: () {},
      onNewTask: () {},
      onSettings: () {},
      onQuit: () {},
      onClick: () async => fail('Windows has no menu bar panel'),
    ).onTrayIconMouseDown();
    await Future<void>.delayed(Duration.zero);

    expect(opened, 1);
    expect(calls, isEmpty, reason: 'a left click is not a menu on Windows');
  });

  test('a click on the Mac opens the menu bar panel, not the menu', () async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    var clicks = 0;

    tray(
      onClick: () async {
        clicks++;
        return true;
      },
    ).onTrayIconMouseDown();
    await Future<void>.delayed(Duration.zero);

    expect(clicks, 1);
    expect(calls, isEmpty);
  });

  test('with no panel to open, a click on the Mac opens the menu', () async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;

    tray(onClick: () async => false).onTrayIconMouseDown();
    await Future<void>.delayed(Duration.zero);

    expect(calls.single.method, 'popUpContextMenu');
  });

  group('an accessibility press on the Mac icon', () {
    const icon = MethodChannel('kapynotes/menubar_icon');
    late List<String> iconCalls;

    setUp(() {
      iconCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(icon, (call) async {
            iconCalls.add(call.method);
            return true;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(icon, null);
    });

    /// The icon's button saying it was pressed, as VoiceOver presses it.
    Future<void> press() async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            icon.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('pressed'),
            ),
            (_) {},
          );
      await Future<void>.delayed(Duration.zero);
    }

    test('opens the panel, as a click does', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      var clicks = 0;
      final subject = tray(onClick: () async => ++clicks > 0);
      await subject.setVisible(true);
      await Future<void>.delayed(Duration.zero);
      expect(iconCalls, ['takePresses']);
      calls.clear();

      await press();
      expect(clicks, 1);
      expect(calls.map((call) => call.method), isNot(contains('popUpContextMenu')));
    });

    test('opens the menu where there is no panel', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      final subject = tray(onClick: () async => false);
      await subject.setVisible(true);
      calls.clear();

      await press();
      expect(calls.single.method, 'popUpContextMenu');
    });

    test('does nothing once the icon is gone', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
      var clicks = 0;
      final subject = tray(onClick: () async => ++clicks > 0);
      await subject.setVisible(true);
      await subject.setVisible(false);

      await press();
      expect(clicks, 0);
    });

    test('is not asked for on Windows', () async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.windows;
      await tray().setVisible(true);
      await Future<void>.delayed(Duration.zero);
      expect(iconCalls, isEmpty);
    });
  });
}
