import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/export/archive.dart';
import 'package:kapy_notes/export/archive_service.dart';
import 'package:kapy_notes/ui/export_import.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:material_ui/material_ui.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'export-ui-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
}

/// Stands in for the file picker, which no widget test has.
class _FakeService extends NoteArchiveService {
  _FakeService({this.opens, this.export});

  final ArchiveContents? opens;
  final ExportResult? export;

  List<Note>? exported;

  @override
  Future<ArchiveContents?> openArchive() async => opens;

  @override
  Future<ExportResult> exportNotes(List<Note> notes) async {
    exported = notes;
    return export ??
        ExportResult(
          ExportStatus.written,
          path: '/tmp/KapyNotes-export-2026-09-05.zip',
          noteCount: notes.length,
        );
  }
}

Note _note(String id, String body, {DateTime? updatedAt}) => Note(
  id: id,
  body: body,
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: updatedAt ?? DateTime.utc(2026, 9, 1),
);

ArchiveContents _archive(List<Note> notes) => readExportArchive(
  buildExportArchive(
    notes: notes,
    appVersion: '1.6.0',
    exportedAt: DateTime.utc(2026, 9, 5, 10, 14),
  ),
);

Future<NotesStore> _emptyStore() async {
  final store = NotesStore(_MemoryStore());
  await store.load();
  return store;
}

/// Lets the toast's own dismissal timer run out.
///
/// A [Toast] is an overlay entry that removes itself after a moment. Leaving
/// that timer pending fails the test on a framework invariant rather than on
/// anything the test was about.
Future<void> settleToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// A screen with one button, so a flow that starts from a tap can be driven.
Widget _harness(Future<void> Function(BuildContext) run) => MaterialApp(
  theme: KapyTheme.dark(),
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => run(context),
          child: const Text('go'),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('export hands the picker every note it holds', (tester) async {
    final notes = await _emptyStore();
    notes.create(body: 'One');
    notes.create(body: 'Two');
    final service = _FakeService();

    await tester.pumpWidget(
      _harness((context) => runExport(context, notes, service: service)),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(service.exported, hasLength(2));
    expect(find.text('Exported 2 notes'), findsOneWidget);
    await settleToast(tester);
  });

  testWidgets('import says what it will do before it does it', (tester) async {
    final notes = await _emptyStore();
    final service = _FakeService(
      opens: _archive([_note('a1', 'Weekly review'), _note('b2', 'Groceries')]),
    );

    await tester.pumpWidget(
      _harness((context) => runImport(context, notes, service: service)),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('Import notes'), findsOneWidget);
    expect(find.textContaining('2 notes will be written'), findsOneWidget);
    // Nothing has been written yet.
    expect(notes.notes, isEmpty);

    await tester.tap(find.byKey(const ValueKey('import-confirm')));
    await tester.pumpAndSettle();

    expect(notes.notes.map((note) => note.id), containsAll(['a1', 'b2']));
    expect(find.text('Imported 2 notes'), findsOneWidget);
    await settleToast(tester);
  });

  testWidgets('cancelling writes nothing', (tester) async {
    final notes = await _emptyStore();
    final service = _FakeService(
      opens: _archive([_note('a1', 'Weekly review')]),
    );

    await tester.pumpWidget(
      _harness((context) => runImport(context, notes, service: service)),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(notes.notes, isEmpty);
  });

  testWidgets('a device with notes is asked which way to import', (
    tester,
  ) async {
    final notes = await _emptyStore();
    notes.create(body: 'Something already here');
    final service = _FakeService(
      opens: _archive([_note('a1', 'Weekly review')]),
    );

    await tester.pumpWidget(
      _harness((context) => runImport(context, notes, service: service)),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('import-mode-restore')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('import-mode-copies')));
    await tester.pumpAndSettle();
    expect(find.textContaining('added as copies'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('import-confirm')));
    await tester.pumpAndSettle();

    expect(notes.notes, hasLength(2));
    // A copy is a new note, not the archived one put back.
    expect(notes.notes.map((note) => note.id), isNot(contains('a1')));
    await settleToast(tester);
  });

  testWidgets('a re-import reads as up to date, not as a failure', (
    tester,
  ) async {
    final notes = await _emptyStore();
    final service = _FakeService(
      opens: _archive([_note('a1', 'Weekly review')]),
    );

    await tester.pumpWidget(
      _harness((context) => runImport(context, notes, service: service)),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('import-confirm')));
    await settleToast(tester);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 note already up to date'), findsOneWidget);
    expect(find.text('Nothing to import'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('an export that could not be written says so', (tester) async {
    final notes = await _emptyStore();
    final service = _FakeService(
      export: const ExportResult(
        ExportStatus.failed,
        error: 'Kapy Notes could not write the export.',
      ),
    );

    await tester.pumpWidget(
      _harness((context) => runExport(context, notes, service: service)),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not write the export'), findsOneWidget);
    await settleToast(tester);
  });

  testWidgets('a cancelled export says nothing at all', (tester) async {
    final notes = await _emptyStore();
    final service = _FakeService(
      export: const ExportResult(ExportStatus.cancelled),
    );

    await tester.pumpWidget(
      _harness((context) => runExport(context, notes, service: service)),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Exported'), findsNothing);
  });

  testWidgets('a file that is not an export says so plainly', (tester) async {
    final notes = await _emptyStore();
    final service = _FakeService(
      opens: readExportArchive(Uint8List.fromList(List.filled(32, 9))),
    );

    await tester.pumpWidget(
      _harness((context) => runImport(context, notes, service: service)),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('Import notes'), findsNothing);
    expect(find.textContaining('could not read that file'), findsOneWidget);
    await settleToast(tester);
  });

  testWidgets('the settings pane offers both, and never calls it a backup', (
    tester,
  ) async {
    final backing = _MemoryStore();
    final notes = NotesStore(backing);
    await notes.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: SettingsDialog(
            layoutPrefs: LayoutPrefs(backing),
            shortcuts: ShortcutPrefs(backing),
            rates: RatesRepository(backing),
            notes: notes,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('export-notes')), findsOneWidget);
    expect(find.byKey(const ValueKey('import-notes')), findsOneWidget);

    // "Backup" implies something running on a schedule, and anybody who reads
    // it here will assume they are covered when they are not.
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(
        (text.data ?? '').toLowerCase(),
        isNot(contains('backup')),
        reason: 'export is portability, not a backup',
      );
    }
    // The plaintext warning is where the action is, not buried in a help page.
    expect(find.textContaining('not encrypted'), findsOneWidget);
  });
}
