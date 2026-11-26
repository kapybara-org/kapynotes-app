import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/images/note_image_provider.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/ui/tasks/task_details_sheet.dart';
import 'package:kapy_notes/ui/tasks/task_marks.dart';
import 'package:kapy_notes/ui/tasks/tasks_controller.dart';
import 'package:kapy_notes/ui/tasks/tasks_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'tasks-phone-details-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  late DateTime clock;
  late NotesStore notes;
  late TaskLibrary library;
  late TasksController tasks;
  late FocusNode addFocus;
  late List<String> opened;

  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  Future<void> pumpPhone(
    WidgetTester tester, {
    bool editable = true,
    bool narrowed = false,
    BlobStore? images,
  }) async {
    clock = DateTime(2026, 11, 20, 9);
    final store = _MemoryStore();
    notes = NotesStore(store);
    library = TaskLibrary(
      notes: notes,
      store: store,
      storage: MemoryDocStorage(),
      now: tick,
    );
    await notes.load();
    await library.load();
    final note = notes.create(
      body:
          'Errands\n☐ Pay the rent\n☐ Call the bank\n☐ Hide the menu\n'
          '  It shrinks to a pill.\n☐ Book flights',
    );
    tasks = TasksController(
      notes: notes,
      library: library,
      canEdit: (_) => editable,
      now: tick,
    );
    await tasks.reconcileNow();
    addFocus = FocusNode();
    opened = [];
    addTearDown(() {
      addFocus.dispose();
      tasks.dispose();
      library.dispose();
    });
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: TasksScreen(
            controller: tasks,
            filter: narrowed
                ? TaskFilter.note(note.id)
                : const TaskFilter.all(),
            addFocus: addFocus,
            labelOf: (note) => note.title,
            onOpenNote: opened.add,
            onOpenDone: () {},
            images: images,
            phone: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // The first two open tasks sit on the pair's cards, so the rows start at
  // the third.
  TaskItem listed() =>
      tasks.read().open.firstWhere((item) => item.words == 'Hide the menu');

  final page = find.byType(PhoneTaskPage);

  Future<void> openListed(WidgetTester tester) async {
    await tester.tap(find.byKey(ValueKey('phone-task-${listed().id}')));
    await tester.pumpAndSettle();
  }

  testWidgets('a phone row pushes the task\'s page: ← Tasks, Open in note, '
      'the task, its note and day, and its details', (tester) async {
    await pumpPhone(tester);

    expect(page, findsNothing);
    await openListed(tester);

    expect(page, findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Close'), findsNothing);
    Finder inPage(Finder finder) => find.descendant(of: page, matching: finder);
    expect(inPage(find.byKey(const ValueKey('page-back'))), findsOneWidget);
    expect(inPage(find.text('Tasks')), findsOneWidget);
    expect(inPage(find.text('Open in note')), findsOneWidget);
    expect(inPage(find.text('Hide the menu')), findsOneWidget);
    expect(inPage(find.text('Errands · Today, Fri 20')), findsOneWidget);
    expect(inPage(find.text('It shrinks to a pill.')), findsOneWidget);
    final back = tester.getRect(find.byKey(const ValueKey('page-back')));
    final open = tester.getRect(
      find.byKey(const ValueKey('phone-task-open-note')),
    );
    expect(back.left, lessThan(40), reason: 'top left');
    expect(open.right, greaterThan(390 - 40), reason: 'top right');
    expect(open.center.dy, closeTo(back.center.dy, 1), reason: 'on one row');
    expect(opened, isEmpty, reason: 'the page opens, not the note');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets("a task added yesterday says so on its page, with the day", (
    tester,
  ) async {
    await pumpPhone(tester);
    clock = clock.add(const Duration(days: 1));
    await openListed(tester);
    expect(find.text('Errands · Yesterday, Fri 20'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('← Tasks goes back to the list where it was scrolled to', (
    tester,
  ) async {
    await pumpPhone(tester);
    final note = notes.allNotes.first;
    notes.updateBody(
      note.id,
      '${note.body}\n${[for (var index = 0; index < 20; index++) '☐ Errand $index'].join('\n')}',
    );
    await tasks.reconcileNow();
    await tester.pumpAndSettle();
    final list = find.byType(Scrollable).first;
    await tester.drag(list, const Offset(0, -300));
    await tester.pumpAndSettle();
    final scrolled = tester.state<ScrollableState>(list).position.pixels;
    expect(scrolled, greaterThan(0));

    final row = find
        .byWidgetPredicate(
          (widget) => switch (widget.key) {
            ValueKey<String>(:final value) =>
              value.startsWith('phone-task-') &&
                  !value.startsWith('phone-task-box-'),
            _ => false,
          },
        )
        .hitTestable()
        .first;
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(page, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('page-back')));
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(tester.state<ScrollableState>(list).position.pixels, scrolled);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the system back goes back to Tasks', (tester) async {
    await pumpPhone(tester);
    await openListed(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(find.byType(TasksScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets("iOS's swipe from the left edge goes back to Tasks", (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await pumpPhone(tester);
    await openListed(tester);
    await tester.dragFrom(const Offset(4, 400), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(find.byType(TasksScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('on ${platform.name} a screen reader presses Back as a tap '
        'does, back to Tasks (KAP-365)', (tester) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      final semantics = tester.ensureSemantics();
      await pumpPhone(tester);
      await openListed(tester);
      final back = tester.getSemantics(find.byKey(const ValueKey('page-back')));
      expect(
        back,
        isSemantics(
          label: platform == TargetPlatform.iOS ? 'Back to Tasks' : null,
          isButton: true,
          hasTapAction: true,
        ),
      );
      tester.semantics.tap(
        find.semantics.byPredicate((each) => each.id == back.id),
      );
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      expect(find.byType(TasksScreen), findsOneWidget);
      semantics.dispose();
      await tester.pump(const Duration(seconds: 3));
    });
  }

  testWidgets('every control on the page is 44 pt to tap, and says what it '
      'does to a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpPhone(tester);
    await openListed(tester);
    for (final key in [
      'page-back',
      'phone-task-open-note',
      'phone-details-box',
    ]) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.width, greaterThanOrEqualTo(44), reason: key);
      expect(size.height, greaterThanOrEqualTo(44), reason: key);
    }
    expect(find.bySemanticsLabel('Back to Tasks'), findsOneWidget);
    expect(find.bySemanticsLabel('Open in note'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('phone-details-box'))),
      matchesSemantics(
        label: 'Hide the menu',
        hasCheckedState: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('long details scroll clear of the home indicator, and of the '
      'keyboard while typed into', (tester) async {
    await pumpPhone(tester);
    notes.updateBody(
      notes.allNotes.first.id,
      'Errands\n☐ Pay the rent\n☐ Call the bank\n☐ Hide the menu\n'
      '${[for (var line = 1; line <= 40; line++) '  Line $line'].join('\n')}',
    );
    await tasks.reconcileNow();
    await tester.pumpAndSettle();
    tester.view.padding = const FakeViewPadding(bottom: 102);
    addTearDown(tester.view.resetPadding);
    final ratio = tester.view.devicePixelRatio;
    await openListed(tester);
    expect(page, findsOneWidget);
    final field = find.descendant(of: page, matching: find.byType(TextField));

    await tester.drag(field, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(
      tester.getBottomLeft(field).dy,
      lessThanOrEqualTo(844 - 102 / ratio),
    );

    tester.view.viewInsets = FakeViewPadding(bottom: 300 * ratio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.drag(field, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(field).dy, lessThanOrEqualTo(844 - 300));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the page goes back when its task leaves the note', (
    tester,
  ) async {
    await pumpPhone(tester);
    await openListed(tester);
    expect(page, findsOneWidget);

    notes.updateBody(notes.allNotes.first.id, 'Errands\n☐ Book flights');
    await tasks.reconcileNow();
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(find.text('Book flights'), findsWidgets);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the page edits the note it came from, and Open in note opens '
      'it', (tester) async {
    await pumpPhone(tester);
    await openListed(tester);

    await tester.enterText(
      find.descendant(of: page, matching: find.byType(TextField)),
      'It shrinks to a pill after a few seconds.',
    );
    await tester.pumpAndSettle();
    expect(
      notes.allNotes.first.body,
      contains('  It shrinks to a pill after a few seconds.'),
    );

    await tester.tap(find.text('Open in note'));
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(opened, [notes.allNotes.first.id]);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the box on the page marks the task done in its note, and '
      'back again', (tester) async {
    await pumpPhone(tester);
    await openListed(tester);
    final box = find.byKey(const ValueKey('phone-details-box'));

    await tester.tap(box);
    await tester.pumpAndSettle();
    expect(notes.allNotes.first.body, contains('☑ Hide the menu'));
    expect(page, findsOneWidget);

    await tester.tap(box);
    await tester.pumpAndSettle();
    expect(notes.allNotes.first.body, contains('☐ Hide the menu'));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a task with no details offers Add details, which writes '
      'under it', (tester) async {
    await pumpPhone(tester);
    final flights = tasks.read().open.firstWhere(
      (item) => item.words == 'Book flights',
    );
    await tester.tap(find.byKey(ValueKey('phone-task-${flights.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Writes under the task, in its note.'), findsOneWidget);

    await tester.tap(find.text('Add details'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(of: page, matching: find.byType(TextField)),
      'Window seat',
    );
    await tester.pumpAndSettle();
    expect(
      notes.allNotes.first.body,
      endsWith('☐ Book flights\n  Window seat'),
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'a note shared to view only shows its details and takes nothing',
    (tester) async {
      await pumpPhone(tester, editable: false);
      final before = notes.allNotes.first.body;
      await openListed(tester);

      final field = tester.widget<TextField>(
        find.descendant(of: page, matching: find.byType(TextField)),
      );
      expect(field.readOnly, isTrue);
      expect(field.decoration?.hintText, isNull);
      expect(find.text('Add details'), findsNothing);
      expect(
        find.text('You can view this note, not change it.'),
        findsOneWidget,
      );
      final box = find.byKey(const ValueKey('phone-details-box'));
      expect(tester.widget<GestureDetector>(box).onTap, isNull);
      expect(
        find.descendant(
          of: box,
          matching: find.byWidgetPredicate(
            (widget) => widget is Opacity && widget.opacity == lockedBoxOpacity,
          ),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Semantics>(
              find.ancestor(of: box, matching: find.byType(Semantics)).first,
            )
            .properties
            .onTap,
        isNull,
      );

      await tester.tap(box);
      await tester.pumpAndSettle();
      expect(notes.allNotes.first.body, before);
      expect(find.text('Open in note'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'on a note shared to view only, a phone row\'s box is faint and takes no tap',
    (tester) async {
      await pumpPhone(tester, editable: false);
      final box = find.byKey(ValueKey('phone-task-box-${listed().id}'));
      expect(tester.widget<GestureDetector>(box).onTap, isNull);
      expect(
        tester
            .widget<Semantics>(
              find.ancestor(of: box, matching: find.byType(Semantics)).first,
            )
            .properties
            .onTap,
        isNull,
      );
      expect(
        find.descendant(
          of: box,
          matching: find.byWidgetPredicate(
            (widget) => widget is Opacity && widget.opacity == lockedBoxOpacity,
          ),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'a Do now task in a note shared to view only has no Done on a phone',
    (tester) async {
      await pumpPhone(tester, editable: false);
      tasks.doNow(tasks.read().open.first);
      await tester.pumpAndSettle();
      expect(tasks.read().open.first.doNow, isTrue);
      expect(find.byKey(const ValueKey('tasks-not-finished')), findsOneWidget);
      expect(find.byKey(const ValueKey('tasks-done')), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  for (final editable in [true, false]) {
    testWidgets(
      'on a phone, Tasks narrowed to ${editable ? 'a note you can change has' : 'a note shared to view only has no'} add row',
      (tester) async {
        await pumpPhone(tester, editable: editable, narrowed: true);
        expect(
          find.byKey(const ValueKey('tasks-add-row')),
          editable ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const ValueKey('tasks-add-view-only')),
          editable ? findsNothing : findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 3));
      },
    );
  }

  testWidgets('a phone row shows the lines mark, as the window does', (
    tester,
  ) async {
    await pumpPhone(tester);
    Finder markIn(String id) => find.descendant(
      of: find.byKey(ValueKey('phone-task-$id')),
      matching: find.byWidgetPredicate(
        (widget) => widget is KapyIcon && widget.icon == KapyIcons.alignLeft,
      ),
    );
    expect(markIn(listed().id), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  group('a picture in the details (M14)', () {
    final fields = find.descendant(of: page, matching: find.byType(TextField));
    final pictures = find.byType(TaskDetailPicture);

    // Puts [details] under Hide the menu, a picture at each mark, numbered
    // in order, and opens its page.
    Future<void> openWith(
      WidgetTester tester,
      String details, {
      BlobStore? images,
    }) async {
      await pumpPhone(tester, images: images);
      final note = notes.allNotes.first;
      final body = note.body.replaceFirst('  It shrinks to a pill.', details);
      final marks = [
        for (var i = 0; i < body.length; i++)
          if (body.codeUnitAt(i) == 0xFFFC) i,
      ];
      notes.updateDocument(note.id, body, note.formats, [
        for (var k = 0; k < marks.length; k++)
          NoteImageRef(
            offset: marks[k],
            hash: 'picture-$k',
            key: Uint8List(32),
            mime: 'image/png',
            width: 10,
            height: 10,
            bytes: 8,
          ),
      ]);
      await tasks.reconcileNow();
      await tester.pumpAndSettle();
      await openListed(tester);
    }

    List<String> words(WidgetTester tester) => [
      for (final field in tester.widgetList<TextField>(fields))
        field.controller!.text,
    ];

    // The pictures the page draws, top to bottom, by the mark each draws.
    List<String> drawn(WidgetTester tester) {
      final note = notes.allNotes.first;
      return [
        for (final picture in tester.widgetList<TaskDetailPicture>(pictures))
          (note.attachments.singleWhere((ref) => ref.offset == picture.at)
                  as NoteImageRef)
              .hash,
      ];
    }

    Rect pictureAt(WidgetTester tester, int index) => tester.getRect(
      find.descendant(of: pictures.at(index), matching: find.byType(ClipRRect)),
    );

    // The note says [details] under Hide the menu, and every picture is on
    // its own mark, in order.
    void expectNote(String details, int count) {
      final note = notes.allNotes.first;
      expect(
        note.body,
        'Errands\n☐ Pay the rent\n☐ Call the bank\n☐ Hide the menu\n'
        '$details\n☐ Book flights',
      );
      expect(
        [for (final ref in note.attachments) (ref as NoteImageRef).hash],
        [for (var k = 0; k < count; k++) 'picture-$k'],
      );
      for (final ref in note.attachments) {
        expect(note.body.codeUnitAt(ref.offset), 0xFFFC);
      }
    }

    for (final (name, details, field, edit, after) in [
      (
        'emptying words that end on a picture\'s line keeps its mark',
        '  Before.\n  \uFFFC\n  Middle.\uFFFC\n  After.',
        1,
        '',
        '  Before.\n  \uFFFC\n  \uFFFC\n  After.',
      ),
      (
        'emptying words that start on a picture\'s line keeps the next '
            'picture on a line of its own',
        '  Before.\n  \uFFFCMiddle.\n  \uFFFC\n  After.',
        1,
        '',
        '  Before.\n  \uFFFC\n  \uFFFC\n  After.',
      ),
      (
        'a blank line read between two pictures stays through another edit',
        '  Before.\n  \uFFFC\n\n  \uFFFC\n  After.',
        0,
        'Before!',
        '  Before!\n  \uFFFC\n\n  \uFFFC\n  After.',
      ),
    ]) {
      testWidgets(name, (tester) async {
        await openWith(tester, details);
        await tester.enterText(fields.at(field), edit);
        await tester.pumpAndSettle();
        expectNote(after, 2);
        await tester.pump(const Duration(seconds: 3));
      });
    }

    testWidgets('sits between the lines around its mark, 12 pt from each', (
      tester,
    ) async {
      await openWith(
        tester,
        '  It shrinks to a pill.\n  \uFFFC\n  Then it fades.',
      );
      expect(words(tester), ['It shrinks to a pill.', 'Then it fades.']);
      expect(drawn(tester), ['picture-0']);
      for (final field in tester.widgetList<TextField>(fields)) {
        expect(field.decoration?.hintText, isNull);
      }
      final above = tester.getRect(fields.at(0));
      final picture = pictureAt(tester, 0);
      final below = tester.getRect(fields.at(1));
      expect(picture.size, const Size(200, 96));
      expect(picture.left, above.left);
      expect(picture.top, above.bottom + 12);
      expect(below.top, picture.bottom + 12);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('typing in either field keeps the mark where it was', (
      tester,
    ) async {
      await openWith(
        tester,
        '  It shrinks to a pill.\n  \uFFFC\n  Then it fades.',
      );
      await tester.enterText(fields.at(0), 'It shrinks fast.\nAnd stays.');
      await tester.pumpAndSettle();
      expectNote(
        '  It shrinks fast.\n  And stays.\n  \uFFFC\n  Then it fades.',
        1,
      );
      await tester.enterText(fields.at(1), 'Then it goes.');
      await tester.pumpAndSettle();
      expectNote(
        '  It shrinks fast.\n  And stays.\n  \uFFFC\n  Then it goes.',
        1,
      );
      expect(words(tester), ['It shrinks fast.\nAnd stays.', 'Then it goes.']);
      expect(drawn(tester), ['picture-0']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('several marks each draw their own picture, in order', (
      tester,
    ) async {
      await openWith(
        tester,
        '  One.\n  \uFFFC\n  Two.\n  \uFFFC\uFFFC\n  Three.',
      );
      expect(words(tester), ['One.', 'Two.', 'Three.']);
      expect(drawn(tester), ['picture-0', 'picture-1', 'picture-2']);
      expect(
        pictureAt(tester, 0).top,
        greaterThan(tester.getRect(fields.at(0)).bottom),
      );
      expect(
        tester.getRect(fields.at(1)).top,
        greaterThan(pictureAt(tester, 0).bottom),
      );
      expect(
        pictureAt(tester, 1).top,
        greaterThan(tester.getRect(fields.at(1)).bottom),
      );
      expect(
        pictureAt(tester, 2).top,
        greaterThan(pictureAt(tester, 1).bottom),
      );
      expect(
        tester.getRect(fields.at(2)).top,
        greaterThan(pictureAt(tester, 2).bottom),
      );

      await tester.enterText(fields.at(1), 'Two, typed.');
      await tester.pumpAndSettle();
      expectNote(
        '  One.\n  \uFFFC\n  Two, typed.\n  \uFFFC\uFFFC\n  Three.',
        3,
      );
      expect(drawn(tester), ['picture-0', 'picture-1', 'picture-2']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a mark at the very start leaves an empty field above it, '
        'and words written there go on a line of their own', (tester) async {
      await openWith(tester, '  \uFFFC\n  After.');
      expect(words(tester), ['', 'After.']);
      expect(
        pictureAt(tester, 0).top,
        greaterThan(tester.getRect(fields.at(0)).bottom),
      );
      await tester.enterText(fields.at(0), 'Before.');
      await tester.pumpAndSettle();
      expectNote('  Before.\n  \uFFFC\n  After.', 1);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a mark at the very end leaves an empty field under it, '
        'and words written there go on a line of their own', (tester) async {
      await openWith(tester, '  Before.\n  \uFFFC');
      expect(words(tester), ['Before.', '']);
      expect(
        tester.getRect(fields.at(1)).top,
        greaterThan(pictureAt(tester, 0).bottom),
      );
      await tester.enterText(fields.at(1), 'After.');
      await tester.pumpAndSettle();
      expectNote('  Before.\n  \uFFFC\n  After.', 1);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets(
      'with no mark, the details stay one field and draw no picture',
      (tester) async {
        await openWith(tester, '  It shrinks to a pill.\n  Then it fades.');
        expect(words(tester), ['It shrinks to a pill.\nThen it fades.']);
        expect(pictures, findsNothing);
        expect(
          tester.widget<TextField>(fields).decoration?.hintText,
          'Add details',
        );
        await tester.enterText(fields, 'It shrinks.\nThen it fades.');
        await tester.pumpAndSettle();
        expectNote('  It shrinks.\n  Then it fades.', 0);
        await tester.pump(const Duration(seconds: 3));
      },
    );

    testWidgets('deleting every word on one side keeps the mark, and its '
        'field, with no blank line left', (tester) async {
      await openWith(
        tester,
        '  It shrinks to a pill.\n  \uFFFC\n  Then it fades.',
      );
      await tester.enterText(fields.at(1), '');
      await tester.pumpAndSettle();
      expectNote('  It shrinks to a pill.\n  \uFFFC', 1);
      expect(words(tester), ['It shrinks to a pill.', '']);
      await tester.enterText(fields.at(1), 'Back again.');
      await tester.pumpAndSettle();
      expectNote('  It shrinks to a pill.\n  \uFFFC\n  Back again.', 1);

      await tester.enterText(fields.at(0), '');
      await tester.pumpAndSettle();
      expectNote('  \uFFFC\n  Back again.', 1);
      expect(words(tester), ['', 'Back again.']);
      expect(drawn(tester), ['picture-0']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('emptying the words between two pictures keeps both marks, '
        'with no blank line left', (tester) async {
      await openWith(tester, '  Before.\n  ￼\n  Middle.\n  ￼\n  After.');
      await tester.enterText(fields.at(1), '');
      await tester.pumpAndSettle();
      expectNote('  Before.\n  ￼\n  ￼\n  After.', 2);
      expect(words(tester), ['Before.', '', 'After.']);
      await tester.enterText(fields.at(1), 'Middle again.');
      await tester.pumpAndSettle();
      expectNote('  Before.\n  ￼\n  Middle again.\n  ￼\n  After.', 2);
      expect(drawn(tester), ['picture-0', 'picture-1']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('each picture draws its own mark\'s image', (tester) async {
      await openWith(
        tester,
        '  One.\n  ￼\n  Two.\n  ￼\n  Three.',
        images: BlobStore(),
      );
      final shown = [
        for (var k = 0; k < 2; k++)
          (tester
                      .widget<Image>(
                        find.descendant(
                          of: pictures.at(k),
                          matching: find.byType(Image),
                        ),
                      )
                      .image
                  as NoteImageProvider)
              .hash,
      ];
      expect(shown, ['picture-0', 'picture-1']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('details indented further than they need come out flush, '
        'and a write keeps each untouched line as it was', (tester) async {
      await openWith(
        tester,
        '      It shrinks to a pill.\n      \uFFFC\n        Then it fades.',
      );
      expect(words(tester), ['It shrinks to a pill.', '  Then it fades.']);
      await tester.enterText(fields.at(0), 'It shrinks fast.');
      await tester.pumpAndSettle();
      expectNote(
        '      It shrinks fast.\n      \uFFFC\n        Then it fades.',
        1,
      );
      await tester.enterText(fields.at(1), '  Then it goes.');
      await tester.pumpAndSettle();
      expectNote(
        '      It shrinks fast.\n      \uFFFC\n        Then it goes.',
        1,
      );
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
