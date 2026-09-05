import 'package:flutter/foundation.dart';

import '../data/note.dart';
import '../data/notes_store.dart';
import '../data/tombstone.dart';
import 'archive.dart';
import 'manifest.dart';

/// Decides what an archive would do to this device before it does any of it.
///
/// Import writes into the local store and stops there. It does not talk to the
/// server, which is the whole reason this is short: the app is local-first, so
/// the notes that land here are simply dirty notes, and the sync that already
/// exists carries them up on its own schedule with the same last-writer-wins
/// rules as any other edit. That also means import works with the network
/// unplugged, and for somebody who has never made an account.

enum ImportMode {
  /// Puts notes back under their own ids and timestamps. For a device that
  /// has lost them. Re-running it changes nothing, because every note already
  /// carries the timestamp the archive holds.
  restore,

  /// Mints new ids and stamps them now. For merging an archive into an account
  /// that already has notes of its own, or one exported by somebody else.
  copies,
}

enum ImportOutcome {
  /// Will be written.
  applied,

  /// This device already holds this exact revision.
  alreadyHere,

  /// The copy here is newer, and keeping it is the same rule sync would apply.
  keptNewer,

  /// Deleted after the export was taken, and the deletion is the later fact.
  deletedSince,

  /// Listed in the manifest, absent from the archive.
  missingFile,
}

class ImportEntry {
  const ImportEntry({
    required this.source,
    required this.outcome,
    this.note,
    this.handEdited = false,
  });

  final ExportedNote source;
  final ImportOutcome outcome;

  /// The note this would write, or null when there is nothing to write.
  final Note? note;

  /// The markdown no longer matched the manifest, so its ranges were read
  /// back out of the text instead.
  final bool handEdited;

  String get title => note?.title ?? source.path;
}

class ImportPlan {
  const ImportPlan({
    required this.mode,
    required this.entries,
    this.problems = const [],
  });

  final ImportMode mode;
  final List<ImportEntry> entries;
  final List<String> problems;

  Iterable<ImportEntry> get applying =>
      entries.where((entry) => entry.outcome == ImportOutcome.applied);

  int get applyCount => applying.length;

  int countOf(ImportOutcome outcome) =>
      entries.where((entry) => entry.outcome == outcome).length;

  int get handEditedCount => applying.where((entry) => entry.handEdited).length;

  bool get isEmpty => applyCount == 0;

  /// Builds the plan for [archive] against what this device currently holds.
  static ImportPlan from({
    required ArchiveContents archive,
    required List<Note> existing,
    required List<Tombstone> tombstones,
    required ImportMode mode,
    required DateTime now,
  }) {
    final manifest = archive.manifest;
    if (manifest == null) {
      return ImportPlan(
        mode: mode,
        entries: const [],
        problems: archive.problems,
      );
    }

    final byId = {for (final note in existing) note.id: note};
    final stones = {for (final stone in tombstones) stone.id: stone};
    final entries = <ImportEntry>[];

    for (final source in manifest.notes) {
      final read = noteFromArchive(source, archive.markdown);
      if (read == null) {
        entries.add(
          ImportEntry(source: source, outcome: ImportOutcome.missingFile),
        );
        continue;
      }

      if (mode == ImportMode.copies) {
        entries.add(
          ImportEntry(
            source: source,
            outcome: ImportOutcome.applied,
            handEdited: read.handEdited,
            note: Note(
              id: NotesStore.newId(),
              body: read.note.body,
              formats: read.note.formats,
              // When it was written is a fact about the note, not about this
              // import, so it survives even though the id does not.
              createdAt: read.note.createdAt,
              updatedAt: now,
            ),
          ),
        );
        continue;
      }

      final incoming = read.note;
      final stone = stones[incoming.id];
      if (stone != null && !stone.deletedAt.isBefore(incoming.updatedAt)) {
        entries.add(
          ImportEntry(
            source: source,
            outcome: ImportOutcome.deletedSince,
            note: incoming,
            handEdited: read.handEdited,
          ),
        );
        continue;
      }

      final local = byId[incoming.id];
      final ImportOutcome outcome;
      if (local == null) {
        outcome = ImportOutcome.applied;
      } else if (local.updatedAt.isAfter(incoming.updatedAt)) {
        outcome = ImportOutcome.keptNewer;
      } else if (_isSameRevision(local, incoming)) {
        outcome = ImportOutcome.alreadyHere;
      } else {
        outcome = ImportOutcome.applied;
      }

      entries.add(
        ImportEntry(
          source: source,
          outcome: outcome,
          note: incoming,
          handEdited: read.handEdited,
        ),
      );
    }

    return ImportPlan(mode: mode, entries: entries, problems: archive.problems);
  }
}

/// True when writing [incoming] would change nothing at all.
///
/// Timestamps are compared as epoch milliseconds for the reason
/// `Note.isDirty` gives: one of these has been through storage and the other
/// off a wire, and `DateTime ==` also compares the UTC flag.
bool _isSameRevision(Note local, Note incoming) =>
    local.body == incoming.body &&
    listEquals(local.formats, incoming.formats) &&
    local.updatedAt.millisecondsSinceEpoch ==
        incoming.updatedAt.millisecondsSinceEpoch;

/// Writes everything the plan decided to apply.
///
/// Returns how many notes were written. The store leaves them dirty, so the
/// next sync pass pushes them like any other edit.
int applyImportPlan(NotesStore store, ImportPlan plan) {
  final notes = plan.applying
      .map((entry) => entry.note!)
      .toList(growable: false);
  if (notes.isEmpty) return 0;
  store.importNotes(notes);
  return notes.length;
}
