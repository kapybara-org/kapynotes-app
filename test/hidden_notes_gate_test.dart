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
}
