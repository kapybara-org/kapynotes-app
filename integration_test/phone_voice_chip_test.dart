import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';
import 'package:material_ui/material_ui.dart';

import 'rates_support.dart';
import 'screenshot.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'phone-voice-chip-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

final _now = DateTime(2025, 11, 19, 9, 41);

void _report(WidgetTester tester, String label) {
  final meta = find.byKey(const ValueKey('note-edited'));
  final metaRect = meta.evaluate().isEmpty ? 'none' : tester.getRect(meta.first).toString();
  final chips = find.byType(NoteVoiceChip).evaluate().map((e) => tester.getRect(find.byWidget(e.widget)).top.toStringAsFixed(1)).join(',');
  final editor = find.byType(NoteEditor);
  var extra = 'no editor';
  if (editor.evaluate().isNotEmpty) {
    final data = MediaQuery.of(tester.element(editor.first));
    final scroll = find.descendant(of: editor.first, matching: find.byType(Scrollable)).evaluate().map((e) => (e as StatefulElement).state).whereType<ScrollableState>().map((s) => s.position.pixels.toStringAsFixed(1)).join(',');
    extra = 'pad=${data.padding} insets=${data.viewInsets} scale16=${data.textScaler.scale(16)} scroll=[$scroll]';
  }
  debugPrint('HEADERDIAG $label meta=$metaRect chips=[$chips] $extra focus=${FocusManager.instance.primaryFocus}');
}

/// A diagnostic copy of #332's voice-chip test for KAP-323's header question:
/// where the note's time line lands, with spell check on and off, and again
/// 3 s later.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final spell in [true, false]) {
    for (final scale in [1.0, 1.3]) {
      final name = 'hdr-${scale == 1.0 ? '1x' : 'large-text'}-${spell ? 'spell' : 'nospell'}';
      testWidgets(name, (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final store = _MemoryStore();
        store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
        final prefs = LayoutPrefs(store)..load();
        prefs.appearance = AppearanceMode.light;
        prefs.spellCheckEnabled = spell;
        final notes = NotesStore(
          store,
          now: () => _now,
          blobs: BlobStore(
            directory: await Directory.systemTemp.createTemp('voice-chip'),
          ),
        );
        await notes.load();
        const anchor = NoteAttachmentRef.placeholder;
        const body =
            'Call with Arjun\n$anchor\nPricing page by Friday\n$anchor\n'
            'Send the deck';
        final first = body.indexOf(anchor);
        final second = body.indexOf(anchor, first + 1);
        final peaks = Uint8List.fromList(
          List.generate(100, (i) => 40 + (i * 37) % 180),
        );
        notes.updateDocument(notes.create().id, body, const [], [
          NoteVoiceRef(
            offset: first,
            hash: 'standup',
            key: Uint8List(32),
            bytes: 2048,
            durationMs: 123000,
            peaks: peaks,
            summary: VoiceSummary(
              engine: 'cf/llama',
              at: 1,
              title: 'Standup thoughts on the pricing page and the launch',
              points: const ['Ship it.'],
            ),
          ),
          NoteVoiceRef(
            offset: second,
            hash: 'deck',
            key: Uint8List(32),
            bytes: 2048,
            durationMs: 41000,
            peaks: peaks,
          ),
        ]);

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
        _report(tester, '$name launch');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle(const Duration(seconds: 1));
        _report(tester, '$name settled');
        expect(find.byType(NoteVoiceChip), findsNWidgets(2));
        await screenshot(name);
        await Future<void>.delayed(const Duration(seconds: 3));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        _report(tester, '$name late');
        await screenshot('$name-late');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
