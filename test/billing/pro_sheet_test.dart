import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/billing/entitlements.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/billing/pro_sheet.dart';

import 'billing_fakes.dart';

class _Session extends ChangeNotifier {
  String? userId;
  void signIn(String id) {
    userId = id;
    notifyListeners();
  }
}

void main() {
  late _Session session;
  late FakeBillingApi api;
  late FakePurchaseStore store;
  late Billing billing;

  setUp(() {
    session = _Session();
    api = FakeBillingApi();
    store = FakePurchaseStore();
    billing = Billing(
      session: session,
      userId: () => session.userId,
      token: () => session.userId == null ? null : 'token',
      api: (_) => api,
      store: store,
      confirmEvery: const Duration(milliseconds: 10),
      confirmFor: const Duration(milliseconds: 50),
    );
  });

  tearDown(() => billing.dispose());

  Future<void> pumpSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(body: ProSheet(billing: billing)),
      ),
    );
    await tester.pumpAndSettle();
  }

  FilledButton buyButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const ValueKey('pro-buy')));

  testWidgets('signed out, it asks for an account before anything else', (
    tester,
  ) async {
    await pumpSheet(tester);

    expect(find.byKey(const ValueKey('pro-sign-in')), findsOneWidget);
    expect(find.byKey(const ValueKey('pro-buy')), findsNothing);
    // Restoring needs an account to restore onto.
    expect(find.byKey(const ValueKey('pro-restore')), findsNothing);
    // Nothing was asked of the store: it is never set up without an account.
    expect(store.log, isEmpty);
  });

  testWidgets('a free account sees the store price and can buy', (
    tester,
  ) async {
    session.signIn('user-1');
    await pumpSheet(tester);

    expect(find.text(r'Get Pro Lifetime · $24.00'), findsOneWidget);
    expect(find.byKey(const ValueKey('pro-restore')), findsOneWidget);

    store.onBuy = () => api.answer = () => entitlementsFor(pro: true);
    await tester.tap(find.byKey(const ValueKey('pro-buy')));
    await tester.pump();
    await tester.pump();

    expect(store.log, contains('buy pro_lifetime as user-1'));
    expect(find.text('Pro Lifetime is yours. Thank you.'), findsOneWidget);
    expect(find.textContaining('Pro Lifetime is on this account'), findsOneWidget);
    // Bought, so the buy button gives way to the packs.
    expect(find.byKey(const ValueKey('pro-buy')), findsNothing);
    expect(find.byKey(const ValueKey('pro-pack-voice_1000')), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the button waits for a price rather than guessing one', (
    tester,
  ) async {
    store.offerList = const [];
    session.signIn('user-1');
    await pumpSheet(tester);

    expect(buyButton(tester).onPressed, isNull);
    expect(find.text('The App Store did not answer.'), findsOneWidget);
    expect(find.byKey(const ValueKey('pro-offers-retry')), findsOneWidget);
  });

  testWidgets('during the beta it says sync and sharing are everyone’s', (
    tester,
  ) async {
    session.signIn('user-1');
    await pumpSheet(tester);

    expect(
      find.textContaining('while Kapy Notes is in beta'),
      findsOneWidget,
    );
  });

  testWidgets('a Pro account at the storage cap cannot buy more storage', (
    tester,
  ) async {
    api.answer = () => entitlementsFor(
      pro: true,
      storageBytes: proStorageBytes + maxBonusStorageBytes,
    );
    session.signIn('user-1');
    await pumpSheet(tester);

    final storage = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('pro-pack-storage_5gb')),
    );
    final voice = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('pro-pack-voice_1000')),
    );
    expect(storage.onPressed, isNull);
    expect(voice.onPressed, isNotNull);
    expect(
      find.text('Your account holds the most extra storage it can.'),
      findsOneWidget,
    );
  });

  testWidgets('a payment the server has not heard of stays on screen', (
    tester,
  ) async {
    session.signIn('user-1');
    await pumpSheet(tester);

    await tester.tap(find.byKey(const ValueKey('pro-buy')));
    // Long enough for every confirmation poll to come back empty.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.textContaining('taken the payment'), findsOneWidget);
    expect(find.text('Pro Lifetime is yours. Thank you.'), findsNothing);
  });
}
