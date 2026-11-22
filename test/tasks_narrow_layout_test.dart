import 'package:flutter/gestures.dart';
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

/// Android 14's 200% text: 12 px doubles, and 100 px and up stays.
class _Android200 extends TextScaler {
  const _Android200();

  static const _from = [0.0, 8, 10, 12, 14, 18, 20, 24, 30, 100];
  static const _to = [0.0, 16, 20, 24, 26, 30, 34, 36, 38, 100];

  @override
  double scale(double fontSize) {
    if (fontSize >= 100) return fontSize;
    for (var i = 0; i < _from.length - 1; i++) {
      if (fontSize <= _from[i + 1]) {
        final t = (fontSize - _from[i]) / (_from[i + 1] - _from[i]);
        return _to[i] + t * (_to[i + 1] - _to[i]);
      }
    }
    return fontSize;
  }

  @override
  double get textScaleFactor => 2;

  @override
  bool operator ==(Object other) => other is _Android200;

  @override
  int get hashCode => 7;
}

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
    TextScaler? scaler,
    TaskFilter filter = const TaskFilter.all(),
    bool scroll = true,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: scaler ?? TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              final screen = TasksScreen(
                controller: tasks,
                filter: filter,
                addFocus: _focus,
                labelOf: (_) => label,
                onOpenNote: (_) {},
                onOpenDone: () {},
                phone: phone,
              );
              return scroll ? SingleChildScrollView(child: screen) : screen;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The left pair card's words, which must keep the card's width.
  Finder pairWords(String words) => find.descendant(
    of: find.byKey(const ValueKey('tasks-pair-left')),
    matching: find.text(words),
  );

  /// The note's name sits under [words] on its own line rather than sharing
  /// theirs, and stays inside [card].
  void expectNoteUnder(
    WidgetTester tester,
    Finder words,
    Finder card,
    String label,
  ) {
    final note = find.descendant(
      of: card,
      matching: find.textContaining(label),
    );
    expect(note, findsOneWidget);
    expect(
      tester.getRect(note).top,
      greaterThanOrEqualTo(tester.getRect(words).bottom - 0.5),
    );
    expect(
      tester.getRect(note).right,
      lessThanOrEqualTo(tester.getRect(card).right + 0.5),
    );
  }

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

  /// A stale task with a long note name, plain, hovered and picked: nothing
  /// overflows, its words keep real room, and Keep, Remove and the note name
  /// stay in the pane. At 1× the row keeps its height and its one line.
  void staleRowTests({required bool touch}) {
    for (final state in ['plain', 'hovered', 'picked']) {
      for (final width in [320.0, 420.0, 768.0]) {
        for (final scale in [1.0, 2.0, 3.1]) {
          testWidgets('a $state stale task in a Tasks pane ${width.round()} '
              'wide at ${scale}x keeps its words, Keep, Remove and its note '
              'name on screen', (tester) async {
            await setUpTasks(
              tester,
              'Errands\n☐ Hide the menu\n☐ Water the plants\n☐ Two',
            );
            tasks.doNow(tasks.read().open.first);
            final item = tasks.read().open.firstWhere(
              (item) => item.words == 'Water the plants',
            );
            if (state == 'picked') tasks.dot(item);
            clock = clock.add(const Duration(days: 15));
            await pumpTasks(
              tester,
              size: Size(width, 1400),
              phone: false,
              label: _shared,
              scale: scale,
            );
            expect(
              tasks.read().open.firstWhere((i) => i.id == item.id).dotted,
              state == 'picked',
            );
            final row = find.byKey(ValueKey(item.id));
            if (state == 'hovered') {
              await tester.ensureVisible(row);
              await tester.pumpAndSettle();
              final mouse = await tester.createGesture(
                kind: PointerDeviceKind.mouse,
              );
              await mouse.addPointer(location: tester.getCenter(row));
              addTearDown(mouse.removePointer);
              await tester.pump();
              final box = tester.widget<DecoratedBox>(
                find
                    .descendant(of: row, matching: find.byType(DecoratedBox))
                    .first,
              );
              expect((box.decoration as BoxDecoration).color, isNotNull);
            }
            expect(tester.takeException(), isNull);
            Finder button(String label) =>
                find.descendant(of: row, matching: find.text(label));
            final words = find.descendant(
              of: row,
              matching: find.text('Water the plants'),
            );
            final others = [
              button('Keep'),
              button('Remove'),
              find.descendant(of: row, matching: find.byType(NoteMark)),
            ];
            final wordsRect = tester.getRect(words);
            expect(
              wordsRect.width,
              greaterThan(16 * scale * 3),
              reason: 'the task kept only its first letters',
            );
            for (final other in others) {
              expectInside(tester, other, width);
              expect(tester.getRect(other).overlaps(wordsRect), isFalse);
            }
            if (scale == 1 && width >= 420) {
              expect(tester.getSize(row).height, touch ? 44 : 36);
              var left = wordsRect.right;
              for (final other in others) {
                final rect = tester.getRect(other);
                expect(rect.center.dy, closeTo(wordsRect.center.dy, 4));
                expect(rect.left, greaterThan(left));
                left = rect.right;
              }
              expect(
                find.descendant(
                  of: row,
                  matching: find.text('Still want this?'),
                ),
                width >= 520 ? findsOneWidget : findsNothing,
              );
            }
            await tester.pump(const Duration(seconds: 3));
          });
        }
      }
    }
  }

  group('on a phone 390 wide', () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    for (final scale in [1.0, 3.1]) {
      testWidgets(
        'at ${scale}x, a long shared note name leaves the first task its card',
        (tester) async {
          await setUpTasks(
            tester,
            'Errands\n☐ Water the plants\n☐ Two\n☐ Three',
          );
          await pumpTasks(
            tester,
            size: const Size(390, 844),
            phone: true,
            label: _shared,
            scale: scale,
          );
          final words = pairWords('Water the plants');
          expect(words, findsOneWidget);
          if (scale == 1) expectOneLine(tester, words, scale);
          expectNoteUnder(
            tester,
            words,
            find.byKey(const ValueKey('tasks-pair-left')),
            'Errands for Bob',
          );
          for (final key in [
            'tasks-pair-left',
            'tasks-pair-right',
            'tasks-start',
          ]) {
            expectInside(tester, find.byKey(ValueKey(key)), 390);
          }
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
        expect(title.height, lessThan(24 * scale * 1.5));
        if (scale == 1) {
          expect(count.left, greaterThanOrEqualTo(title.right - 0.5));
          expect(count.top, lessThan(title.bottom));
        } else {
          expect(count.top, greaterThanOrEqualTo(title.bottom));
        }
        await tester.pump(const Duration(seconds: 3));
      });
    }

    testWidgets('at 3.1x, the first pair and Start with fit', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ Hide the menu\n☐ Two\n☐ Three');
      await pumpTasks(
        tester,
        size: const Size(390, 844),
        phone: true,
        label: 'Errands',
        scale: 3.1,
      );
      final words = pairWords('Hide the menu');
      expect(
        tester.getSize(words).height,
        lessThan(22 * 3.1 * 2.5),
        reason: 'the task words went one word per line',
      );
      for (final key in ['tasks-pair-left', 'tasks-pair-right']) {
        expectInside(tester, find.byKey(ValueKey(key)), 390);
      }
      final start = find.byKey(const ValueKey('tasks-start'));
      expectInside(tester, start, 390);
      final label = find.descendant(
        of: start,
        matching: find.textContaining('Start with'),
      );
      expectWholeLine(
        tester,
        label,
        find.ancestor(of: label, matching: find.byType(Container)).first,
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

  group('on a phone 390 wide with Android 14\'s 200% text', () {
    setUp(
      () => AppPlatform.debugTargetPlatformOverride = TargetPlatform.android,
    );
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    testWidgets('the first pair keeps its words above a long note name', (
      tester,
    ) async {
      await setUpTasks(tester, 'Errands\n☐ Water the plants\n☐ Two\n☐ Three');
      await pumpTasks(
        tester,
        size: const Size(390, 844),
        phone: true,
        label: _shared,
        scaler: const _Android200(),
      );
      expect(tester.takeException(), isNull);
      final words = pairWords('Water the plants');
      expect(
        tester.getSize(words).width,
        greaterThan(const _Android200().scale(16) * 3),
        reason: 'the task kept only its first letters',
      );
      expectNoteUnder(
        tester,
        words,
        find.byKey(const ValueKey('tasks-pair-left')),
        'Errands for Bob',
      );
      for (final key in [
        'tasks-pair-left',
        'tasks-pair-right',
        'tasks-start',
      ]) {
        expectInside(tester, find.byKey(ValueKey(key)), 390);
      }
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a done task keeps its words above a long note name', (
      tester,
    ) async {
      await setUpTasks(tester, 'Errands\n☐ Water the plants\n☐ Two');
      await tasks.setDone(tasks.read().open.first, done: true);
      await pumpTasks(
        tester,
        size: const Size(390, 844),
        phone: true,
        label: _shared,
        scaler: const _Android200(),
        filter: const TaskFilter.done(),
      );
      expect(tester.takeException(), isNull);
      final words = find.text('Water the plants');
      expect(
        tester.getSize(words).width,
        greaterThan(const _Android200().scale(16) * 3),
        reason: 'the task kept only its first letters',
      );
      final mark = find.byType(NoteMark).first;
      expect(
        tester.getRect(mark).top,
        greaterThanOrEqualTo(tester.getRect(words).bottom - 0.5),
      );
      expectInside(tester, words, 390);
      expectInside(tester, mark, 390);
      expectInside(tester, find.text('09:00'), 390);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('on a desktop', () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS);
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    staleRowTests(touch: false);

    for (final width in [420.0, 560.0, 640.0, 768.0, 1024.0]) {
      testWidgets('in a Tasks pane ${width.round()} wide with Android 14\'s '
          '200% text, a stale task keeps its words, Keep, Remove and its note '
          'name on screen', (tester) async {
        await setUpTasks(
          tester,
          'Errands\n☐ Hide the menu\n☐ Water the plants\n☐ Two',
        );
        tasks.doNow(tasks.read().open.first);
        final item = tasks.read().open.firstWhere(
          (item) => item.words == 'Water the plants',
        );
        clock = clock.add(const Duration(days: 15));
        await pumpTasks(
          tester,
          size: Size(width, 1400),
          phone: false,
          label: _shared,
          scaler: const _Android200(),
        );
        expect(tester.takeException(), isNull);
        final row = find.byKey(ValueKey(item.id));
        final words = tester.getRect(
          find.descendant(of: row, matching: find.text('Water the plants')),
        );
        expect(
          words.width,
          greaterThan(const _Android200().scale(16) * 3),
          reason: 'the task kept only its first letters',
        );
        for (final other in [
          find.descendant(of: row, matching: find.text('Keep')),
          find.descendant(of: row, matching: find.text('Remove')),
          find.descendant(of: row, matching: find.byType(NoteMark)),
        ]) {
          expectInside(tester, other, width);
          expect(tester.getRect(other).overlaps(words), isFalse);
        }
        await tester.pump(const Duration(seconds: 3));
      });
    }

    for (final label in ['Errands', _shared]) {
      testWidgets(
        'with a task\'s details open and ${label == _shared ? 'a long' : 'a short'} '
        'note name, Do now keeps its words and its buttons stay clear of the '
        'details',
        (tester) async {
          await setUpTasks(tester, 'Errands\n☐ Hide the menu\n☐ Two');
          tasks.doNow(tasks.read().open.first);
          // The details are a column the page's full height, so the page
          // has one.
          await pumpTasks(
            tester,
            size: const Size(560, 700),
            phone: false,
            label: label,
            scroll: false,
          );
          final second = tasks.read().open[1];
          await tester.tap(
            find
                .descendant(
                  of: find.byKey(ValueKey(second.id)),
                  matching: find.text('Two'),
                )
                .first,
          );
          await tester.pumpAndSettle();
          final sheet = tester.getRect(find.byType(TaskDetailsSheet));
          final card = find.byKey(const ValueKey('tasks-do-now'));
          final words = find.descendant(
            of: card,
            matching: find.text('Hide the menu'),
          );
          expect(
            tester.getSize(words).height,
            lessThan(20 * 2.5),
            reason: 'the task words broke into more than two lines',
          );
          expect(tester.getRect(words).right, lessThanOrEqualTo(sheet.left));
          expectNoteUnder(tester, words, card, label.split(' · ').first);
          for (final key in ['tasks-done', 'tasks-not-finished']) {
            expectInside(tester, find.byKey(ValueKey(key)), sheet.left);
          }
          expect(
            tester.getRect(find.byKey(const ValueKey('tasks-done'))).top,
            greaterThanOrEqualTo(tester.getRect(words).bottom),
            reason: 'beside a narrow column the buttons go under the task',
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
        final row = find.text('Send the weekly report');
        expect(row, findsWidgets);
        expect(find.text('Still want this?'), findsNothing);
        expect(find.text('Keep'), findsWidgets);
        final mark = find.descendant(
          of: find.ancestor(of: row.last, matching: find.byType(Row)).first,
          matching: find.byType(NoteMark),
        );
        expect(tester.getSize(mark).width, lessThanOrEqualTo(480 * 0.4));
        expect(
          tester.getSize(find.byKey(const ValueKey('tasks-note-picker'))).width,
          lessThanOrEqualTo(480 * 0.4),
        );
        expectInside(tester, find.byKey(const ValueKey('tasks-done')), 480);
        await tasks.setDone(tasks.read().open.first, done: true);
        await pumpTasks(
          tester,
          size: const Size(480, 900),
          phone: false,
          label: _shared,
          filter: const TaskFilter.done(),
        );
        final done = find.text('Water the plants');
        expect(
          tester.renderObject<RenderParagraph>(done).didExceedMaxLines,
          isFalse,
          reason: 'the done task lost its words to the note name',
        );
        for (final mark in find.byType(NoteMark).evaluate()) {
          expect(mark.size!.width, lessThanOrEqualTo(220));
        }
        expectInside(tester, find.text('09:00'), 480);
        await tester.pump(const Duration(seconds: 3));
      },
    );

    for (final (width, scale) in [(420.0, 3.1), (900.0, 1.0)]) {
      testWidgets(
        'in a Tasks pane ${width.round()} wide at ${scale}x, an open '
        'task ${scale == 1 ? 'keeps its note name beside its words' : 'puts its note name under its words'}',
        (tester) async {
          await setUpTasks(tester, 'Errands\n☐ Two\n☐ Water the plants');
          tasks.doNow(tasks.read().open.first);
          await pumpTasks(
            tester,
            size: Size(width, 900),
            phone: false,
            label: _shared,
            scale: scale,
          );
          final water = tasks.read().open.firstWhere(
            (item) => item.words == 'Water the plants',
          );
          final row = find.byKey(ValueKey(water.id));
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
              greaterThan(16 * 3.1 * 3),
              reason: 'the note name squeezed the task words',
            );
          }
          expectInside(tester, words, width);
          expectInside(tester, mark, width);
          await tester.pump(const Duration(seconds: 3));
        },
      );
    }

    testWidgets('in a Tasks pane 420 wide at 3.1x, a pair card puts its '
        'note name under its words', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ Hide the menu\n☐ Water the plants');
      await pumpTasks(
        tester,
        size: const Size(420, 900),
        phone: false,
        label: _shared,
        scale: 3.1,
      );
      final card = find.byKey(const ValueKey('tasks-pair-left'));
      final words = pairWords('Hide the menu');
      expect(
        tester.getRect(words).width,
        greaterThan(16 * 3.1 * 3),
        reason: 'the task kept only its first letters',
      );
      expectNoteUnder(tester, words, card, 'Errands for Bob');
      expectInside(tester, card, 420);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('in a Tasks pane 320 wide at 3.1x, Done and Not finished wrap '
        'their words instead of overflowing', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ Water the plants\n☐ Two');
      tasks.doNow(tasks.read().open.first);
      await pumpTasks(
        tester,
        size: const Size(320, 844),
        phone: false,
        label: 'Errands',
        scale: 3.1,
      );
      expect(tester.takeException(), isNull);
      for (final (key, text) in [
        ('tasks-done', 'Done'),
        ('tasks-not-finished', 'Not finished'),
      ]) {
        final pill = find.byKey(ValueKey(key));
        expectInside(tester, pill, 320);
        expectInside(
          tester,
          find.descendant(of: pill, matching: find.text(text)),
          320,
        );
      }
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('in a Tasks pane 640 wide with Android 14\'s 200% text, the '
        'pair stacks its cards', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ Hide the menu\n☐ Water the plants');
      await pumpTasks(
        tester,
        size: const Size(640, 1400),
        phone: false,
        label: 'Errands',
        scaler: const _Android200(),
      );
      expect(tester.takeException(), isNull);
      final left = tester.getRect(
        find.byKey(const ValueKey('tasks-pair-left')),
      );
      final right = tester.getRect(
        find.byKey(const ValueKey('tasks-pair-right')),
      );
      expect(right.top, greaterThanOrEqualTo(left.bottom - 0.5));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('in a Tasks pane 640 wide with Android 14\'s 200% text, Do '
        'now puts its buttons under the task', (tester) async {
      await setUpTasks(tester, 'Errands\n☐ Hide the menu\n☐ Two');
      tasks.doNow(tasks.read().open.first);
      await pumpTasks(
        tester,
        size: const Size(640, 1400),
        phone: false,
        label: 'Errands',
        scaler: const _Android200(),
      );
      expect(tester.takeException(), isNull);
      final words = find.descendant(
        of: find.byKey(const ValueKey('tasks-do-now')),
        matching: find.text('Hide the menu'),
      );
      for (final key in ['tasks-done', 'tasks-not-finished']) {
        expect(
          tester.getRect(find.byKey(ValueKey(key))).top,
          greaterThanOrEqualTo(tester.getRect(words).bottom - 0.5),
        );
      }
      await tester.pump(const Duration(seconds: 3));
    });

    for (final (width, scale, asks) in [
      (768.0, 1.0, true),
      (768.0, 2.0, false),
    ]) {
      testWidgets('in a Tasks pane ${width.round()} wide at ${scale}x, a stale '
          'task ${asks ? 'asks' : 'doesn\'t ask'} "Still want this?"', (
        tester,
      ) async {
        await setUpTasks(
          tester,
          'Errands\n☐ Hide the menu\n☐ Water the plants\n☐ Two',
        );
        tasks.doNow(tasks.read().open.first);
        final item = tasks.read().open.firstWhere(
          (item) => item.words == 'Water the plants',
        );
        clock = clock.add(const Duration(days: 15));
        await pumpTasks(
          tester,
          size: Size(width, 1400),
          phone: false,
          label: 'Errands',
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        final row = find.byKey(ValueKey(item.id));
        expect(
          find.descendant(of: row, matching: find.text('Still want this?')),
          asks ? findsOneWidget : findsNothing,
        );
        expect(
          find.descendant(of: row, matching: find.text('Keep')),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 3));
      });
    }
  });

  group('on a touch screen', () {
    setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

    staleRowTests(touch: true);
  });
}

late FocusNode _focus;
