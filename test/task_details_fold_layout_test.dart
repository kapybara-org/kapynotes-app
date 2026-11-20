import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/editor/task_details_chrome.dart';
import 'package:material_ui/material_ui.dart';

import 'support/note_driver.dart';
import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'task-details-fold-layout-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  Future<void> pumpNote(WidgetTester tester, String body) async {
    final engine = CalcEngine(ratesPerUsd: const {'EUR': 0.86});
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: NoteEditor(
            noteId: 'fold-layout',
            initialBody: body,
            initialFormats: const [],
            resultsVisible: true,
            writingFont: WritingFont.clean,
            engine: engine,
            highlighter: Highlighter(engine.registry),
            onDocumentChanged: (body, formats, attachments, edit) {},
            onSettingsPressed: () {},
            shortcuts: ShortcutPrefs(_MemoryStore()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder arrows() => find.descendant(
    of: find.byType(TaskDetailsChrome),
    matching: find.byType(GestureDetector),
  );

  testWidgets('a done task with details opens with its arrow and preview', (
    tester,
  ) async {
    await pumpNote(tester, '☑ Call the garage\n  Ask about the tyre.\n');

    expect(arrows(), findsWidgets);
    expect(find.textContaining('Ask about the tyre'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('folding a task keeps the arrows below it on their tasks', (
    tester,
  ) async {
    await pumpNote(
      tester,
      '☐ First\n  One.\n  Two.\n☐ Second\n  Three.\n☐ Third\n',
    );
    final text = tester.widget<NoteField>(noteField).controller.text;
    final driver = NoteDriver(tester);

    double taskCentre(String name) {
      final at = text.indexOf(name);
      final box = driver
          .boxesFor(TextSelection(baseOffset: at, extentOffset: at + 1))
          .single;
      return driver.toGlobal(Offset(0, (box.top + box.bottom) / 2)).dy;
    }

    await tester.tap(arrows().first);
    await tester.pumpAndSettle();

    final second = tester.getCenter(arrows().at(1)).dy;
    expect(second, closeTo(taskCentre('Second'), 12));
    await tester.pump(const Duration(seconds: 3));
  });
}
