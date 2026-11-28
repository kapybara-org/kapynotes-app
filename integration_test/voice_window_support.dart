// The recording both voice window tests open: a note with one voice note
// that has a transcript, a summary and two posts, and a Kapy AI that runs
// on Pro but has nothing agreed to, so a question about the recording stops
// at the card before the first answer. Every request it would make is
// answered here and kept, so a test can show that nothing left. Not a test
// file itself, so neither workflow runs it on its own.
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_ai_controller.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/sync/key_store.dart';

import '../test/ai/ai_fakes.dart';
import '../test/ai/fake_cli.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'voice-window-integration.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// The starters, in the order they sit under the page.
const voiceStarters = [
  'What did we decide?',
  'Create X post',
  'What are the next steps?',
  'Create LinkedIn post',
  'What did Arjun ask for?',
  'Translate to…',
  'Your own words…',
];

/// What an X post is called above its text and in Earlier, the same words
/// as its starter.
const xPostHeading = 'Create X post';

const voiceTitle = 'Pricing page plan with Arjun';

const xPostText =
    'Reworking our pricing page: annual plan first, monthly price under it, '
    'and a price per seat for bigger teams. Live on Friday.';

const ownWordsInstruction = 'Write a short message for my team';

const recordingConsent =
    'Kapy AI sends your question and this transcript through Kapy cloud, '
    'where an AI service answers it. Kapy keeps nothing, and it is never '
    'used to train AI.';

final _now = DateTime(2026, 11, 19, 9, 41);

/// What the window is opened over, and what Kapy AI tried to send.
class VoiceWindowSeed {
  VoiceWindowSeed._(this.store, this.prefs, this.notes, this.kapyAi, this.sent);

  final LocalStore store;
  final LayoutPrefs prefs;
  final NotesStore notes;
  final KapyAiController kapyAi;
  final List<http.Request> sent;

  /// The questions and posts that reached Kapy AI Cloud.
  Iterable<http.Request> get answers =>
      sent.where((request) => request.url.path.endsWith('/ai/answer'));

  static Future<VoiceWindowSeed> create(AppearanceMode appearance) async {
    final store = _MemoryStore();
    store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
    final prefs = LayoutPrefs(store)..load();
    prefs.appearance = appearance;
    final notes = NotesStore(
      store,
      now: () => _now,
      blobs: BlobStore(
        directory: await Directory.systemTemp.createTemp('voice-window'),
      ),
    );
    await notes.load();
    const anchor = NoteAttachmentRef.placeholder;
    const body = 'Call with Arjun\n$anchor\nPricing page by Friday';
    notes.updateDocument(notes.create().id, body, const [], [
      NoteVoiceRef(
        offset: body.indexOf(anchor),
        hash: 'pricing-call',
        key: Uint8List(32),
        bytes: 2048,
        durationMs: 123000,
        peaks: Uint8List.fromList(
          List.generate(100, (i) => 40 + (i * 37) % 180),
        ),
        transcript: VoiceTranscript(
          lang: 'en',
          engine: 'test',
          at: 1,
          speakers: const {0: 'Me', 1: 'Arjun'},
          segments: const [
            TranscriptSegment(
              s: 0,
              e: 6000,
              t:
                  'Thanks for jumping on. I wanted to go through the pricing '
                  'page before Friday.',
              speaker: 0,
            ),
            TranscriptSegment(
              s: 8000,
              e: 15000,
              t:
                  'Sure. The main thing is the annual plan. People should see '
                  'it first, with the monthly price underneath.',
              speaker: 1,
            ),
            TranscriptSegment(
              s: 31000,
              e: 36000,
              t:
                  'So annual on the left, highlighted, and monthly as the '
                  'second option?',
              speaker: 0,
            ),
            TranscriptSegment(
              s: 38000,
              e: 46000,
              t:
                  'Yes. And can we split the first invoice across two months? '
                  'Finance said the first one is the hard sell.',
              speaker: 1,
            ),
            TranscriptSegment(
              s: 75000,
              e: 82000,
              t: 'The 40-seat tier should show a price per seat, not a total.',
              speaker: 1,
            ),
            TranscriptSegment(
              s: 102000,
              e: 110000,
              t:
                  "I'll send you the deck tomorrow morning. The page is due "
                  'Friday.',
              speaker: 0,
            ),
          ],
        ),
        summary: VoiceSummary(
          engine: 'test',
          at: 1,
          title: voiceTitle,
          points: const [
            'Show the annual plan first, with the monthly price under it.',
            'Ask billing whether the first invoice can be split across two '
                'months.',
            'Show the 40-seat tier as a price per seat, not a total.',
            'Send Arjun the deck tomorrow morning; the page is due Friday.',
          ],
        ),
        takes: [
          VoiceTake(
            kind: VoiceTakeKind.x,
            text: xPostText,
            engine: 'test',
            at: DateTime(2026, 11, 19, 10, 2).millisecondsSinceEpoch,
          ),
          VoiceTake(
            kind: VoiceTakeKind.custom,
            instruction: ownWordsInstruction,
            text:
                'Quick update: the pricing page leads with the annual plan, '
                'the 40-seat tier shows a price per seat, and it goes live '
                'on Friday.',
            engine: 'test',
            at: DateTime(2026, 11, 19, 10, 31).millisecondsSinceEpoch,
          ),
        ],
      ),
    ]);

    final sent = <http.Request>[];
    final kapyAi = KapyAiController(
      store: store,
      notes: notes,
      device: FakeDeviceModel(),
      billing: await billingOn(pro: true),
      token: () => 'session-token',
      client: MockClient((request) async {
        sent.add(request);
        return http.Response('', 503);
      }),
      secrets: InMemorySecureStore(),
      codex: FakeLocalTool(
        KapyAccountKind.codex,
        status: KapyAccountStatus.notConnected,
      ),
      claudeCode: FakeLocalTool(
        KapyAccountKind.claudeCode,
        status: KapyAccountStatus.notConnected,
      ),
      apiBaseUrl: Uri.parse('https://api.test/'),
      now: () => _now,
      environment: const {},
      toolHelper: FakeToolHelper(answers: false),
    );
    return VoiceWindowSeed._(store, prefs, notes, kapyAi, sent);
  }
}
