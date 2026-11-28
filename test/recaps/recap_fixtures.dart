import 'dart:convert';
import 'dart:typed_data';

import 'package:kapy_notes/ai/answer_engine.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/crdt/note_doc.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_board.dart';
import 'package:kapy_notes/data/task_index.dart';
import 'package:kapy_notes/data/time_zones.dart';
import 'package:kapy_notes/recaps/recap_digest.dart';
import 'package:kapy_notes/recaps/recap_material.dart';
import 'package:kapy_notes/recaps/recap_period.dart';

import '../ai/ai_fakes.dart';

/// A recording with a summary and a transcript, a segment every ten
/// seconds, [said] the second one.
NoteVoiceRef recapVoice({
  String hash = 'call',
  String said = 'We ship the annual plan first.',
  int segments = 6,
  String text = 'and then the pricing page',
}) => NoteVoiceRef(
  offset: 0,
  hash: hash,
  key: Uint8List(32),
  bytes: 1,
  durationMs: segments * 10000,
  transcript: VoiceTranscript(
    lang: 'en',
    engine: 'test',
    at: 0,
    segments: [
      for (var i = 0; i < segments; i++)
        TranscriptSegment(
          s: i * 10000,
          e: i * 10000 + 2000,
          t: i == 1 ? said : 'Line $i $text.',
        ),
    ],
  ),
  summary: VoiceSummary(
    engine: 'test',
    at: 0,
    title: 'Pricing call',
    points: ['Annual plan first'],
  ),
);

/// Notes, their tasks and a clock, as the notes list and Tasks read them.
class RecapWorld {
  RecapWorld() {
    final local = MemoryStore();
    index = TaskIndex(local, now: () => clock);
    tags = TagStore(local, now: () => clock);
    folders = FolderStore(local, now: () => clock);
  }

  DateTime clock = DateTime.utc(2026, 11, 1);
  late final TaskIndex index;
  late final TagStore tags;
  late final FolderStore folders;
  final Map<String, NoteDoc> docs = {};
  final List<Note> notes = [];
  late NotesStore store;

  void note(
    String id,
    String edited, {
    String body = 'Note\nWords',
    List<NoteAttachmentRef> attachments = const [],
    bool hidden = false,
    String? hiddenAt,
    String? archivedAt,
    String? created,
  }) {
    final at = DateTime.parse(edited);
    final made = Note(
      id: id,
      body: body,
      attachments: attachments,
      createdAt: created == null
          ? at.subtract(const Duration(hours: 1))
          : DateTime.parse(created),
      updatedAt: at,
      hiddenAt: hiddenAt != null
          ? DateTime.parse(hiddenAt)
          : hidden
          ? at
          : null,
      archivedAt: archivedAt == null ? null : DateTime.parse(archivedAt),
    );
    final doc = docs[id] ??= NoteDoc(replica: 'aaaaaaaaaaaa');
    doc.reconcile(
      body: body,
      formats: const [],
      attachments: const [],
      createdAt: made.createdAt,
    );
    index.reconcileNote(id, doc, idFor: (anchor) => '$id:$anchor');
    notes
      ..removeWhere((n) => n.id == id)
      ..add(made);
  }

  void tick(String instant, void Function() change) {
    clock = DateTime.parse(instant);
    change();
  }

  /// The notes as the app holds them, loaded from what [note] wrote.
  Future<NotesStore> load() async =>
      store = await notesWith([for (final note in notes) note.toJson()]);

  DateTime displayTime(DateTime instant) =>
      AppTimeZones.convert(instant, 'UTC');

  TaskBoard get board => TaskBoard.read(
    entries: index.entries,
    notes: store.allNotes,
    docOf: (id) => docs[id],
  );

  RecapMaterial material(RecapPeriod period) => RecapMaterial.gather(
    period,
    store: store,
    tasks: board,
    tags: tags,
    displayTime: displayTime,
  );

  RecapDigest digest(RecapPeriod period) => RecapDigest.compute(
    period,
    notes: store.allNotes,
    tasks: board,
    tags: tags,
    folders: folders.tree,
    displayTime: displayTime,
  );
}

/// Kapy AI, scripted: each call takes the next of [script], an answer or a
/// failure to throw, and then [reply]. [paid] counts what came back, which
/// is what Kapy AI Cloud counts.
class ScriptedEngine implements AnswerEngine {
  ScriptedEngine([List<Object>? script]) : script = script ?? [];

  final List<Object> script;
  final List<AnswerRequest> asked = [];
  String Function(AnswerRequest request) reply = (_) => 'A digest.';
  int paid = 0;

  @override
  Future<String> answer(KapyModel model, AnswerRequest request) async {
    asked.add(request);
    final next = script.isEmpty ? reply(request) : script.removeAt(0);
    if (next is! String) throw next;
    paid++;
    return next;
  }
}

RecapPeriod dayOf(DateTime day) =>
    RecapPeriod.containing(day, RecapKind.day, firstWeekday: DateTime.monday);

RecapPeriod periodOf(DateTime day, RecapKind kind) =>
    RecapPeriod.containing(day, kind, firstWeekday: DateTime.monday);

/// A recap filter's slot for [id] among [count] × [m], its coding written
/// out again here (RecapFilter), so that a change to it fails.
int recapSlotOf(String id, int count, int m, {bool whole = false}) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(id)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  hash ^= whole ? 0x7f4a7c15 : 0;
  hash ^= hash >> 16;
  hash = (hash * 0x85ebca6b) & 0xffffffff;
  hash ^= hash >> 13;
  hash = (hash * 0xc2b2ae35) & 0xffffffff;
  hash ^= hash >> 16;
  return (hash * count * m) >> 32;
}

/// The bits a recap filter of [m] slots a note codes a gap's low part in.
int recapRiceBits(int m) {
  final bits = ((m * 45426) >> 16).bitLength - 1;
  return bits < 0 ? 0 : bits;
}
