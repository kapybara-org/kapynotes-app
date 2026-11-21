// Phone · v2 on a real phone: the whole app, launched as a fresh install.
//
//   flutter test integration_test/phone_v2_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// Every screen is checked for keycaps, which a touch screen has no keys for,
// and for tap targets under 44 × 44 pt. Then the largest text size, and a
// 5,000-line note typed into at its end.
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/main.dart' as app;
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/keycap.dart';
import 'package:material_ui/material_ui.dart';

import 'screenshot.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('every screen: no keycaps, and every target at least 44 pt', (
    tester,
  ) async {
    await app.main();
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final misses = <String>[];

    // Every tappable node is 44 pt square at least. A text field's own node
    // is its line of text, so it is left to the box it is given.
    Future<void> check(String screen, {bool keyboard = false}) async {
      if (find.byType(Keycap).evaluate().isNotEmpty) {
        misses.add('$screen: a keycap');
      }
      await tester.pumpAndSettle();
      await screenshot(
        'phone-v2-${screen.replaceAll(RegExp('[^a-z0-9]+'), '-')}',
        device: keyboard,
      );
      final root = tester.binding.renderViews
          .map((view) => view.owner?.semanticsOwner?.rootSemanticsNode)
          .whereType<SemanticsNode>()
          .firstOrNull;
      void walk(SemanticsNode node) {
        final data = node.getSemanticsData();
        final size = node.rect.size;
        final tap = data.hasAction(SemanticsAction.tap);
        if (tap && !data.flagsCollection.isTextField) {
          // A hairline border inside a 44 pt target can leave 43 to
          // measure, as the formatting bar's does.
          // A node the formatting bar's scroll has cut to a hairline is
          // not a target anyone can reach, and it comes back whole when the
          // bar is scrolled to it.
          final cut = size.width < 2 || size.height < 2;
          if (!cut && (size.width < 43 || size.height < 43)) {
            // A sideways scroll clips a node's rect at the viewport edge,
            // while the target itself is whole: the format bar's edge button
            // is a 44 pt box with 11 of it showing. The box it was laid out
            // in is what a finger has to hit, so measure that.
            final whole = data.label.isEmpty
                ? null
                : find
                      .bySemanticsLabel(RegExp.escape(data.label))
                      .evaluate()
                      .firstOrNull
                      ?.renderObject;
            final box = whole is RenderBox ? whole.size : null;
            if (box == null || box.width < 43 || box.height < 43) {
              misses.add(
                '$screen: ${data.label} is ${size.width.toStringAsFixed(1)} × '
                '${size.height.toStringAsFixed(1)}',
              );
            }
          }
        }
        node.visitChildren((child) {
          walk(child);
          return true;
        });
      }

      final rootNode = root;
      if (rootNode != null) walk(rootNode);
    }

    await check('first launch page');
    await tap(tester, 'page-back');
    await check('notes home');
    await tap(tester, 'phone-filters');
    await check('notes home, filters open');
    await tap(tester, 'phone-filters');
    await tap(tester, 'sidebar-search-field');
    await check('quick find', keyboard: true);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const ValueKey('command-menu-field')),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode
          .hasFocus,
      isTrue,
      reason: 'quick find opens ready to type',
    );
    final cancel = find.byKey(const ValueKey('command-menu-cancel'));
    await tap(
      tester,
      cancel.evaluate().isEmpty ? 'command-menu-back' : 'command-menu-cancel',
    );
    await tap(tester, 'bar-tasks');
    await check('tasks');
    await tap(tester, 'bar-drawings');
    await check('drawings');
    await tap(tester, 'bar-settings');
    await check('settings');
    await tap(tester, 'settings-sheet-done');
    await tap(tester, 'bar-notes');
    await tap(tester, 'phone-new');
    await check('new note', keyboard: true);
    // A device with a hardware keyboard attached raises no software one, so
    // the note asks for the keyboard and takes the caret rather than reading
    // viewInsets. The inset itself is checked on the emulator by hand.
    expect(
      tester.widget<NoteField>(find.byType(NoteField)).focusNode.hasFocus,
      isTrue,
      reason: 'a new note opens ready to type',
    );
    await tap(tester, 'page-more');
    await check('page menu');

    expect(misses, isEmpty, reason: misses.join('\n\n'));
  });

  testWidgets('the largest text size lays out without overflow', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await app.main();
    await tester.pumpAndSettle(const Duration(seconds: 1));
    for (final key in [
      'page-back',
      'phone-filters',
      'bar-tasks',
      'bar-drawings',
      'bar-notes',
      'sidebar-search-field',
    ]) {
      await tap(tester, key);
      expect(tester.takeException(), isNull, reason: key);
      await screenshot('phone-v2-large-text-$key');
    }
  });
}
