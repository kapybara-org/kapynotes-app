import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_kapy_ai.dart';
import 'test_fonts.dart';

/// Where a phone's keyboard goes (KAP-337). A finger outside a text field
/// puts it away, so the bar under it can be reached again, while a control
/// that works with the keyboard keeps it up. The desktop keeps Flutter's own
/// rule, and the note editor its own.

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-keyboard-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _windowMaterial = MethodChannel('kapynotes/window_material');

late LocalStore store;
late NotesStore notes;
late FakeKapyAi ai;

Future<void> _pump(
  WidgetTester tester,
  TargetPlatform platform, {
  Size size = const Size(402, 874),
}) async {
  AppPlatform.debugTargetPlatformOverride = platform;
  addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await notes.load();
  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: RatesRepository(store),
      prefs: LayoutPrefs(store)..load(),
      shortcuts: ShortcutPrefs(store)..load(),
      kapyAi: ai,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _keyboard(WidgetTester tester, {required bool up}) async {
  tester.view.viewInsets = FakeViewPadding(bottom: up ? 300 : 0);
  await tester.pumpAndSettle();
}

bool _typing(WidgetTester tester, Finder field) =>
    tester
        .widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        )
        .focusNode
        .hasFocus &&
    tester.testTextInput.isVisible;

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _tapAt(WidgetTester tester, Offset spot) async {
  await tester.tapAt(spot);
  await tester.pumpAndSettle();
}

Future<void> _home(WidgetTester tester) async {
  final back = find.byKey(const ValueKey('page-home'));
  if (back.evaluate().isNotEmpty) await _tap(tester, back);
}

Future<void> _openKapyAiPage(WidgetTester tester) async {
  await _home(tester);
  await _tap(tester, find.byKey(const ValueKey('bar-kapyAi')));
}

void main() {
  setUpAll(loadTestFonts);

  late bool wasAvailable;
  setUp(() {
    wasAvailable = kapyAiAvailable;
    kapyAiAvailable = true;
    store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    notes = NotesStore(store, now: () => DateTime(2026, 11, 24, 9, 41));
    ai = FakeKapyAi(pro: true)..set(model: KapyModel.cloud);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowMaterial, (call) async => false);
  });
  tearDown(() {
    kapyAiAvailable = wasAvailable;
    ai.dispose();
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    group('on ${platform.name}', () {
      testWidgets('a tap on the Kapy AI page’s empty list puts the keyboard '
          'away, and the bar can be reached again', (tester) async {
        await _pump(tester, platform);
        await _openKapyAiPage(tester);
        final field = find.byKey(const ValueKey('kapy-ai-page-field'));
        await _tap(tester, field);
        await _keyboard(tester, up: true);
        expect(_typing(tester, field), isTrue);

        await _tapAt(
          tester,
          tester.getCenter(find.byKey(const ValueKey('kapy-ai-page-chats'))),
        );
        expect(_typing(tester, field), isFalse);
        expect(tester.testTextInput.hasAnyClients, isFalse);

        await _keyboard(tester, up: false);
        await _tap(tester, find.byKey(const ValueKey('bar-notes')));
        expect(find.byKey(const ValueKey('kapy-ai-page')), findsNothing);
      });

      testWidgets('Ask Kapy AI sits 12 above the keyboard while it’s up, and '
          '12 above the bar once it’s down', (tester) async {
        await _pump(tester, platform);
        await _openKapyAiPage(tester);
        final field = find.byKey(const ValueKey('kapy-ai-page-field'));
        double above(double top) =>
            top -
            tester
                .getRect(
                  find
                      .ancestor(of: field, matching: find.byType(Container))
                      .first,
                )
                .bottom;
        double bar() =>
            tester.getRect(find.byKey(const ValueKey('phone-bar'))).top;
        expect(above(bar()), 12);

        await _tap(tester, field);
        await _keyboard(tester, up: true);
        expect(above(874 - 300), 12);

        await tester.enterText(field, 'What is left');
        await tester.pumpAndSettle();
        expect(above(874 - 300), 12);

        await _tapAt(
          tester,
          tester.getCenter(find.byKey(const ValueKey('kapy-ai-page-chats'))),
        );
        await _keyboard(tester, up: false);
        expect(above(bar()), 12);
      });

      testWidgets('on the Kapy AI page, the model picker and the search pill '
          'keep the keyboard', (tester) async {
        await _pump(tester, platform);
        await _openKapyAiPage(tester);
        final field = find.byKey(const ValueKey('kapy-ai-page-field'));
        final picker = find.byKey(const ValueKey('kapy-ai-picker'));
        final button = find.bySemanticsLabel('Answers with Kapy AI Cloud');
        await _tap(tester, field);
        await _keyboard(tester, up: true);

        await _tap(tester, button);
        expect(picker, findsOneWidget);
        expect(_typing(tester, field), isTrue);
        await _tap(
          tester,
          find.byKey(const ValueKey('kapy-ai-model-cloud-cloud')),
        );
        expect(picker, findsNothing);
        expect(_typing(tester, field), isTrue);

        await _tap(tester, button);
        await _tapAt(
          tester,
          tester.getTopLeft(find.byKey(const ValueKey('kapy-ai-page-chats'))) +
              const Offset(20, 20),
        );
        expect(picker, findsNothing, reason: 'a tap beside it closes it');
        expect(_typing(tester, field), isTrue);

        final search = find.byKey(const ValueKey('kapy-ai-page-search'));
        final line = tester.getRect(search);
        await _tapAt(tester, Offset(line.right - 4, line.top - 4));
        expect(_typing(tester, search), isTrue);
        expect(_typing(tester, field), isFalse);
      });

      testWidgets('on Kapy AI’s sheet, Send, a suggestion, New chat and the '
          'model picker keep the keyboard, and a tap on the chat puts it '
          'away', (tester) async {
        await _pump(tester, platform);
        await _openKapyAiPage(tester);
        await _tap(tester, find.byKey(const ValueKey('kapy-ai-page-new-chat')));
        final field = find.byKey(const ValueKey('kapy-ai-field'));
        await _tap(tester, field);
        await _keyboard(tester, up: true);
        expect(_typing(tester, field), isTrue);

        await tester.enterText(field, 'Find my notes about Lisbon');
        await tester.pump();
        await _tap(tester, find.byKey(const ValueKey('kapy-ai-send')));
        expect(ai.calls.last, startsWith('ask:Find my notes about Lisbon:'));
        expect(_typing(tester, field), isTrue);

        ai.set(answering: false);
        await tester.pumpAndSettle();
        await _tap(tester, find.text('Summarise this note'));
        expect(ai.calls.last, startsWith('ask:Summarise this note:'));
        expect(_typing(tester, field), isTrue);

        await _tap(tester, find.byKey(const ValueKey('kapy-ai-new-chat')));
        expect(ai.calls.last, 'newChat');
        expect(_typing(tester, field), isTrue);

        await _tap(
          tester,
          find.descendant(
            of: find.byKey(const ValueKey('kapy-ai-sheet')),
            matching: find.byKey(const ValueKey('kapy-ai-model-button')),
          ),
        );
        await _tap(
          tester,
          find.byKey(const ValueKey('kapy-ai-model-cloud-cloud')),
        );
        expect(_typing(tester, field), isTrue);

        await _tap(tester, find.text('Ask about anything in your notes'));
        expect(_typing(tester, field), isFalse);
        expect(tester.testTextInput.hasAnyClients, isFalse);
      });

      testWidgets('in Quick find, a scope pill keeps the keyboard and a tap '
          'under the results puts it away', (tester) async {
        notes.create(body: 'Lisbon trip\nBook the Sintra train');
        await _pump(tester, platform);
        await _home(tester);
        await _tap(tester, find.byKey(const ValueKey('sidebar-search-box')));
        final field = find.byKey(const ValueKey('command-menu-field'));
        expect(_typing(tester, field), isTrue);
        await _keyboard(tester, up: true);

        await _tap(tester, find.byKey(const ValueKey('command-scope-notes')));
        expect(_typing(tester, field), isTrue);

        await _tapAt(tester, const Offset(201, 874 - 300 - 24));
        expect(_typing(tester, field), isFalse);
        expect(find.byKey(const ValueKey('command-menu')), findsOneWidget);
      });

      testWidgets('in a note, the format bar and a tap under the text keep '
          'the note focused, as they did', (tester) async {
        notes.create(body: 'Call with Arjun\nSend the deck');
        await _pump(tester, platform);
        await _home(tester);
        await _tap(tester, find.widgetWithText(NoteRow, 'Call with Arjun'));
        final note = find.byType(NoteField);
        await _tap(tester, note);
        await _keyboard(tester, up: true);
        NoteField field() => tester.widget<NoteField>(note);
        expect(field().focusNode.hasFocus, isTrue);

        final quote = find.byKey(const ValueKey('format-quote'));
        await tester.ensureVisible(quote);
        await _tap(tester, quote);
        expect(field().focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        await _tapAt(
          tester,
          tester.getBottomLeft(note) + const Offset(40, -40),
        );
        expect(field().focusNode.hasFocus, isTrue);
        expect(field().controller.selection.isCollapsed, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
      });
    });
  }

  testWidgets('on the desktop, a click outside Kapy AI’s field drops its '
      'focus as it did, its model button included', (tester) async {
    notes.create(body: 'Trip budget\n900 flights');
    await _pump(tester, TargetPlatform.macOS, size: const Size(1500, 800));
    await _tap(tester, find.byKey(const ValueKey('page-kapy-ai')));
    final field = find.byKey(const ValueKey('kapy-ai-field'));
    expect(_typing(tester, field), isTrue);

    await tester.tap(
      find.byKey(const ValueKey('kapy-ai-model-button')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kapy-ai-picker')), findsOneWidget);
    expect(_typing(tester, field), isFalse);

    await tester.tapAt(
      tester.getCenter(find.text('Ask about anything in your notes')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kapy-ai-picker')), findsNothing);
    await tester.tap(field, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(_typing(tester, field), isTrue);
    await tester.tap(
      find.text('Ask about anything in your notes'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(_typing(tester, field), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
