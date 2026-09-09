import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/core/toast.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

Widget _harness(ValueChanged<BuildContext> onContext, {ThemeData? theme}) {
  final baseTheme = theme ?? KapyTheme.dark();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(fontFamily: 'Roboto'),
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) {
          onContext(context);
          return const SizedBox.expand();
        },
      ),
    ),
  );
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => Toast.debugAnimateLifetimeInTests = true);
  tearDown(() => Toast.debugAnimateLifetimeInTests = false);

  testWidgets('a waiting toast changes from progress to completion', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(_harness((value) => context = value));

    final progress = Toast.showProgress(context, 'Adding image…');
    await tester.pump();

    expect(find.text('Adding image…'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('toast-progress-indicator')),
      findsOneWidget,
    );

    progress.success('Image added');
    await tester.pump();

    expect(find.text('Adding image…'), findsNothing);
    expect(find.text('Image added'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('toast-progress-indicator')),
      findsNothing,
    );

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Image added'), findsNothing);
  });

  testWidgets('a waiting toast can complete before its first frame', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(_harness((value) => context = value));

    final progress = Toast.showProgress(context, 'Exporting notes…');
    progress.success('Export ready');
    await tester.pump();

    expect(find.text('Exporting notes…'), findsNothing);
    expect(find.text('Export ready'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('toast-progress-indicator')),
      findsNothing,
    );

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Export ready'), findsNothing);
  });

  testWidgets('a progress toast stays above the mobile keyboard', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(_harness((value) => context = value));

    final progress = Toast.showProgress(context, 'Uploading…');
    await tester.pump();

    final positioned = tester.widget<Positioned>(
      find.ancestor(
        of: find.text('Uploading…'),
        matching: find.byType(Positioned),
      ),
    );
    expect(positioned.bottom, 296);

    progress.dismiss();
    await tester.pump();
  });

  testWidgets('uses a compact neutral pill with a clear status icon', (
    tester,
  ) async {
    Toast.debugAnimateLifetimeInTests = false;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 140);
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(_harness((value) => context = value));

    Toast.show(context, 'Copied 1,234', icon: Icons.copy_rounded);
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('toast-surface'));
    expect(tester.getSize(surface).height, 40);
    final decoration = tester.widget<Container>(surface).decoration;
    expect(decoration, isA<BoxDecoration>());
    expect(
      (decoration! as BoxDecoration).borderRadius,
      BorderRadius.circular(999),
    );
    final icon = tester.widget<Icon>(
      find.byKey(const ValueKey('toast-status-icon')),
    );
    expect(icon.size, 14);
    expect(icon.color, Theme.of(tester.element(surface)).colorScheme.primary);
    expect(icon.color, isNot(KapyTheme.darkPalette.chipCurrency));

    await expectLater(
      find.byKey(const ValueKey('toast-repaint-boundary')),
      matchesGoldenFile('goldens/toast_success_dark.png'),
    );
  });

  testWidgets('uses the error treatment cleanly on a light surface', (
    tester,
  ) async {
    Toast.debugAnimateLifetimeInTests = false;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 140);
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(
      _harness((value) => context = value, theme: KapyTheme.light()),
    );

    Toast.show(context, 'Could not save', isError: true);
    await tester.pumpAndSettle();

    final icon = tester.widget<Icon>(
      find.byKey(const ValueKey('toast-status-icon')),
    );
    expect(icon.icon, Icons.error_outline_rounded);
    expect(icon.color, Theme.of(context).colorScheme.error);
    await expectLater(
      find.byKey(const ValueKey('toast-repaint-boundary')),
      matchesGoldenFile('goldens/toast_error_light.png'),
    );
  });
}
