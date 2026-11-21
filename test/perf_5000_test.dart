import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
// R5 {
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/note_days.dart';
// } R5

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const words = [
  'call', 'plan', 'budget', 'groceries', 'meeting', 'notes', 'idea', 'trip',
  'invoice', 'rent', 'books', 'garden', 'project', 'review', 'draft', 'list',
  'weekend', 'doctor', 'school', 'gift', 'recipe', 'coffee', 'train', 'hotel',
  'salary', 'loan', 'insurance', 'car', 'repair', 'paint', '12 + 30', '450 / 3',
  '\$20 in EUR', '15% of 2400',
];

Future<double> timed(Future<void> Function() step) async {
  final watch = Stopwatch()..start();
  await step();
  return watch.elapsedMicroseconds / 1000;
}

String ms(double value) => value.toStringAsFixed(0);

void main() {
  testWidgets('perf: 5,000 notes', (tester) async {
    final random = Random(42);
    final today = DateTime(2026, 11, 20, 12);
    var clock = today;
    final store = MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    final notes = NotesStore(store, now: () => clock);
    final prefs = LayoutPrefs(store);
    final rates = RatesRepository(store);
    final shortcuts = ShortcutPrefs(store);
    final tags = TagStore(store, now: () => clock);
    await notes.load();
    await tags.load();
    final tagIds = [
      for (final name in ['Work', 'Home', 'Money', 'Travel', 'Health', 'Ideas',
          'Family', 'Reading', 'Kitchen', 'Car', 'School', 'Later'])
        tags.create(name)!.id,
    ];
    // R5 {
    final folders = FolderStore(store, now: () => clock);
    await folders.load();
    final days = NoteDayStore(store, now: () => clock);
    await days.load();
    final folderIds = <String>[];
    for (var i = 0; i < 16; i++) {
      final parent = i >= 10 ? folderIds[i - 10] : null;
      folderIds.add(folders.create('Folder ${i + 1}', parentId: parent)!.id);
    }
    // } R5
    final ids = <String>[];
    for (var i = 0; i < 5000; i++) {
      clock = today.subtract(
        Duration(minutes: random.nextInt(700 * 24 * 60)),
      );
      final title = [
        for (var w = 0; w < 2 + random.nextInt(4); w++)
          words[random.nextInt(words.length)],
      ].join(' ');
      final roll = random.nextDouble();
      final lines = roll < 0.4
          ? random.nextInt(3)
          : roll < 0.85
          ? 3 + random.nextInt(15)
          : 20 + random.nextInt(80);
      final body = StringBuffer(i % 20 == 0 ? 'Tax $title' : title);
      for (var l = 0; l < lines; l++) {
        body.write('\n');
        body.write([
          for (var w = 0; w < 3 + random.nextInt(10); w++)
            words[random.nextInt(words.length)],
        ].join(' '));
      }
      final note = notes.create(body: body.toString());
      ids.add(note.id);
      if (random.nextDouble() < 0.3) {
        tags.setTags(note.id, [
          tagIds[random.nextInt(tagIds.length)],
          if (random.nextBool()) tagIds[random.nextInt(tagIds.length)],
        ].toSet().toList());
      }
    }
    clock = today;
    for (var i = 0; i < 25; i++) {
      notes.togglePinned(ids[random.nextInt(ids.length)]);
    }
    // R5 {
    for (final id in ids) {
      final roll = random.nextDouble();
      if (roll < 0.15) {
        final offset = random.nextInt(60) - 30;
        days.setDay(id, DateTime(today.year, today.month, today.day + offset));
      }
      if (random.nextDouble() < 0.4) {
        folders.file([id], folderIds[random.nextInt(folderIds.length)]);
      }
    }
    // } R5
    expect(notes.notes.length, greaterThanOrEqualTo(5000));

    const size = Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    prefs.load();
    if (!prefs.sidebarVisible) prefs.toggleSidebar();
    shortcuts.load();

    final results = <String, String>{};
    results['open'] = ms(await timed(() async {
      await tester.pumpWidget(
        KapyNotesApp(
          store: store,
          notes: notes,
          rates: rates,
          prefs: prefs,
          shortcuts: shortcuts,
          tags: tags,
          // R5 {
          folders: folders,
          days: days,
          // } R5
        ),
      );
      await tester.pumpAndSettle();
    }));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    results['reopen'] = ms(await timed(() async {
      await tester.pumpWidget(
        KapyNotesApp(
          store: store,
          notes: notes,
          rates: RatesRepository(store),
          prefs: prefs,
          shortcuts: shortcuts,
          tags: tags,
          // R5 {
          folders: folders,
          days: days,
          // } R5
        ),
      );
      await tester.pumpAndSettle();
    }));

    await tester.tap(find.byKey(const ValueKey('sidebar-search-field')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('command-menu-field'));
    final typed = <double>[];
    for (final text in ['t', 'ta', 'tax']) {
      typed.add(await timed(() async {
        await tester.enterText(field.first, text);
        await tester.pumpAndSettle();
      }));
    }
    results['filter'] = '${ms(typed.reduce((a, b) => a + b))} (${typed.map(ms).join('/')})';
    results['clear'] = ms(await timed(() async {
      await tester.enterText(field.first, '');
      await tester.pumpAndSettle();
    }));
    final again = <double>[];
    for (final text in ['t', 'ta', 'tax']) {
      again.add(await timed(() async {
        await tester.enterText(field.first, text);
        await tester.pumpAndSettle();
      }));
    }
    results['filterAgain'] = '${ms(again.reduce((a, b) => a + b))} (${again.map(ms).join('/')})';
    await tester.enterText(field.first, '');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-menu')), findsNothing);

    ScrollableState list() {
      final states = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .where((s) => s.position.axis == Axis.vertical && s.position.hasContentDimensions)
          .toList();
      states.sort((a, b) => b.position.maxScrollExtent.compareTo(a.position.maxScrollExtent));
      return states.first;
    }

    Future<void> scrollAll(String name) async {
      final frames = <double>[];
      var guard = 0;
      final watch = Stopwatch()..start();
      while (guard++ < 5000) {
        final position = list().position;
        if (position.pixels >= position.maxScrollExtent - 1) break;
        position.jumpTo(min(position.pixels + 600, position.maxScrollExtent));
        frames.add(await timed(() => tester.pump(const Duration(milliseconds: 16))));
      }
      final total = watch.elapsedMicroseconds / 1000;
      final sorted = [...frames]..sort();
      final p95 = sorted.isEmpty ? 0.0 : sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
      results[name] =
          'total ${ms(total)} frames ${frames.length} mean ${(frames.isEmpty ? 0 : frames.reduce((a, b) => a + b) / frames.length).toStringAsFixed(1)} p95 ${p95.toStringAsFixed(1)} max ${sorted.isEmpty ? 0 : sorted.last.toStringAsFixed(1)} extent ${list().position.maxScrollExtent.toStringAsFixed(0)}';
      list().position.jumpTo(0);
      await tester.pumpAndSettle();
    }

    await scrollAll('scroll');
    // R5 {
    results['byTag'] = ms(await timed(() async {
      prefs.notesGrouping = NotesGrouping.byTag;
      await tester.pumpAndSettle();
    }));
    results['byDate'] = ms(await timed(() async {
      prefs.notesGrouping = NotesGrouping.byDate;
      await tester.pumpAndSettle();
    }));
    results['folders'] = ms(await timed(() async {
      prefs.foldersShown = true;
      await tester.pumpAndSettle();
    }));
    await scrollAll('scrollFolders');
    results['backToNotes'] = ms(await timed(() async {
      prefs.foldersShown = false;
      await tester.pumpAndSettle();
    }));
    // } R5
    // ignore: avoid_print
    print('PERF ${results.entries.map((e) => '${e.key}=${e.value}').join(' | ')}');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
