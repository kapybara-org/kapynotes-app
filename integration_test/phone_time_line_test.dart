// A phone note that opens with the keyboard up and then loses it (KAP-344),
// on a real phone or simulator: the whole app over notes kept in memory.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_time_line_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The note opens with the caret at its end and is long enough that, with the
// keyboard up, the field scrolls to it. When the keyboard goes down the whole
// note fits again, and the time line has to come back under the title's row
// with the text. Each text size is a device shot once the keyboard is down, where
// tool/ci/phone_screenshots.sh names the device.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:material_ui/material_ui.dart';

import 'keyboard_support.dart';
import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-time-line-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _lines = [
  'Call with Arjun',
  'Pricing page by Friday',
  'Annual plan shown first',
  'Invoice split across two months',
  'Send the deck',
  'Book the room for Thursday',
  'Draft the follow-up',
  'Ask about the renewal',
  'Share the board with Priya',
  'Check the tax line',
  'Note the discount',
  'Close by the end of the month',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final scale in [1.0, 1.3]) {
    final name = 'time-line-${scale == 1.0 ? '1x' : 'large-text'}';
    testWidgets('at ${scale}x text, the time line comes back under the title '
        'when the keyboard goes', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final store = _MemoryStore();
      store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
      final prefs = LayoutPrefs(store)..load();
      prefs.appearance = AppearanceMode.light;
      final notes = NotesStore(store);
      await notes.load();
      notes.create(body: _lines.join('\n'));

      await tester.pumpWidget(
        KapyNotesApp(
          store: store,
          notes: notes,
          rates: offlineRates(store),
          prefs: prefs,
          shortcuts: ShortcutPrefs(store)..load(),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      NoteFieldState field() =>
          tester.state<NoteFieldState>(find.byType(NoteField));
      double offset() => field().widget.scrollController.offset;

      await settleKeyboard(tester, up: true);
      expect(
        offset(),
        greaterThan(0),
        reason: 'the note opens scrolled to the caret at its end',
      );

      FocusManager.instance.primaryFocus?.unfocus();
      await settleKeyboard(tester, up: false);
      expect(offset(), 0, reason: 'the whole note fits without the keyboard');
      await screenshot(name, device: true);

      final text = field();
      final origin = text.box!.localToGlobal(Offset.zero);
      final title = text
          .boxesFor(
            TextSelection(baseOffset: 0, extentOffset: _lines.first.length),
          )
          .map((box) => box.toRect())
          .reduce((a, b) => a.expandToInclude(b))
          .shift(origin);
      final line = tester.getRect(find.byKey(const ValueKey('note-edited')));
      expect(
        line.top,
        greaterThanOrEqualTo(title.bottom),
        reason: 'the time line sits under the title’s row',
      );
      expect(
        line.bottom,
        lessThanOrEqualTo(origin.dy + text.lineTop(1)!),
        reason: 'and above the note’s first line',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
