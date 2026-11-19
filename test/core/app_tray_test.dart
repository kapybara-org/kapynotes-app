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

  test('Linux shows the colour icon and asks for no tooltip', () async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
    final linux = tray();

    await linux.setVisible(true);

    // tray_manager's Linux side answers setToolTip with not-implemented,
    // which would leave the tray switched off.
    expect(calls.map((call) => call.method), ['setIcon', 'setContextMenu']);
    expect(
      (calls.first.arguments as Map)['iconPath'],
      endsWith('assets/branding/kapynotes_tray_linux.png'),
    );
    expect(linux.isVisible, isTrue);
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
}
