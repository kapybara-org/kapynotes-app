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

/// A note with a summarised recording and one at rest, at the phone's own
/// width and at Android's Large text, where the chip's words grow once with
/// the writing and a title takes the line under the row.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final appearance in [AppearanceMode.light, AppearanceMode.dark]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('voice chips in a note at ${scale}x, ${appearance.name}', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final store = _MemoryStore();
        store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
        final prefs = LayoutPrefs(store)..load();
        prefs.appearance = appearance;
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
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle(const Duration(seconds: 1));

        expect(find.byType(NoteVoiceChip), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await screenshot(
          'voice-chip-${scale == 1.0 ? '1x' : 'large-text'}-${appearance.name}',
          device: true,
        );
      });
    }
  }
}
