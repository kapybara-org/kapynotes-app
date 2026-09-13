import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/billing/entitlements.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/billing/pro_sheet.dart';

import 'billing_fakes.dart';
import '../test_fonts.dart';

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
  late List<Uri> openedCheckouts;

  setUpAll(loadTestFonts);

  setUp(() {
    session = _Session();
    api = FakeBillingApi();
    store = FakePurchaseStore();
    openedCheckouts = [];
    billing = Billing(
      session: session,
      userId: () => session.userId,
      token: () => session.userId == null ? null : 'token',
      api: (_) => api,
      store: store,
      launchWebCheckout: (url) async {
        openedCheckouts.add(url);
        return true;
      },
      confirmEvery: const Duration(milliseconds: 10),
      confirmFor: const Duration(milliseconds: 50),
    );
  });

  tearDown(() => billing.dispose());

  Future<void> pumpSheet(
    WidgetTester tester, {
    Size size = const Size(900, 1000),
    Brightness brightness = Brightness.dark,
    bool asSheet = false,
    TargetPlatform? platform,
  }) async {
    AppPlatform.debugTargetPlatformOverride = platform;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? KapyTheme.dark()
            : KapyTheme.light(),
        home: Scaffold(body: ProSheet(billing: billing, asSheet: asSheet)),
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
    expect(find.text('Get Pro Lifetime'), findsOneWidget);
    expect(find.text(r'$24.00'), findsOneWidget);
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

    expect(find.text('Get Pro Lifetime'), findsOneWidget);
    expect(find.text(r'$24.00'), findsOneWidget);
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

  testWidgets('desktop opens web checkout and never offers mobile packs', (tester) async {
    store.supported = false;
    session.signIn('user-1');
    await pumpSheet(tester, platform: TargetPlatform.macOS);

    expect(find.text('Price shown\nat checkout'), findsOneWidget);
    expect(find.text('Secure web checkout. No subscription.'), findsOneWidget);
    expect(find.byKey(const ValueKey('pro-restore')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('pro-buy')));
    await tester.pumpAndSettle();

    expect(openedCheckouts, [api.checkoutUrl]);
    expect(find.textContaining('Finish the purchase in your browser'), findsOneWidget);

    api.answer = () => entitlementsFor(pro: true);
    await billing.refresh();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pro-pack-storage_5gb')), findsNothing);
    expect(find.byKey(const ValueKey('pro-pack-voice_1000')), findsNothing);
  });

  testWidgets('desktop asks a signed-out person to sign in before checkout', (
    tester,
  ) async {
    store.supported = false;
    await pumpSheet(tester, platform: TargetPlatform.windows);

    expect(find.text('Sign in to buy on the web'), findsOneWidget);
    expect(find.textContaining('Sign in first so Pro Lifetime belongs'), findsOneWidget);
    expect(find.textContaining('Unlimited notes unlock on this device'), findsNothing);
    expect(find.byKey(const ValueKey('pro-restore')), findsNothing);
  });

  testWidgets('the button waits for a price rather than guessing one', (
    tester,
  ) async {
    store.offerList = const [];
    session.signIn('user-1');
    await pumpSheet(tester);

    expect(buyButton(tester).onPressed, isNull);
    expect(find.text('No answer from the App Store.'), findsOneWidget);
    expect(find.byKey(const ValueKey('pro-offers-retry')), findsOneWidget);
  });

  testWidgets('while the limits are off it says sync and sharing are everyone’s', (
    tester,
  ) async {
    session.signIn('user-1');
    await pumpSheet(tester);

    expect(find.textContaining('everyone for now'), findsOneWidget);
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
    // Not the everyone line: during a trial, sync is on because of the trial.
    expect(find.textContaining('everyone for now'), findsNothing);
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
    expect(find.textContaining('Write past five notes'), findsOneWidget);
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

    expect(find.textContaining('payment has gone through'), findsOneWidget);
    expect(find.text('Pro Lifetime is yours. Thank you.'), findsNothing);
  });

  testWidgets('the compact phone layout keeps the offer immediately visible', (
    tester,
  ) async {
    session.signIn('user-1');
    await pumpSheet(
      tester,
      size: const Size(328, 712),
      brightness: Brightness.light,
      asSheet: true,
      platform: TargetPlatform.iOS,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Write without limits.'), findsOneWidget);
    expect(find.byKey(const ValueKey('pro-price')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('pro-buy'))).bottom,
      lessThan(520),
    );
  });

  testWidgets('phone Pro sheet golden', (tester) async {
    session.signIn('user-1');
    await pumpSheet(
      tester,
      size: const Size(328, 712),
      brightness: Brightness.light,
      asSheet: true,
      platform: TargetPlatform.iOS,
    );

    await expectLater(
      find.byType(ProSheet),
      matchesGoldenFile('goldens/pro_sheet_phone_light.png'),
    );

    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -430));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(ProSheet),
      matchesGoldenFile('goldens/pro_sheet_phone_light_details.png'),
    );
  });
}
