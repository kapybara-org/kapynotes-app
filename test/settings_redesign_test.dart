import 'dart:async';
import 'dart:io';

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/calc/format.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/auto_titles.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/voice_prefs.dart';
import 'package:kapy_notes/speech/cloud_access.dart';
import 'package:kapy_notes/speech/summarizer.dart';
import 'package:kapy_notes/speech/transcriber.dart';
import 'package:kapy_notes/ui/hidden_notes_gate.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:kapy_notes/ui/settings_rows.dart';
import 'package:material_ui/material_ui.dart';

import 'billing/billing_fakes.dart';

/// The rows the redesign added: Hidden Notes in Notes, engines chosen by
/// plan, and the appearance preview.

class _Store extends LocalStore {
  _Store() : super(fileName: 'settings-redesign-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

class _Titles implements TitleModel {
  _Titles([this.reason]);

  final String? reason;

  @override
  Future<String?> unavailableReason() async => reason;

  @override
  Future<String> name({required String instructions, required String prompt}) =>
      Completer<String>().future;
}

class _Gate implements HiddenNotesGate {
  _Gate({required this.pin});

  final bool pin;
  int changes = 0;

  @override
  Future<bool> ensureConfigured(BuildContext context) async => true;

  @override
  Future<bool> unlock(BuildContext context) async => true;

  @override
  Future<bool> usesPin() async => pin;

  @override
  Future<bool> changePin(BuildContext context) async {
    changes++;
    return true;
  }
}

/// A device that transcribes everything but Hindi.
class _Device implements Transcriber {
  _Device(this.prefs);

  final VoicePrefs prefs;

  @override
  Future<TranscriberReadiness> readiness() async => prefs.language == 'hi'
      ? TranscriberReadiness.unsupported
      : TranscriberReadiness.ready;

  @override
  Future<TranscriptDraft> transcribe({
    required File audio,
    required String requestId,
    String? language,
  }) async => throw UnimplementedError();
}

late LocalStore store;
late NotesStore notes;
late LayoutPrefs prefs;

Future<void> _open(
  WidgetTester tester, {
  SettingsSection? section,
  HiddenNotesGate? hiddenNotes,
  VoicePrefs? voicePrefs,
  CloudAccess? cloudAccess,
  NoteNamer? namer,
}) async {
  tester.view.physicalSize = const Size(1000, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: SettingsDialog(
          layoutPrefs: prefs,
          shortcuts: ShortcutPrefs(store)..load(),
          rates: RatesRepository(store),
          notes: notes,
          voicePrefs: voicePrefs,
          cloudAccess: cloudAccess,
          hiddenNotes: hiddenNotes,
          namer: namer,
          section: section,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Voice settings for a free account, with [language] chosen.
Future<(VoicePrefs, CloudAccess)> _freeVoice(
  WidgetTester tester, {
  String? language,
}) async {
  final voice = VoicePrefs(store)..load();
  voice.language = language;
  final session = FakeSession();
  final api = FakeBillingApi()..answer = entitlementsFor;
  late Billing billing;
  late CloudAccess access;
  await tester.runAsync(() async {
    billing = billingFor(session, api);
    session.signIn('user-1');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    access = CloudAccess(
      prefs: voice,
      device: _Device(voice),
      billing: billing,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
  });
  addTearDown(() {
    access.dispose();
    billing.dispose();
  });
  return (voice, access);
}

SemanticsProperties _segment(WidgetTester tester, String key) => tester
    .widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(Semantics),
          )
          .first,
    )
    .properties;

void main() {
  setUp(() async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    store = _Store();
    notes = NotesStore(store);
    await notes.load();
    prefs = LayoutPrefs(store)..load();
  });

  group('Name new notes automatically', () {
    final row = find.byKey(const ValueKey('auto-titles-toggle'));

    Future<NoteNamer> open(WidgetTester tester, TitleModel model) async {
      final namer = NoteNamer(
        notes: notes,
        prefs: prefs,
        model: model,
        mayName: (_) => true,
      );
      addTearDown(namer.dispose);
      await _open(tester, section: SettingsSection.notes, namer: namer);
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      return namer;
    }

    SettingsSwitch switchIn(WidgetTester tester) =>
        tester.widget<SettingsSwitch>(
          find.descendant(of: row, matching: find.byType(SettingsSwitch)),
        );

    testWidgets('is off by default with a model on the device, and turns on', (
      tester,
    ) async {
      await open(tester, _Titles());
      expect(
        find.descendant(
          of: row,
          matching: find.text('Name new notes automatically'),
        ),
        findsOneWidget,
      );
      expect(switchIn(tester).value, isFalse);
      expect(switchIn(tester).enabled, isTrue);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(prefs.autoTitlesEnabled, isTrue);
      expect(switchIn(tester).value, isTrue);
    });

    testWidgets('without a model it is off and disabled, and says why', (
      tester,
    ) async {
      const why = 'Turn on Apple Intelligence in System Settings to use this';
      await open(tester, _Titles(why));
      expect(
        find.descendant(of: row, matching: find.text(why)),
        findsOneWidget,
      );
      expect(switchIn(tester).value, isFalse);
      expect(switchIn(tester).enabled, isFalse);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(prefs.autoTitlesEnabled, isFalse, reason: 'nothing to turn on');
    });

    testWidgets('is left out where nothing names notes', (tester) async {
      await _open(tester, section: SettingsSection.notes);
      expect(row, findsNothing);
    });
  });

  testWidgets('Notes asks before deleting again after "Don’t ask again"', (
    tester,
  ) async {
    prefs.askBeforeDeleting = false;
    await _open(tester, section: SettingsSection.notes);

    final toggle = find.byKey(const ValueKey('ask-before-deleting-toggle'));
    await tester.scrollUntilVisible(
      toggle,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      find.descendant(
        of: toggle,
        matching: find.text('Ask before deleting notes'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: toggle,
        matching: find.text(
          'Deleted notes wait 30 days in Recently deleted. Deleting several '
          'at once always asks.',
        ),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SettingsSwitch>(
            find.descendant(of: toggle, matching: find.byType(SettingsSwitch)),
          )
          .value,
      isFalse,
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(prefs.askBeforeDeleting, isTrue);
    expect(store.data['askBeforeDeleting.v1'], isTrue);
  });

  group('Hidden Notes', () {
    testWidgets('the switch moved to Notes and still shows the folder', (
      tester,
    ) async {
      await _open(tester, section: SettingsSection.notes);

      final toggle = find.byKey(const ValueKey('hidden-notes-sidebar-toggle'));
      await tester.scrollUntilVisible(
        toggle,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(prefs.hiddenFolderVisible, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(prefs.hiddenFolderVisible, isFalse);

      await tester.tap(find.byKey(const ValueKey('settings-section-window')));
      await tester.pumpAndSettle();
      expect(toggle, findsNothing);
    });

    testWidgets('Change PIN shows only where a PIN unlocks them', (
      tester,
    ) async {
      await _open(
        tester,
        section: SettingsSection.notes,
        hiddenNotes: _Gate(pin: false),
      );
      expect(
        find.byKey(const ValueKey('change-pin'), skipOffstage: false),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());
      final gate = _Gate(pin: true);
      await _open(tester, section: SettingsSection.notes, hiddenNotes: gate);
      final button = find.byKey(const ValueKey('change-pin-button'));
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(gate.changes, 1);
    });
  });

  group('engines by plan', () {
    testWidgets('free runs voice on this device without forgetting the '
        'saved choice', (tester) async {
      final (voice, access) = await _freeVoice(tester);
      await _open(
        tester,
        section: SettingsSection.voice,
        voicePrefs: voice,
        cloudAccess: access,
      );

      expect(find.text('Cloud transcription is on Pro'), findsOneWidget);
      expect(find.text('Cloud summaries are on Pro'), findsOneWidget);
      expect(_segment(tester, 'transcribe-with-cloud').enabled, isFalse);
      expect(_segment(tester, 'summarise-with-cloud').enabled, isFalse);
      // What the person chose stays saved for the day they have Pro.
      expect(voice.transcriptEngine, TranscriptEngine.cloud);
      expect(voice.summaryEngine, SummaryEngine.cloud);
    });

    testWidgets('a language this device cannot transcribe keeps the cloud', (
      tester,
    ) async {
      final (voice, access) = await _freeVoice(tester, language: 'hi');
      await _open(
        tester,
        section: SettingsSection.voice,
        voicePrefs: voice,
        cloudAccess: access,
      );

      expect(
        find.text(
          "Cloud is used for Hindi, which this device can't transcribe",
        ),
        findsOneWidget,
      );
      expect(find.text('Cloud summaries are on Pro'), findsOneWidget);
    });

    testWidgets('Linux summarises in the cloud, with nothing on the device', (
      tester,
    ) async {
      AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
      final (voice, access) = await _freeVoice(tester);
      await _open(
        tester,
        section: SettingsSection.voice,
        voicePrefs: voice,
        cloudAccess: access,
      );

      expect(find.byKey(const ValueKey('summarise-with-device')), findsNothing);
      expect(find.byKey(const ValueKey('local-summary-line')), findsNothing);
      expect(find.text('Cloud summaries are on Pro'), findsOneWidget);
    });
  });

  testWidgets('the preview writes numbers the way they are set', (
    tester,
  ) async {
    prefs.numberSystem = NumberSystem.indian;
    await _open(tester, section: SettingsSection.appearance);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('appearance-preview')),
        matching: find.text(ResultFormatter.sample(DigitGrouping.indian)),
      ),
      findsOneWidget,
    );
  });

  // A capsule 36 × 16 with a white knob 20.5 × 12.5. The knob stays white
  // on both sides; it is read by its position, not by its contrast on orange.
  for (final dark in const [true, false]) {
    for (final value in const [false, true]) {
      testWidgets('the switch on a ${dark ? 'dark' : 'light'} side, '
          '${value ? 'on' : 'off'}', (tester) async {
        AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? KapyTheme.dark() : KapyTheme.light(),
            home: Center(child: SettingsSwitch(value: value)),
          ),
        );
        await tester.pumpAndSettle();

        final palette = tester.element(find.byType(SettingsSwitch)).palette;
        expect(
          tester.getSize(find.byKey(const ValueKey('compact-switch-indicator'))),
          const Size(36, 16),
        );
        final boxes = find.descendant(
          of: find.byType(SettingsSwitch),
          matching: find.byType(DecoratedBox),
        );
        expect(tester.getSize(boxes.last), const Size(20.5, 12.5));
        BoxDecoration face(Finder box) =>
            tester.widget<DecoratedBox>(box).decoration as BoxDecoration;
        final knob = face(boxes.last);
        expect(knob.boxShadow, isNull);
        expect(knob.color, palette.switchThumb);
        final track = tester
            .widget<AnimatedContainer>(
              find.byKey(const ValueKey('compact-switch-indicator')),
            )
            .decoration! as BoxDecoration;
        expect(track.color, value ? palette.accent : palette.switchTrackOff);
      });
    }
  }
}
