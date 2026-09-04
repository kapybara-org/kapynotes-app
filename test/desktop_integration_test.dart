import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/desktop_integration.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';

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

  test('the tray and the close button follow the preference', () async {
    prefs.keepRunningInBackground = true;
    await settle();

    expect(window.calls, contains('setPreventClose'));
    expect(tray.calls, containsAll(['setIcon', 'setContextMenu']));

    prefs.keepRunningInBackground = false;
    await settle();

    expect(tray.calls, contains('destroy'));
  });

  test('a close is a hide only while the app is set to stay', () async {
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
}
