import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/popup_keyboard.dart';

void main() {
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  testWidgets('popup routes put the software keyboard away on phones', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [MobilePopupKeyboardObserver()],
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const TextField(key: ValueKey('editor'), autofocus: true),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => const AlertDialog(
                      content: TextField(
                        key: ValueKey('popup-field'),
                        autofocus: true,
                      ),
                    ),
                  ),
                  child: const Text('Open popup'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.text('Open popup'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('popup-field')), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.tap(find.byKey(const ValueKey('popup-field')));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('popup-field')), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('desktop popup inputs keep their autofocus', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [MobilePopupKeyboardObserver()],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => const AlertDialog(
                  content: TextField(
                    key: ValueKey('popup-field'),
                    autofocus: true,
                  ),
                ),
              ),
              child: const Text('Open popup'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open popup'));
    await tester.pumpAndSettle();

    expect(tester.testTextInput.isVisible, isTrue);
  });
}
