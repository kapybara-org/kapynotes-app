import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/sidebar.dart' show NoteRow;
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show MemoryStore;
import 'support/note_driver.dart';
import 'test_fonts.dart';

/// A long note opened on a phone with the keyboard coming up (KAPY-108).
/// The page lays the note out for the room the keyboard took last time, so
/// the caret is above it from the page's first frame and the note doesn't
/// move while it slides in, however few of those frames a busy phone draws.

const _phone = Size(390, 844);
const _keyboard = 336.0;
const _title = 'Deploying the booking site';
const _bar = ValueKey('phone-format-bar');

final _body = [
  _title,
  for (var i = 1; i <= 60; i++)
    'Paragraph $i weighs up another way to host a booking site cheaply.',
  'If you prefer the easiest deployment workflow and do not mind a small '
      'monthly cost later, use Netlify.',
  'Last line.',
].join('\n');

final _lowCaret = _body.indexOf('cost later');

late MemoryStore store;
late LayoutPrefs prefs;

Future<void> _pump(WidgetTester tester, {int? caret}) async {
  AppPlatform.debugTargetPlatformOverride = defaultTargetPlatform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final now = DateTime.now();
  Map<String, Object?> note(String id, String body, DateTime at) => {
    'id': id,
    'body': body,
    'createdAt': at.millisecondsSinceEpoch,
    'updatedAt': at.millisecondsSinceEpoch,
  };
  store.data['notes.v1'] = [
    note('long', _body, now.subtract(const Duration(hours: 1))),
    note('other', 'Groceries\nMilk', now),
  ];
  final notes = NotesStore(store);
  await notes.load();
  prefs = LayoutPrefs(store)..load();
  if (caret != null) prefs.rememberCaret('long', caret);
  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: RatesRepository(store),
      prefs: prefs,
      shortcuts: ShortcutPrefs(store)..load(),
    ),
  );
  await tester.pumpAndSettle();
  await _home(tester);
}

Future<void> _home(WidgetTester tester) async {
  tester.view.viewInsets = FakeViewPadding.zero;
  await tester.pumpAndSettle();
  final home = find.byKey(const ValueKey('page-home'));
  if (home.evaluate().isEmpty) return;
  await tester.tap(home);
  await tester.pumpAndSettle();
}

/// The open note's caret on screen and how far its note is scrolled.
({Rect caret, double offset}) _seen(WidgetTester tester) {
  final driver = NoteDriver(tester);
  return (
    caret: driver
        .caretRect(driver.value.selection.extent)
        .shift(driver.toGlobal(Offset.zero)),
    offset: tester.widget<NoteField>(noteField).scrollController.offset,
  );
}

/// Opens the long note from the list and brings the keyboard up as a phone
/// does: asked for once the page has focused the note, then, [late] frames
/// later, sliding in over 18 frames while the page turns. A phone too busy
/// to move it stops it a third of the way up for [stall] frames. Returns
/// what each frame showed, from the first one with the page on screen.
Future<List<({Rect caret, double offset})>> _open(
  WidgetTester tester, {
  double keyboard = _keyboard,
  int late = 0,
  int stall = 0,
}) async {
  await tester.tap(find.widgetWithText(NoteRow, _title));
  final frames = <({Rect caret, double offset})>[];
  int? asked;
  for (var frame = 0; frame < 30 + late + stall; frame++) {
    if (asked == null && tester.testTextInput.isVisible) asked = frame;
    if (asked != null) {
      var moved = frame - asked - late;
      if (moved > 6) moved = math.max(6, moved - stall);
      final t = (moved / 18).clamp(0.0, 1.0);
      final inset = keyboard * Curves.easeOutCubic.transform(t);
      // Only a keyboard that moves tells the app so.
      if (inset != tester.view.viewInsets.bottom) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
      }
    }
    await tester.pump(const Duration(milliseconds: 16));
    if (frame > 0) frames.add(_seen(tester));
  }
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
  return frames;
}

/// The caret's row is all in sight, just above the format bar.
void _expectAboveTheBar(WidgetTester tester) {
  final caret = _seen(tester).caret;
  final bar = tester.getRect(find.byKey(_bar));
  expect(bar.bottom, closeTo(_phone.height - _keyboard, 0.01));
  expect(caret.bottom, lessThanOrEqualTo(bar.top));
  expect(caret.bottom, greaterThan(bar.top - 40));
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    store = MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  });

  final phones = TargetPlatformVariant({
    TargetPlatform.iOS,
    TargetPlatform.android,
  });

  for (final (name, caret) in [
    ('a caret left low in it earlier today', _lowCaret),
    ('a new session at its end', null),
  ]) {
    testWidgets('a long note opened again, with $name, is where it ends up '
        'from its first frame, and the keyboard sliding in moves nothing', (
      tester,
    ) async {
      await _pump(tester, caret: caret);
      await _open(tester);
      _expectAboveTheBar(tester);
      await _home(tester);

      final frames = await _open(tester);
      final settled = _seen(tester);
      for (final (index, frame) in frames.indexed) {
        expect(
          frame.offset,
          settled.offset,
          reason: 'frame ${index + 1} scrolled the note',
        );
        expect(frame.caret.top, settled.caret.top);
      }
      _expectAboveTheBar(tester);
    }, variant: phones);
  }

  testWidgets('a keyboard that takes most of a second to start, as an '
      "Android emulator's does, finds a note opened at its end already in "
      'place', (tester) async {
    await _pump(tester);
    await _open(tester);
    await _home(tester);

    // 50 frames of 16 ms: 800 ms before it moves.
    final frames = await _open(tester, late: 50);
    final settled = _seen(tester);
    for (final (index, frame) in frames.indexed) {
      expect(
        frame.offset,
        settled.offset,
        reason: 'frame ${index + 1} scrolled the note',
      );
    }
    _expectAboveTheBar(tester);
  }, variant: phones);

  testWidgets('the first time, with no keyboard seen yet, the note follows '
      'the keyboard up and remembers the room it took', (tester) async {
    await _pump(tester, caret: _lowCaret);
    expect(prefs.keyboardRoom(_phone.width), isNull);
    final frames = await _open(tester);
    expect(frames.last.offset, greaterThan(frames.first.offset));
    _expectAboveTheBar(tester);
    final room = prefs.keyboardRoom(_phone.width);
    expect(room, isNotNull);
    expect(room, greaterThan(_keyboard - 100));
    expect((LayoutPrefs(store)..load()).keyboardRoom(_phone.width), room);
    expect((LayoutPrefs(store)..load()).keyboardRoom(_phone.height), isNull);
  }, variant: phones);

  testWidgets('a keyboard that stops on its way up, on a phone too busy to '
      'move it, is measured once it is all the way up, and the note opened '
      'again stays still through the same stop', (tester) async {
    await _pump(tester);
    // 44 frames of 16 ms: the keyboard stands still for 700 ms.
    await _open(tester, stall: 44);
    final room = prefs.keyboardRoom(_phone.width)!;
    expect(room, greaterThan(_keyboard - 100));
    await _home(tester);

    final frames = await _open(tester, stall: 44);
    final settled = _seen(tester);
    for (final (index, frame) in frames.indexed) {
      expect(
        frame.offset,
        settled.offset,
        reason: 'frame ${index + 1} scrolled the note',
      );
    }
    _expectAboveTheBar(tester);
    expect(prefs.keyboardRoom(_phone.width), room);
  }, variant: phones);

  testWidgets('a smaller keyboard than last time still ends with the caret '
      'in sight, holds no room past it after 5 s, and is remembered', (
    tester,
  ) async {
    await _pump(tester);
    await _open(tester);
    final room = prefs.keyboardRoom(_phone.width)!;
    await _home(tester);

    await _open(tester, keyboard: _keyboard - 60);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final scroll = tester.widget<NoteField>(noteField).scrollController;
    final bar = tester.getRect(find.byKey(_bar));
    final caret = _seen(tester).caret;
    expect(caret.bottom, lessThanOrEqualTo(bar.top));
    expect(scroll.offset, scroll.position.maxScrollExtent);
    expect(prefs.keyboardRoom(_phone.width), closeTo(room - 60, 0.01));
  }, variant: phones);

  testWidgets('a keyboard put away with the note still open gives back the '
      'room held for it at once', (tester) async {
    await _pump(tester);
    await _open(tester);
    await _home(tester);

    await _open(tester, keyboard: _keyboard - 60);
    final open = tester.widget<NoteField>(noteField).scrollController;
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(const Duration(milliseconds: 16));
    final down = open.position.maxScrollExtent;
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(open.position.maxScrollExtent, down);
    expect(prefs.keyboardRoom(_phone.width), greaterThan(0));
  }, variant: phones);

  testWidgets('a keyboard that never comes, as with one plugged in, has its '
      'room held for 5 s and then none, and not held again', (tester) async {
    await _pump(tester);
    await _open(tester);
    await _home(tester);
    final room = prefs.keyboardRoom(_phone.width)!;

    await tester.tap(find.widgetWithText(NoteRow, _title));
    await tester.pumpAndSettle();
    double gap() =>
        tester.getRect(noteField).bottom - _seen(tester).caret.bottom;
    expect(gap(), greaterThan(room - 40));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(gap(), greaterThanOrEqualTo(0));
    expect(gap(), lessThan(40));
    expect(prefs.keyboardRoom(_phone.width), isNull);
    expect((LayoutPrefs(store)..load()).keyboardRoom(_phone.width), isNull);

    await _home(tester);
    await tester.tap(find.widgetWithText(NoteRow, _title));
    await tester.pumpAndSettle();
    expect(gap(), lessThan(40), reason: 'the plugged-in keyboard opens again');
  }, variant: phones);
}
