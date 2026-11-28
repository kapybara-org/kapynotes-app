// A long note opened on a phone with its caret low, the way KAPY-108's
// recording showed it, for KAPY-35 to judge: the note opened once so the
// keyboard's room is known, then opened again and filmed off the device's
// own screen as build/screenshots/note-open.mp4 when the run's host reads
// screens. Opened again, the note is where it ends up from the page's first
// frame and doesn't move while the keyboard slides in. Each frame's scroll
// offset and keyboard inset are printed, as NOTE-OPEN-FRAMES.
//
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/phone_note_open_test.dart -d <device> \
//     --dart-define=KAPYNOTES_SYNC=false
//
// The Phones workflow runs it through tool/ci/phone_screenshots.sh.
import 'dart:convert';

import 'package:flutter/scheduler.dart';
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
import 'package:kapy_notes/ui/sidebar.dart' show NoteRow;
import 'package:material_ui/material_ui.dart';

import 'keyboard_support.dart';
import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-note-open-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _title = 'Deploying the booking site';

final _body = [
  _title,
  for (var i = 1; i <= 40; i++) ...[
    'Option $i: fine for trying things out, but it sleeps after a while '
        'and a customer trying to book waits for it to wake up.',
    '',
  ],
  'Best choice for you',
  'If you prefer the easiest deployment workflow and do not mind a small '
      'monthly cost later, use Netlify.',
  'Then move the database once bookings pick up.',
].join('\n');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a long note opened with its caret low stays put as the '
      'keyboard comes up', (tester) async {
    final now = DateTime.now();
    Map<String, Object?> note(String id, String body, DateTime at) => {
      'id': id,
      'body': body,
      'createdAt': at.millisecondsSinceEpoch,
      'updatedAt': at.millisecondsSinceEpoch,
    };
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    store.data['notes.v1'] = [
      note('long', _body, now.subtract(const Duration(hours: 1))),
      note('other', 'Groceries\nMilk', now),
    ];
    final prefs = LayoutPrefs(store)..load();
    prefs.appearance = AppearanceMode.dark;
    prefs.rememberCaret('long', _body.indexOf('cost later'));
    final notes = NotesStore(store);
    await notes.load();
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

    Future<void> home() async {
      FocusManager.instance.primaryFocus?.unfocus();
      await settleKeyboard(tester, up: false);
      final button = find.byKey(const ValueKey('page-home'));
      if (button.evaluate().isNotEmpty) {
        await tester.tap(button);
        await tester.pumpAndSettle();
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
    }

    final row = find.widgetWithText(NoteRow, _title);
    await home();
    await tester.tap(row);
    await tester.pumpAndSettle();
    await settleKeyboard(tester, up: true);
    await home();

    final frames = <({double inset, double? offset})>[];
    var watching = true;
    void watch(Duration _) {
      if (!watching) return;
      final fields = find.byType(NoteField).evaluate();
      final scroll = fields.isEmpty
          ? null
          : (fields.last.widget as NoteField).scrollController;
      frames.add((
        inset: tester.view.viewInsets.bottom / tester.view.devicePixelRatio,
        offset: scroll != null && scroll.hasClients ? scroll.offset : null,
      ));
      SchedulerBinding.instance.addPostFrameCallback(watch);
    }

    expect(
      await deviceAction('record:note-open'),
      anyOf(isNull, startsWith('no host')),
    );
    addTearDown(() => deviceAction('record-stop'));
    SchedulerBinding.instance.addPostFrameCallback(watch);
    await tester.tap(row);
    await settleKeyboard(tester, up: true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    watching = false;
    await deviceAction('record-stop');
    await screenshot('note-open-settled', device: true);

    // ignore: avoid_print
    print(
      'NOTE-OPEN-FRAMES ${jsonEncode([
        for (final frame in frames)
          if (frame.offset != null) [frame.inset.round(), frame.offset!.round()],
      ])}',
    );
    final offsets = {
      for (final frame in frames)
        if (frame.offset != null && frame.offset! > 0) frame.offset!.round(),
    };
    expect(
      offsets,
      hasLength(1),
      reason: 'the note scrolled as the page came in: $offsets',
    );
    expect(
      tester.widget<NoteField>(find.byType(NoteField)).scrollController.offset,
      closeTo(offsets.single, 1),
    );
  });
}
