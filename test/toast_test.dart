import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/core/toast.dart';
import 'package:material_ui/material_ui.dart';

Widget _harness(ValueChanged<BuildContext> onContext) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: Builder(
      builder: (context) {
        onContext(context);
        return const SizedBox.expand();
      },
    ),
  ),
);

void main() {
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
    expect(positioned.bottom, 308);

    progress.dismiss();
    await tester.pump();
  });
}
