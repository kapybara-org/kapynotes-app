import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/ui/hidden_notes_gate.dart';
import 'package:material_ui/material_ui.dart';

class _DeviceAuthenticator implements DeviceAuthenticator {
  _DeviceAuthenticator(this.results);

  final List<DeviceAuthenticationResult> results;
  int calls = 0;

  @override
  Future<DeviceAuthenticationResult> authenticate() async => results[calls++];
}

Future<Uint8List> _testPinDeriver(String pin, Uint8List salt) async =>
    Uint8List.fromList(
      List<int>.generate(
        32,
        (index) =>
            pin.codeUnitAt(index % pin.length) ^ salt[index % salt.length],
      ),
    );

/// Lets a test break the store at the exact step it is about, and counts
/// deletes because a PIN change must never remove the credential.
class _Store implements SecureStore {
  final InMemorySecureStore _inner = InMemorySecureStore();
  bool failReads = false;
  bool failWrites = false;
  bool garbleNextWrite = false;
  int deletes = 0;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('read');
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('write');
    if (garbleNextWrite) {
      garbleNextWrite = false;
      return _inner.write(key, '$value ');
    }
    return _inner.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
    return _inner.delete(key);
  }
}

Future<BuildContext> _pumpContext(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Builder(
        builder: (value) {
          context = value;
          return const SizedBox();
        },
      ),
    ),
  );
  return context;
}

Future<(BuildContext, DefaultHiddenNotesGate, _Store, String)> _pinGate(
  WidgetTester tester, {
  DateTime Function()? now,
}) async {
  final context = await _pumpContext(tester);
  final store = _Store();
  final gate = DefaultHiddenNotesGate(
    store: store,
    deviceAuthenticator: _DeviceAuthenticator(const []),
    useSystemAuthentication: false,
    pinDeriver: _testPinDeriver,
    now: now,
  );
  final configured = gate.ensureConfigured(context);
  await tester.pumpAndSettle();
  await _enterNewPin(tester, '1357', '1357', 'Create PIN');
  expect(await configured, isTrue);
  return (
    context,
    gate,
    store,
    (await store.read(DefaultHiddenNotesGate.credentialKey))!,
  );
}

Future<void> _enterUnlockPin(WidgetTester tester, String pin) async {
  await tester.enterText(find.byKey(const ValueKey('hidden-pin-unlock')), pin);
  await tester.tap(find.text('Unlock'));
  await tester.pumpAndSettle();
}

Future<bool> _tryUnlock(
  WidgetTester tester,
  HiddenNotesGate gate,
  BuildContext context,
  String pin,
) async {
  final unlocked = gate.unlock(context);
  await tester.pumpAndSettle();
  await _enterUnlockPin(tester, pin);
  if (find.text('Unlock Hidden Notes').evaluate().isNotEmpty) {
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  }
  return unlocked;
}

Future<void> _enterNewPin(
  WidgetTester tester,
  String pin,
  String confirmation,
  String button,
) async {
  await tester.enterText(find.byKey(const ValueKey('hidden-pin-create')), pin);
  await tester.enterText(
    find.byKey(const ValueKey('hidden-pin-confirm')),
    confirmation,
  );
  await tester.tap(find.text(button));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('system authentication is saved and asked for on every unlock', (
    tester,
  ) async {
    final context = await _pumpContext(tester);
    final store = InMemorySecureStore();
    final device = _DeviceAuthenticator([
      DeviceAuthenticationResult.authenticated,
      DeviceAuthenticationResult.authenticated,
      DeviceAuthenticationResult.canceled,
    ]);
    final gate = DefaultHiddenNotesGate(
      store: store,
      deviceAuthenticator: device,
      useSystemAuthentication: true,
    );

    expect(await gate.ensureConfigured(context), isTrue);
    expect(device.calls, 1);
    expect(
      await store.read(DefaultHiddenNotesGate.credentialKey),
      contains('system'),
    );

    expect(await gate.unlock(context), isTrue);
    expect(await gate.unlock(context), isFalse);
    expect(device.calls, 3);
  });

  testWidgets('a canceled device prompt never falls through to PIN setup', (
    tester,
  ) async {
    final context = await _pumpContext(tester);
    final store = InMemorySecureStore();
    final gate = DefaultHiddenNotesGate(
      store: store,
      deviceAuthenticator: _DeviceAuthenticator([
        DeviceAuthenticationResult.canceled,
      ]),
      useSystemAuthentication: true,
    );

    expect(await gate.ensureConfigured(context), isFalse);
    expect(find.byKey(const ValueKey('hidden-pin-create')), findsNothing);
    expect(await store.read(DefaultHiddenNotesGate.credentialKey), isNull);
  });

  testWidgets('no device credential falls back to a four-digit PIN', (
    tester,
  ) async {
    final context = await _pumpContext(tester);
    final store = InMemorySecureStore();
    final gate = DefaultHiddenNotesGate(
      store: store,
      deviceAuthenticator: _DeviceAuthenticator([
        DeviceAuthenticationResult.unavailable,
      ]),
      useSystemAuthentication: true,
      pinDeriver: _testPinDeriver,
    );

    final configured = gate.ensureConfigured(context);
    await tester.pumpAndSettle();
    expect(find.text('Create a Hidden Notes PIN'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('hidden-pin-create')),
      '4826',
    );
    await tester.enterText(
      find.byKey(const ValueKey('hidden-pin-confirm')),
      '4826',
    );
    await tester.tap(find.text('Create PIN'));
    await tester.pumpAndSettle();
    expect(await configured, isTrue);

    final unlocked = gate.unlock(context);
    await tester.pumpAndSettle();
    expect(find.text('Unlock Hidden Notes'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('hidden-pin-unlock')),
      '0000',
    );
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('That PIN is not correct.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('hidden-pin-unlock')),
      '4826',
    );
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(await unlocked, isTrue);
  });

  testWidgets('desktop setup uses only the app PIN', (tester) async {
    final context = await _pumpContext(tester);
    final store = InMemorySecureStore();
    final device = _DeviceAuthenticator(const []);
    final gate = DefaultHiddenNotesGate(
      store: store,
      deviceAuthenticator: device,
      useSystemAuthentication: false,
      pinDeriver: _testPinDeriver,
    );

    final configured = gate.ensureConfigured(context);
    await tester.pumpAndSettle();
    expect(find.text('Create a Hidden Notes PIN'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('hidden-pin-create')),
      '1357',
    );
    await tester.enterText(
      find.byKey(const ValueKey('hidden-pin-confirm')),
      '1357',
    );
    await tester.tap(find.text('Create PIN'));
    await tester.pumpAndSettle();

    expect(await configured, isTrue);
    expect(device.calls, 0);
  });

  testWidgets('changing the PIN replaces it in place with a new salt', (
    tester,
  ) async {
    final (context, gate, store, original) = await _pinGate(tester);

    final changed = gate.changePin(context);
    await tester.pumpAndSettle();
    await _enterUnlockPin(tester, '1357');
    expect(find.text('Change Hidden Notes PIN'), findsOneWidget);
    expect(
      find.text('Use a new 4-digit PIN for Hidden Notes on this device.'),
      findsOneWidget,
    );
    await _enterNewPin(tester, '2468', '2468', 'Change PIN');
    expect(await changed, isTrue);

    final stored = (await store.read(DefaultHiddenNotesGate.credentialKey))!;
    expect(jsonDecode(stored)['v'], 1);
    expect(jsonDecode(stored)['method'], 'pin');
    expect(jsonDecode(stored)['salt'], isNot(jsonDecode(original)['salt']));
    expect(store.deletes, 0);
    expect(await _tryUnlock(tester, gate, context, '1357'), isFalse);
    expect(await _tryUnlock(tester, gate, context, '2468'), isTrue);
  });

  testWidgets('a wrong current PIN changes nothing', (tester) async {
    final (context, gate, store, original) = await _pinGate(tester);

    final changed = gate.changePin(context);
    await tester.pumpAndSettle();
    await _enterUnlockPin(tester, '0000');
    expect(find.text('That PIN is not correct.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await changed, isFalse);
    expect(find.text('Change Hidden Notes PIN'), findsNothing);
    expect(await store.read(DefaultHiddenNotesGate.credentialKey), original);
  });

  testWidgets('a mismatched confirmation is refused and changes nothing', (
    tester,
  ) async {
    final (context, gate, store, original) = await _pinGate(tester);

    final changed = gate.changePin(context);
    await tester.pumpAndSettle();
    await _enterUnlockPin(tester, '1357');
    await _enterNewPin(tester, '2468', '2469', 'Change PIN');
    expect(find.text('The PINs do not match.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await changed, isFalse);
    expect(await store.read(DefaultHiddenNotesGate.credentialKey), original);
  });

  testWidgets('canceling at either step changes nothing', (tester) async {
    final (context, gate, store, original) = await _pinGate(tester);

    final atCurrent = gate.changePin(context);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await atCurrent, isFalse);

    final atNew = gate.changePin(context);
    await tester.pumpAndSettle();
    await _enterUnlockPin(tester, '1357');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await atNew, isFalse);

    expect(await store.read(DefaultHiddenNotesGate.credentialKey), original);
    expect(await _tryUnlock(tester, gate, context, '1357'), isTrue);
  });

  testWidgets('a failed write keeps the old PIN', (tester) async {
    final (context, gate, store, original) = await _pinGate(tester);

    final changed = gate.changePin(context);
    await tester.pumpAndSettle();
    await _enterUnlockPin(tester, '1357');
    store.failWrites = true;
    await _enterNewPin(tester, '2468', '2468', 'Change PIN');
    expect(
      find.text('The new PIN could not be saved. Your old PIN still works.'),
      findsOneWidget,
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(await changed, isFalse);

    store.failWrites = false;
    expect(await store.read(DefaultHiddenNotesGate.credentialKey), original);
    expect(await _tryUnlock(tester, gate, context, '1357'), isTrue);
  });

  testWidgets('a read-back mismatch writes the old PIN back', (tester) async {
    final (context, gate, store, original) = await _pinGate(tester);

    final changed = gate.changePin(context);
    await tester.pumpAndSettle();
    await _enterUnlockPin(tester, '1357');
    store.garbleNextWrite = true;
    await _enterNewPin(tester, '2468', '2468', 'Change PIN');
    expect(
      find.text('The new PIN could not be saved. Your old PIN still works.'),
      findsOneWidget,
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(await changed, isFalse);

    expect(await store.read(DefaultHiddenNotesGate.credentialKey), original);
    expect(store.deletes, 0);
    expect(await _tryUnlock(tester, gate, context, '1357'), isTrue);
  });

  testWidgets('usesPin is true only for a readable PIN credential', (
    tester,
  ) async {
    final (context, pinned, pinStore, _) = await _pinGate(tester);
    expect(await pinned.usesPin(), isTrue);

    pinStore.failReads = true;
    expect(await pinned.usesPin(), isFalse);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    final store = InMemorySecureStore();
    final system = DefaultHiddenNotesGate(
      store: store,
      deviceAuthenticator: _DeviceAuthenticator([
        DeviceAuthenticationResult.authenticated,
      ]),
      useSystemAuthentication: true,
    );
    expect(await system.usesPin(), isFalse);
    expect(await system.ensureConfigured(context), isTrue);
    expect(await system.usesPin(), isFalse);
    expect(await system.changePin(context), isFalse);
  });

  testWidgets('five wrong PINs in a row wait 30 seconds across dialogs', (
    tester,
  ) async {
    var now = DateTime(2026, 11, 17);
    final (context, gate, _, _) = await _pinGate(tester, now: () => now);

    for (var i = 0; i < 4; i++) {
      expect(await _tryUnlock(tester, gate, context, '0000'), isFalse);
    }
    expect(await _tryUnlock(tester, gate, context, '1357'), isTrue);
    for (var i = 0; i < 4; i++) {
      expect(await _tryUnlock(tester, gate, context, '0000'), isFalse);
    }

    final unlocked = gate.unlock(context);
    await tester.pumpAndSettle();
    await _enterUnlockPin(tester, '0000');
    expect(find.text('Too many tries. Try again in 30 s.'), findsOneWidget);
    TextField field() => tester.widget(
      find.descendant(
        of: find.byKey(const ValueKey('hidden-pin-unlock')),
        matching: find.byType(TextField),
      ),
    );
    expect(field().enabled, isFalse);

    now = now.add(const Duration(seconds: 12));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Too many tries. Try again in 18 s.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await unlocked, isFalse);

    final changed = gate.changePin(context);
    await tester.pumpAndSettle();
    expect(find.text('Too many tries. Try again in 18 s.'), findsOneWidget);
    expect(field().enabled, isFalse);

    now = now.add(const Duration(seconds: 18));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('hidden-pin-error')), findsNothing);
    expect(field().enabled, isTrue);
    await _enterUnlockPin(tester, '1357');
    expect(find.text('Change Hidden Notes PIN'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await changed, isFalse);
  });
}
