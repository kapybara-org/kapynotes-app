import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/tasks/task_details_sheet.dart';
import 'package:kapy_notes/ui/tasks/task_marks.dart';
import 'package:kapy_notes/ui/tasks/tasks_controller.dart';
import 'package:kapy_notes/ui/tasks/tasks_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'tasks-narrow-layout-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _shared = 'Errands for Bob · With kapy16p-bob-1795219088@example.com';

void main() {
  setUpAll(loadTestFonts);

  late DateTime clock;
  late NotesStore notes;
  late TasksController tasks;

  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  Future<void> setUpTasks(WidgetTester tester, String body) async {
    clock = DateTime(2026, 11, 21, 9);
    final store = _MemoryStore();
    notes = NotesStore(store);
    final library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: tick,
    );
    await notes.load();
    await library.load();
    notes.create(body: body);
    tasks = TasksController(
      notes: notes,
      library: library,
      canEdit: (_) => true,
      now: tick,
    );
    await tasks.reconcileNow();
    final addFocus = FocusNode();
    addTearDown(() {
      addFocus.dispose();
      tasks.dispose();
      library.dispose();
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    _focus = addFocus;
  }

  Future<void> pumpTasks(
    WidgetTester tester, {
    required Size size,
    required bool phone,
    required String label,
    double scale = 1,
    TaskFilter filter = const TaskFilter.all(),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TasksScreen(
              controller: tasks,
              filter: filter,
              addFocus: _focus,
              labelOf: (_) => label,
              onOpenNote: (_) {},
              phone: phone,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The first-on-the-list card's words, which must keep most of its row.
  Finder readyWords(String words) => find.descendant(
    of: find
        .ancestor(
          of: find.text('First on the list'),
          matching: find.byType(Column),
        )
        .first,
    matching: find.text(words),
  );

  /// One line of [finder]'s text at [scale]: no letter-per-line wrapping.
  void expectOneLine(WidgetTester tester, Finder finder, double scale) {
    expect(
      tester.getSize(finder).height,
      lessThan(22 * scale * 1.5),
      reason: 'the task words wrapped onto more than one line',
    );
  }

  /// The task words keep more of their row than the note's name beside them.
  void expectMostOfRow(WidgetTester tester, Finder words) {
    final row = find.ancestor(of: words, matching: find.byType(Row)).first;
    final mark = find.descendant(of: row, matching: find.byType(NoteMark));
    expect(
      tester.getSize(words).width,
      mark.evaluate().isEmpty
          ? greaterThan(tester.getSize(row).width * 0.6)
          : greaterThan(tester.getSize(mark).width),
    );
  }

  /// [text]'s line gets its whole height and sits inside [box], so no letter
  /// is cut at the top or bottom.
  void expectWholeLine(WidgetTester tester, Finder text, Finder box) {
    final paragraph = tester.renderObject<RenderParagraph>(text);
    expect(
      paragraph.size.height,
      greaterThanOrEqualTo(
        paragraph.getMaxIntrinsicHeight(paragraph.size.width) - 0.5,
      ),
    );
    final words = tester.getRect(text);
    final bounds = tester.getRect(box);
    expect(words.top, greaterThanOrEqualTo(bounds.top - 0.5));
    expect(words.bottom, lessThanOrEqualTo(bounds.bottom + 0.5));
  }

  void expectInside(WidgetTester tester, Finder finder, double right) {
    expect(tester.getRect(finder).right, lessThanOrEqualTo(right + 0.5));
  }

  group('on a phone 390 wide', () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    for (final scale in [1.0, 3.1]) {
      testWidgets(
        'at ${scale}x, a long shared note name leaves the first task its row',
        (tester) async {
          await setUpTasks(tester, 'Errands\n☐ Water the plants\n☐ Two');
          await pumpTasks(
            tester,
            size: const Size(390, 844),
            phone: true,
            label: _shared,
            scale: scale,
          );
          final words = readyWords('Water the plants');
          expect(words, findsOneWidget);
          if (scale == 1) expectOneLine(tester, words, scale);
          expectMostOfRow(tester, words);
          expectInside(
            tester,
            find.byKey(const ValueKey('tasks-ready-yes')),
            390,
          );
          expectInside(
            tester,
            find.byKey(const ValueKey('tasks-ready-not-yet')),
            390,
          );
          await tester.pump(const Duration(seconds: 3));
        },
      );
    }

    for (final scale in [1.0, 3.1]) {
      testWidgets('at ${scale}x, "Today" stays on one line, with the count '
          '${scale == 1 ? 'beside' : 'under'} it', (tester) async {
        await setUpTasks(tester, 'Errands\n☐ Hide the menu\n☐ Two');
        await pumpTasks(
          tester,
          size: const Size(390, 844),
          phone: true,
          label: 'Errands',
          scale: scale,
        );
        final title = tester.getRect(find.text('Today'));
        final count = tester.getRect(
          find.byKey(const ValueKey('tasks-done-count')),
        );
        expect(title.height, lessThan(36 * scale * 1.5));
        if (scale == 1) {
          expect(count.left, greaterThanOrEqualTo(title.right - 0.5));
          expect(count.top, lessThan(title.bottom));
        } else {
          expect(count.top, greaterThanOrEqualTo(title.bottom));
        }
        await tester.pump(const Duration(seconds: 3));
      });
    }

    testWidgets('at 3.1x, the first task and its buttons fit', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ Hide the menu\n☐ Two');
      await pumpTasks(
        tester,
        size: const Size(390, 844),
        phone: true,
        label: 'Errands',
        scale: 3.1,
      );
      final words = readyWords('Hide the menu');
      expectMostOfRow(tester, words);
      expect(
        tester.getSize(words).height,
        lessThan(22 * 3.1 * 2.5),
        reason: 'the task words went one word per line',
      );
      expectInside(tester, find.byKey(const ValueKey('tasks-ready-yes')), 390);
      expectInside(
        tester,
        find.byKey(const ValueKey('tasks-ready-not-yet')),
        390,
      );
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('at 3.1x, Do now with a long note name keeps both buttons on '
        'screen', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ Water the plants\n☐ Two');
      tasks.doNow(tasks.read().open.first);
      await pumpTasks(
        tester,
        size: const Size(390, 844),
        phone: true,
        label: _shared,
        scale: 3.1,
      );
      for (final (key, text) in [
        ('tasks-done', 'Done'),
        ('tasks-not-finished', 'Not finished'),
      ]) {
        final pill = find.byKey(ValueKey(key));
        expectInside(tester, pill, 390);
        final words = find.descendant(of: pill, matching: find.text(text));
        expectWholeLine(
          tester,
          words,
          find.ancestor(of: words, matching: find.byType(Container)).first,
        );
      }
      final label = find.descendant(
        of: find.byKey(const ValueKey('tasks-do-now')),
        matching: find.text(_shared),
      );
      expect(
        tester.getSize(label).height,
        lessThanOrEqualTo(18 * 3.1 * 2 + 0.5),
        reason: 'the note name should keep to two lines',
      );
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('at 3.1x, the add row gives "Add a task" its whole line', (
      tester,
    ) async {
      await setUpTasks(tester, 'Errands\n☐ Water the plants');
      await pumpTasks(
        tester,
        size: const Size(390, 844),
        phone: true,
        label: 'Errands',
        scale: 3.1,
      );
      expectWholeLine(
        tester,
        find.text('Add a task'),
        find.byKey(const ValueKey('tasks-add-row')),
      );
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('at 3.1x, the Done list with a long note name fits', (
      tester,
    ) async {
      await setUpTasks(tester, 'Errands\n☐ Water the plants\n☐ Two');
      await tasks.setDone(tasks.read().open.first, done: true);
      await pumpTasks(
        tester,
        size: const Size(390, 844),
        phone: true,
        label: _shared,
        scale: 3.1,
        filter: const TaskFilter.done(),
      );
      final count = find.text('1 completed');
      expect(count, findsOneWidget);
      expect(
        tester.getSize(count).height,
        lessThan(16 * 3.1 * 1.5),
        reason: 'the completed count broke apart',
      );
      final time = find.text('09:00');
      expect(time, findsOneWidget);
      expect(
        tester.getSize(time).height,
        lessThan(16 * 3.1 * 1.5),
        reason: 'the time broke apart',
      );
      expectInside(tester, time, 390);
      final words = find.text('Water the plants');
      expect(words, findsOneWidget);
      expect(find.byType(NoteMark), findsWidgets);
      expectMostOfRow(tester, words);
      expectInside(tester, words, 390);
      await tester.pump(const Duration(seconds: 3));
    });

    for (final scale in [1.0, 3.1]) {
      testWidgets('at ${scale}x, a done task beside a long note name keeps '
          'its words', (tester) async {
        await setUpTasks(tester, 'Errands\n☐ Water the plants\n☐ Two');
        await tasks.setDone(tasks.read().open.first, done: true);
        await pumpTasks(
          tester,
          size: const Size(390, 844),
          phone: true,
          label: _shared,
          scale: scale,
          filter: const TaskFilter.done(),
        );
        final words = find.text('Water the plants');
        final mark = find.descendant(
          of: find
              .ancestor(of: words, matching: find.byType(LayoutBuilder))
              .first,
          matching: find.byType(NoteMark),
        );
        expect(mark, findsOneWidget);
        final wordsRect = tester.getRect(words);
        final markRect = tester.getRect(mark);
        if (scale == 1) {
          expect(markRect.center.dy, closeTo(wordsRect.center.dy, 4));
          expect(markRect.left, greaterThan(wordsRect.right));
        } else {
          expect(markRect.top, greaterThanOrEqualTo(wordsRect.bottom - 0.5));
          expect(
            wordsRect.width,
            greaterThan(16 * 3.1 * 3),
            reason: 'the task kept only its first letter',
          );
        }
        expectInside(tester, words, 390);
        expectInside(tester, mark, 390);
        await tester.pump(const Duration(seconds: 3));
      });
    }
  });

  group('on a desktop', () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    for (final label in ['Errands', _shared]) {
      testWidgets(
        'with a task\'s details open and ${label == _shared ? 'a long' : 'a short'} '
        'note name, the first task keeps its row and its buttons stay clear '
        'of the details',
        (tester) async {
          await setUpTasks(tester, 'Errands\n☐ Hide the menu\n☐ Two');
          await pumpTasks(
            tester,
            size: const Size(560, 700),
            phone: false,
            label: label,
          );
          final second = tasks.read().open[1];
          await tester.tap(
            find.descendant(
              of: find.byKey(ValueKey(second.id)),
              matching: find.text('Two'),
            ),
          );
          await tester.pumpAndSettle();
          final sheet = tester.getRect(find.byType(TaskDetailsSheet));
          final words = readyWords('Hide the menu');
          expect(
            tester.getSize(words).height,
            lessThan(22 * 2.5),
            reason: 'the task words broke into more than two lines',
          );
          expect(
            tester.getRect(find.text('Hide the menu').first).right,
            lessThanOrEqualTo(sheet.left),
          );
          expectMostOfRow(tester, words);
          expectInside(
            tester,
            find.byKey(const ValueKey('tasks-ready-yes')),
            sheet.left,
          );
          expectInside(
            tester,
            find.byKey(const ValueKey('tasks-ready-not-yet')),
            sheet.left,
          );
          await tester.pump(const Duration(seconds: 3));
        },
      );
    }

    testWidgets(
      'in a window 480 wide, long note names leave every row its words',
      (tester) async {
        await setUpTasks(
          tester,
          'Errands\n☐ Water the plants\n☐ Send the weekly report\n'
          '☑ Book flights',
        );
        tasks.doNow(tasks.read().open.first);
        clock = clock.add(const Duration(days: 365));
        await pumpTasks(
          tester,
          size: const Size(480, 900),
          phone: false,
          label: _shared,
        );
        expect(find.text('Send the weekly report'), findsWidgets);
        expectInside(tester, find.byKey(const ValueKey('tasks-done')), 480);
        await pumpTasks(
          tester,
          size: const Size(480, 900),
          phone: false,
          label: _shared,
          filter: const TaskFilter.done(),
        );
        await tester.pump(const Duration(seconds: 3));
      },
    );

    for (final (width, scale) in [(420.0, 3.1), (900.0, 1.0)]) {
      testWidgets(
        'in a Tasks pane ${width.round()} wide at ${scale}x, an open '
        'task ${scale == 1 ? 'keeps its note name beside its words' : 'puts its note name under its words'}',
        (tester) async {
          await setUpTasks(tester, 'Errands\n☐ Water the plants\n☐ Two');
          await pumpTasks(
            tester,
            size: Size(width, 900),
            phone: false,
            label: _shared,
            scale: scale,
          );
          final row = find.byKey(ValueKey(tasks.read().open.first.id));
          final words = find.descendant(
            of: row,
            matching: find.text('Water the plants'),
          );
          final mark = find.descendant(
            of: row,
            matching: find.byType(NoteMark),
          );
          expect(mark, findsOneWidget);
          final wordsRect = tester.getRect(words);
          final markRect = tester.getRect(mark);
          if (scale == 1) {
            expect(markRect.center.dy, closeTo(wordsRect.center.dy, 4));
            expect(markRect.left, greaterThan(wordsRect.right));
          } else {
            expect(markRect.top, greaterThanOrEqualTo(wordsRect.bottom - 0.5));
            expect(
              wordsRect.width,
              greaterThan(tester.getSize(row).width * 0.6),
              reason: 'the note name squeezed the task words',
            );
          }
          expectInside(tester, words, width);
          expectInside(tester, mark, width);
          await tester.pump(const Duration(seconds: 3));
        },
      );
    }

    testWidgets('in a Tasks pane 420 wide at 3.1x, a task to pick puts its '
        'note name under its words', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ Hide the menu\n☐ Water the plants');
      await pumpTasks(
        tester,
        size: const Size(420, 900),
        phone: false,
        label: _shared,
        scale: 3.1,
      );
      final notYet = find.byKey(const ValueKey('tasks-ready-not-yet'));
      await tester.ensureVisible(notYet);
      await tester.tap(notYet);
      await tester.pumpAndSettle();
      final row = find.byKey(
        ValueKey('tasks-candidate-${tasks.read().open[1].id}'),
      );
      final words = find.descendant(
        of: row,
        matching: find.text('Water the plants'),
      );
      final mark = find.descendant(of: row, matching: find.byType(NoteMark));
      expect(mark, findsOneWidget);
      final wordsRect = tester.getRect(words);
      expect(
        tester.getRect(mark).top,
        greaterThanOrEqualTo(wordsRect.bottom - 0.5),
      );
      expect(
        wordsRect.width,
        greaterThan(16 * 3.1 * 3),
        reason: 'the task kept only its first letters',
      );
      expectInside(tester, words, 420);
      expectInside(tester, mark, 420);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}

late FocusNode _focus;
