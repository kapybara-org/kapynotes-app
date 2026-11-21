import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
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

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'kapy56-device-sheet.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _body = 'Friday\n\n'
    '☐ option to hide and turn it into a pill\n'
    '  The menu stays up. After a few seconds it should shrink to a pill.\n'
    '  Check it on the small screen too.\n'
    '☐ Send the weekly report\n';

Future<void> shot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  // ignore: avoid_print
  print('KAPY56SHOT:$name');
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

Future<void> settleReal(WidgetTester tester, int tenths) async {
  for (var i = 0; i < tenths; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

Future<(TasksController, TaskLibrary, NotesStore)> board(bool editable) async {
  var clock = DateTime(2026, 11, 21, 9);
  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));
  final store = _MemoryStore();
  final notes = NotesStore(store, now: tick);
  final library = TaskLibrary(
    notes: notes,
    store: store,
    storage: MemoryDocStorage(),
    now: tick,
  );
  await notes.load();
  await library.load();
  notes.create(body: _body);
  final tasks = TasksController(
    notes: notes,
    library: library,
    canEdit: (_) => editable,
    now: tick,
  );
  await tasks.reconcileNow();
  return (tasks, library, notes);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Widget screen(TasksController tasks, FocusNode focus) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: KapyTheme.dark(),
    home: Scaffold(
      body: SafeArea(
        child: TasksScreen(
          controller: tasks,
          filter: const TaskFilter.all(),
          addFocus: focus,
          labelOf: (note) => note.title,
          onOpenNote: (_) {},
          phone: true,
        ),
      ),
    ),
  );

  testWidgets('the details sheet on a device', (tester) async {
    final (tasks, library, notes) = await board(true);
    final focus = FocusNode();
    await tester.pumpWidget(screen(tasks, focus));
    await shot(tester, 'tasks');

    final first = tasks.read().open.first;
    await tester.tap(find.byKey(ValueKey('phone-task-${first.id}')));
    await tester.pumpAndSettle();
    final body = find.byKey(const ValueKey('phone-details-body'));
    final screenHeight = tester.getSize(find.byType(Scaffold)).height;
    expect(tester.getSize(body).height, closeTo(screenHeight / 2, 40));
    await shot(tester, 'sheet-half');

    final field = find.descendant(
      of: find.byType(TaskDetailsSheet),
      matching: find.byType(TextField),
    );
    await tester.tap(field);
    await settleReal(tester, 20);
    final keyboard = tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
    // ignore: avoid_print
    print('KAPY56KEYBOARD:$keyboard');
    expect(keyboard, greaterThan(100));
    expect(
      tester.getBottomLeft(body).dy,
      lessThanOrEqualTo(screenHeight - keyboard + 1),
    );
    await shot(tester, 'sheet-keyboard');
    await tester.enterText(field, 'The menu stays up. Typed on the device.');
    await settleReal(tester, 10);
    expect(notes.allNotes.first.body, contains('  The menu stays up. Typed on the device.'));
    FocusManager.instance.primaryFocus?.unfocus();
    await settleReal(tester, 15);

    await tester.drag(
      find.byKey(const ValueKey('phone-details-grabber')),
      const Offset(0, -350),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(body).height, greaterThan(screenHeight * 0.85));
    await shot(tester, 'sheet-full');

    await tester.drag(
      find.byKey(const ValueKey('phone-details-grabber')),
      const Offset(0, 600),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PhoneTaskDetailsSheet), findsNothing);

    await tester.pumpWidget(const SizedBox());
    focus.dispose();
    tasks.dispose();
    library.dispose();
  });

  testWidgets('a view-only note on a device', (tester) async {
    final (tasks, library, notes) = await board(false);
    final focus = FocusNode();
    await tester.pumpWidget(screen(tasks, focus));
    await tester.pumpAndSettle();
    final before = notes.allNotes.first.body;
    final first = tasks.read().open.first;
    await tester.tap(find.byKey(ValueKey('phone-task-${first.id}')));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(TaskDetailsSheet),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(field).readOnly, isTrue);
    expect(find.text('You can view this note, not change it.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('phone-details-box')));
    await tester.pumpAndSettle();
    expect(notes.allNotes.first.body, before);
    await shot(tester, 'sheet-view-only');

    await tester.pumpWidget(const SizedBox());
    focus.dispose();
    tasks.dispose();
    library.dispose();
  });
}
