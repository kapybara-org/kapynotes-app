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

  void signOut() {
    userId = null;
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

  testWidgets('signed out, it sells Pro and says what needs an account', (
    tester,
  ) async {
    await pumpSheet(tester);

    // Buying is allowed with no account, because unlimited notes works
    // without one — and what does not is said before the money.
    expect(find.text(r'Get Pro Lifetime · $24.00'), findsOneWidget);
    expect(
      find.textContaining('Unlimited notes unlock on this device'),
      findsOneWidget,
    );
    expect(find.textContaining('belong to an account'), findsOneWidget);
    // Restoring is offered too: a wiped device unlocks its notes again.
    expect(find.byKey(const ValueKey('pro-restore')), findsOneWidget);
    expect(find.byKey(const ValueKey('pro-sign-in')), findsOneWidget);
  });

  testWidgets('bought with no account, it says where the purchase is', (
    tester,
  ) async {
    await pumpSheet(tester);
    await tester.tap(find.byKey(const ValueKey('pro-buy')));
    await tester.pump();
    await tester.pump();

    expect(store.log, contains('buy pro_lifetime as nobody'));
    expect(find.byKey(const ValueKey('pro-owned-here')), findsOneWidget);
    expect(find.textContaining('on this device'), findsWidgets);
    expect(
      find.textContaining('Sign in to use it on your other devices'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('pro-buy')), findsNothing);
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

  testWidgets('a trial says what is left of it, and that it ends by itself', (
    tester,
  ) async {
    api.answer = () => trialFor(const Duration(days: 5, hours: 1));
    session.signIn('user-1');
    await pumpSheet(tester);

    expect(find.byKey(const ValueKey('pro-trial')), findsOneWidget);
    expect(find.textContaining('6 days left'), findsOneWidget);
    expect(find.textContaining('Nothing is charged'), findsOneWidget);
    // Not the beta's line: after launch, sync is on because of the trial.
    expect(find.textContaining('in beta'), findsNothing);
    expect(find.textContaining('while you try Pro'), findsOneWidget);
    // Pro Lifetime is still the thing to buy, and no pack is: one bought
    // during a trial would be stranded on Free when the trial ended.
    expect(find.byKey(const ValueKey('pro-buy')), findsOneWidget);
    expect(find.byKey(const ValueKey('pro-pack-storage_5gb')), findsNothing);
    expect(find.byKey(const ValueKey('pro-pack-voice_1000')), findsNothing);
    // Which also stops the timer waiting for the trial to end.
    session.signOut();
  });

  testWidgets('after the trial it says what Pro would give back', (
    tester,
  ) async {
    api.answer = afterTrial;
    session.signIn('user-1');
    await pumpSheet(tester);

    expect(find.byKey(const ValueKey('pro-trial')), findsNothing);
    expect(
      find.textContaining('editing more than five notes'),
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
