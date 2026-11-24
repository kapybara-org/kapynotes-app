import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart' show NoteEditor;
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore;
import 'test_fonts.dart';

final _now = DateTime(2025, 11, 19, 9, 41);

/// A phone note that opens with the keyboard up is scrolled to its end. When
/// the keyboard goes down the whole note fits again, and the field pulls its
/// offset back while it lays out. The time line under the title and the
/// folder path above it have to come back down with the text, to where a
/// fresh build of the page puts them (KAP-344).
void main() {
  setUpAll(loadTestFonts);

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets(
        'on ${platform.name} at ${scale}x, the time line and the path '
        'come back down with the text when the keyboard goes',
        (tester) async {
          AppPlatform.debugTargetPlatformOverride = platform;
          addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(393, 852);
          tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
          tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
          tester.view.viewInsets = const FakeViewPadding(bottom: 336);
          addTearDown(tester.view.reset);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

          final store = MemoryStore();
          store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
          final notes = NotesStore(store, now: () => _now);
          await notes.load();
          final folders = FolderStore(store, now: () => _now);
          await folders.load();
          final note = notes.create();
          notes.updateDocument(
            note.id,
            [
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
            ].join('\n'),
            const [],
            const [],
          );
          folders.file([note.id], folders.create('Work')!.id);
          final prefs = LayoutPrefs(store)..load();

          await tester.pumpWidget(
            KapyNotesApp(
              store: store,
              notes: notes,
              rates: RatesRepository(store),
              prefs: prefs,
              shortcuts: ShortcutPrefs(store)..load(),
              folders: folders,
            ),
          );
          await tester.pumpAndSettle();

          double offset() => tester
              .stateList<ScrollableState>(
                find.descendant(
                  of: find.byType(NoteEditor),
                  matching: find.byType(Scrollable),
                ),
              )
              .firstWhere((state) => state.position.axis == Axis.vertical)
              .position
              .pixels;
          expect(offset(), greaterThan(0));

          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(offset(), 0);

          final line = find.byKey(const ValueKey('note-edited'));
          final path = find.byKey(const ValueKey('note-path'));
          final placed = (tester.getRect(line), tester.getRect(path));
          final reassembled = tester.binding.reassembleApplication();
          await tester.pump();
          await reassembled;
          await tester.pumpAndSettle();
          expect((tester.getRect(line), tester.getRect(path)), placed);
        },
      );
    }
  }
}
