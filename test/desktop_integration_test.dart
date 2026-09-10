import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/desktop_integration.dart';
import 'package:kapy_notes/core/system_shutdown.dart';
import 'package:kapy_notes/core/window_pin.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';

/// Records what the runners were asked to do, and answers for them.
///
/// The behaviour worth pinning down here is a sequence of native calls —
/// prevent the close, put up the tray, hide rather than quit — and none of it
/// can be seen from the widget tree. The channels are the seam.
class _NativeRecorder {
  _NativeRecorder(this.channel, {required this.sequence});

  final String channel;
  final List<String> calls = [];
  final Map<String, Object?> answers = {};

  /// The arguments of the most recent call to each method. Keyed rather than
  /// listed so it stays readable across the tests that clear [calls] partway
  /// through.
  final Map<String, Object?> lastArguments = {};

  /// Methods the host refuses, for the paths that have to survive a runner
  /// saying no.
  final Set<String> refuses = {};

  /// Shared across the recorders, for the assertions that are about the order
  /// two different runners were spoken to in.
  final List<String> sequence;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(channel), (call) async {
          calls.add(call.method);
          lastArguments[call.method] = call.arguments;
          sequence.add('$channel.${call.method}');
          if (refuses.contains(call.method)) {
            throw PlatformException(code: 'refused', message: call.method);
          }
          return answers[call.method];
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), null),
    );
  }
}

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'test.json');

  @override
  Future<void> load() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  Future<void> flush() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> sequence;
  late _NativeRecorder window;
  late _NativeRecorder tray;
  late _NativeRecorder loginItem;
  late LayoutPrefs prefs;
  late DesktopIntegration integration;

  setUp(() {
    sequence = [];
    window = _NativeRecorder('window_manager', sequence: sequence)
      ..answers['isVisible'] = true
      // show() asks before it restores.
      ..answers['isMinimized'] = false
      ..install();
    tray = _NativeRecorder('tray_manager', sequence: sequence)..install();
    loginItem = _NativeRecorder('kapynotes/login_item', sequence: sequence)
      ..answers['isSupported'] = true
      ..answers['isEnabled'] = false
      ..install();

    prefs = LayoutPrefs(_MemoryStore())..load();
    integration = DesktopIntegration(layoutPrefs: prefs);
    addTearDown(integration.dispose);
  });

  /// The preference is applied off a listener, so the work lands a microtask
  /// or two after the assignment.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// Desktop now starts with the tray on, so anything testing the way there
  /// has to ask for the other end rather than inherit it from the default.
  Future<void> startWithoutTray() async {
    prefs.keepRunningInBackground = false;
    await settle();
    window.calls.clear();
    tray.calls.clear();
  }

  test('the tray and the close button follow the preference', () async {
    await startWithoutTray();

    prefs.keepRunningInBackground = true;
    await settle();

    expect(window.calls, contains('setPreventClose'));
    expect(tray.calls, containsAll(['setIcon', 'setContextMenu']));

    prefs.keepRunningInBackground = false;
    await settle();

    expect(tray.calls, contains('destroy'));
  });

  test('a close is a hide only while the app is set to stay', () async {
    await startWithoutTray();

    // Both platforms report the close whether or not it was prevented, so
    // doing nothing has to be the answer when it was not.
    integration.onWindowClose();
    await settle();
    expect(window.calls, isNot(contains('hide')));

    prefs.keepRunningInBackground = true;
    await settle();
    integration.onWindowClose();
    await settle();
    expect(window.calls, contains('hide'));
  });

  test(
    'turning it off with the window hidden brings the window back',
    () async {
      prefs.keepRunningInBackground = true;
      await settle();

      // What the tray was hiding it behind.
      window.answers['isVisible'] = false;
      window.calls.clear();

      prefs.keepRunningInBackground = false;
      await settle();

      // Otherwise there is no window on screen and no tray icon left to click.
      expect(window.calls, containsAll(['show', 'focus']));
    },
  );

  test('summoning the window reports that it is ready for writing', () async {
    window.answers['isFocused'] = false;
    var opened = 0;
    integration.onOpenRequested = () => opened++;

    await integration.toggleWindow();

    expect(
      window.calls,
      containsAllInOrder(['isVisible', 'isFocused', 'show', 'focus']),
    );
    expect(opened, 1);

    integration.onWindowFocus();
    expect(opened, 2);
  });

  test('a tray that will not appear leaves the close button alone', () async {
    // Reported, not thrown: a tray is a convenience and must not take the app
    // down with it. The report would otherwise fail this test.
    final onError = FlutterError.onError;
    FlutterError.onError = (_) {};
    addTearDown(() => FlutterError.onError = onError);

    tray.refuses.add('setIcon');
    prefs.keepRunningInBackground = true;
    await settle();

    // Hiding the window with nothing in the tray would strand it, so the
    // close button keeps meaning what it always did.
    integration.onWindowClose();
    await settle();
    expect(window.calls, isNot(contains('hide')));
  });

  test('quitting saves first, and takes the tray icon with it', () async {
    prefs.keepRunningInBackground = true;
    await settle();
    sequence.clear();

    var flushed = false;
    integration.onBeforeQuit = () async => flushed = true;
    await integration.quit();

    expect(flushed, isTrue, reason: 'notes must reach disk before the exit');
    // An icon that outlives the app it belongs to is one the user goes on
    // clicking at, so it has to go first.
    expect(
      sequence.indexOf('tray_manager.destroy'),
      lessThan(sequence.indexOf('window_manager.destroy')),
    );
  });

  /// What the Windows runner sends when Restart Manager — the installer —
  /// or a logoff asks this process to end.
  Future<void> sendShutdown() {
    return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          SystemShutdown.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('shutdown'),
          ),
          (_) {},
        );
  }

  test(
    'an installer asking the app to end is not answered with a hide',
    () async {
      // The configuration this went wrong in, which is also the default one:
      // the close button hides to the tray, so the WM_CLOSE Restart Manager
      // falls back to was swallowed and the process lived on holding the very
      // files the installer had come to replace.
      await integration.initialize(ShortcutPrefs(_MemoryStore())..load());
      prefs.keepRunningInBackground = true;
      await settle();
      window.calls.clear();
      tray.calls.clear();

      var flushed = false;
      integration.onBeforeQuit = () async => flushed = true;

      await sendShutdown();

      expect(flushed, isTrue, reason: 'notes must reach disk before the exit');
      expect(window.calls, contains('destroy'));
      expect(window.calls, isNot(contains('hide')));
      expect(tray.calls, contains('destroy'));
    },
  );

  test('being asked to leave twice still only leaves once', () async {
    // An update arrives here from both ends at once: WinSparkle asks the app
    // to quit at the same moment the installer it already launched asks
    // Windows to make it. Destroying the window twice is a crash.
    await integration.initialize(ShortcutPrefs(_MemoryStore())..load());
    await settle();
    window.calls.clear();

    var saves = 0;
    integration.onBeforeQuit = () async => saves++;

    await Future.wait([sendShutdown(), integration.quit()]);
    await integration.quit();

    expect(saves, 1);
    expect(window.calls.where((call) => call == 'destroy'), hasLength(1));
  });

  test('quitting still closes the window when the final save fails', () async {
    integration.onBeforeQuit = () async => throw StateError('disk failed');

    await integration.quit();

    expect(window.calls, contains('setPreventClose'));
    expect(window.calls, contains('destroy'));
  });

  test(
    'a first launch opens at login, and later ones leave it alone',
    () async {
      final store = _MemoryStore();
      final shortcuts = ShortcutPrefs(_MemoryStore())..load();

      final first = DesktopIntegration(layoutPrefs: LayoutPrefs(store)..load());
      addTearDown(first.dispose);
      await first.initialize(shortcuts);

      expect(loginItem.calls, contains('setEnabled'));
      expect((LayoutPrefs(store)..load()).loginItemDefaultApplied, isTrue);

      // Whatever the user did with it afterwards is the last word. A default
      // that reasserted itself every launch would not be a default.
      loginItem.calls.clear();
      final second = DesktopIntegration(
        layoutPrefs: LayoutPrefs(store)..load(),
      );
      addTearDown(second.dispose);
      await second.initialize(shortcuts);

      expect(loginItem.calls, isNot(contains('setEnabled')));
    },
  );

  test('a host with no mechanism keeps its one chance for later', () async {
    // macOS 12 has no login-item API this sandbox may use. Spending the
    // default against it would mean an upgrade to 13 never got one.
    loginItem.answers['isSupported'] = false;
    final store = _MemoryStore();

    final integration = DesktopIntegration(
      layoutPrefs: LayoutPrefs(store)..load(),
    );
    addTearDown(integration.dispose);
    await integration.initialize(ShortcutPrefs(_MemoryStore())..load());

    expect(loginItem.calls, isNot(contains('setEnabled')));
    expect((LayoutPrefs(store)..load()).loginItemDefaultApplied, isFalse);
  });

  test('the login item is read back from the OS, not assumed', () async {
    await integration.refreshLoginItem();
    expect(integration.loginItemSupported, isTrue);
    expect(integration.loginItemEnabled, isFalse);

    // A registration the OS accepts.
    loginItem.answers['isEnabled'] = true;
    expect(await integration.setLoginItemEnabled(true), isNull);
    expect(integration.loginItemEnabled, isTrue);
  });

  test('a refused login item reports why and stays off', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('kapynotes/login_item'), (
          call,
        ) async {
          if (call.method == 'isSupported') return true;
          if (call.method == 'isEnabled') return false;
          throw PlatformException(
            code: 'requires-approval',
            message: 'Allow Kapy Notes in System Settings.',
          );
        });

    expect(
      await integration.setLoginItemEnabled(true),
      'Allow Kapy Notes in System Settings.',
    );
    expect(integration.loginItemEnabled, isFalse);
  });

  test(
    'a host with no login items at all is reported as unsupported',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('kapynotes/login_item'),
            null,
          );

      await integration.refreshLoginItem();
      expect(integration.loginItemSupported, isFalse);
      expect(integration.loginItemEnabled, isFalse);
    },
  );

  test(
    'the pin reaches the window manager, and only when it changes',
    () async {
      expect(window.calls, isNot(contains('setAlwaysOnTop')));

      prefs.alwaysOnTop = true;
      await settle();
      expect(window.calls, contains('setAlwaysOnTop'));

      // LayoutPrefs notifies for every dragged pixel of the sidebar, so an
      // unguarded listener would cross the channel on each one.
      window.calls.clear();
      prefs.sidebarWidth = LayoutPrefs.defaultSidebarWidth + 40;
      prefs.sidebarWidth = LayoutPrefs.defaultSidebarWidth + 80;
      await settle();
      expect(window.calls, isNot(contains('setAlwaysOnTop')));

      prefs.alwaysOnTop = false;
      await settle();
      expect(window.calls, contains('setAlwaysOnTop'));
    },
  );

  test('the pin is given up before a window we do not own goes up', () async {
    prefs.alwaysOnTop = true;
    await settle();
    window.calls.clear();

    expect(await integration.releaseAlwaysOnTop(), isTrue);

    // Awaited, and before the preference is touched: the caller is about to
    // put Sparkle's panel on screen and cannot wait for a listener to catch
    // up. A panel opened over a window still at floating level is the bug.
    expect(window.calls, ['setAlwaysOnTop']);
    expect(window.lastArguments['setAlwaysOnTop'], {'isAlwaysOnTop': false});
    // Given up rather than borrowed, so the toolbar button goes out with it
    // and one press puts it back. Nothing says when Sparkle's panel closes.
    expect(prefs.alwaysOnTop, isFalse);

    // And the preference change that follows must not cross the channel a
    // second time to say what has already been said.
    await settle();
    expect(window.calls, ['setAlwaysOnTop']);
  });

  test('a window that was never on top has nothing to give up', () async {
    await settle();
    window.calls.clear();

    expect(await integration.releaseAlwaysOnTop(), isFalse);
    expect(window.calls, isEmpty);
  });

  test('the runner can ask for the pin before it opens a panel', () async {
    // The About panel is the caller: AppKit opens it at the ordinary window
    // level, underneath a window kept on top, and choosing About looks like
    // it did nothing.
    await integration.initialize(ShortcutPrefs(_MemoryStore())..load());
    prefs.alwaysOnTop = true;
    await settle();
    window.calls.clear();

    // The runner puts its panel up when this reply arrives, so awaiting the
    // ask is also the assertion that the reply comes after the window has
    // been lowered rather than before it.
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          WindowPin.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('release'),
          ),
          (_) {},
        );

    expect(window.lastArguments['setAlwaysOnTop'], {'isAlwaysOnTop': false});
    expect(prefs.alwaysOnTop, isFalse);
  });

  test('a pin saved last time is re-asserted on the new window', () async {
    // A fresh window starts unpinned however the preference was left, so
    // startup has to say so rather than wait for a change that never comes.
    final restored = LayoutPrefs(_MemoryStore()..data['alwaysOnTop.v1'] = true)
      ..load();
    final second = DesktopIntegration(layoutPrefs: restored);
    addTearDown(second.dispose);
    window.calls.clear();

    await second.initialize(ShortcutPrefs(_MemoryStore())..load());

    expect(window.calls, contains('setAlwaysOnTop'));
  });
}
