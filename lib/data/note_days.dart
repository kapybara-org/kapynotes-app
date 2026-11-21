import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'record_book.dart';
import 'stamped.dart';

/// The longest a day may be: `YYYY-MM-DD`, ten characters.
const int noteDayMaxChars = 10;

/// The most note-day records an account holds. Mirrors `DAY_RECORDS_MAX` in
/// `packages/contract/src/days.ts`.
const int noteDayRecordsMax = 20000;

/// The largest stamp a record may carry: JavaScript's largest safe integer,
/// where the contract's integers stop.
const int _stampMax = 9007199254740991;

/// One past [at], short of [_stampMax].
int _past(int at) => at < _stampMax ? at + 1 : _stampMax;

/// [raw] as a stamp a device could have written, or null.
Stamped<T>? _stamped<T>(Object? raw) {
  final stamped = Stamped.fromJson<T>(raw);
  if (stamped == null || stamped.at < 0 || stamped.at > _stampMax) return null;
  return stamped;
}

final RegExp _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// A calendar date as the record holds it: `YYYY-MM-DD`, in the person's own
/// time, never an instant. The date the person sees is the date stored.
String dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// [key] as the day it names, or null when it is not one.
DateTime? dayOfKey(String key) {
  if (key.length != noteDayMaxChars || !_dayPattern.hasMatch(key)) return null;
  final day = DateTime.tryParse(key);
  return day == null ? null : DateTime(day.year, day.month, day.day);
}

/// A note's own day: the calendar date it was given. A note with no record of
/// its own sits on the day it was last edited, as it always has.
@immutable
class NoteDay {
  const NoteDay({
    required this.noteId,
    required this.day,
    this.extra = const {},
  });

  static const String kind = 'noteDay';

  final String noteId;
  final Stamped<String> day;

  /// Fields a later build wrote, kept and written back untouched.
  final Map<String, Object?> extra;

  static const _known = {'kind', 'noteId', 'day'};

  /// The later day wins, the same whichever side merges.
  NoteDay merge(NoteDay other) => NoteDay(
    noteId: noteId,
    day: day.merge(other.day),
    extra: mergeExtra(extra, other.extra),
  );

  Map<String, Object?> toPayload() => {
    ...extra,
    'kind': kind,
    'noteId': noteId,
    'day': day.toJson(),
  };

  /// Null for a payload missing anything this build needs, or for a day that
  /// is not a calendar date.
  static NoteDay? fromPayload(Object? raw) {
    if (raw is! Map) return null;
    final noteId = raw['noteId'];
    final day = _stamped<String>(raw['day']);
    if (noteId is! String || day == null || dayOfKey(day.v) == null) {
      return null;
    }
    return NoteDay(noteId: noteId, day: day, extra: extraOf(raw, _known));
  }
}

/// The day each note was given, kept on this device signed in or not and
/// synced on the account's record stream beside the tasks, tags and folders,
/// as one record per note that has one (see `TaskSync`). The day is the
/// person's own: on a shared note each person keeps a record of their own.
///
/// A note with no record, or whose record is deleted, has no day of its own
/// and sits on its last-edit day. Clearing a day deletes the record.
class NoteDayStore extends ChangeNotifier {
  NoteDayStore(this._store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final LocalStore _store;
  final DateTime Function() _now;

  static const String _key = 'noteDays.v1';

  /// Keyed by note id. A cleared day keeps its record, deleted, while that
  /// delete is ahead of this device's clock, so giving the note a day again
  /// is stamped past it (see [_letGo]).
  final _days = RecordBook<NoteDay>(
    keepDeleted: true,
    merge: (mine, theirs) => mine.merge(theirs),
    encode: (note) => note.toPayload(),
    decode: (noteId, raw) {
      final day = NoteDay.fromPayload(raw);
      return day?.noteId == noteId ? day : null;
    },
  );

  int _stamp() => _now().millisecondsSinceEpoch;

  /// [v] stamped [now], or just after [replaced] when this device's clock is
  /// behind it: a change made over a value outranks it, so a device with a
  /// slow clock can still give a note the same day as one with a fast clock.
  static Stamped<T> _over<T>(Stamped<T> replaced, T v, int now) =>
      Stamped(v, now > replaced.at ? now : _past(replaced.at));

  /// The day [noteId] was given, or null when it has none of its own.
  DateTime? dayOf(String noteId) {
    final slot = _days.slots[noteId];
    return slot == null || slot.deleted ? null : dayOfKey(slot.value.day.v);
  }

  /// How many more notes may be given a day.
  int get room {
    final live = _days.slots.values.where((slot) => !slot.deleted).length;
    return live >= noteDayRecordsMax ? 0 : noteDayRecordsMax - live;
  }

  /// Whether a task in [noteId] waits for the note's day, which keeps it out
  /// of Tasks until then.
  bool taskWaits(String noteId, DateTime today) {
    final day = dayOf(noteId);
    return day != null &&
        day.isAfter(DateTime(today.year, today.month, today.day));
  }

  /// Gives [note]'s a day of its own. False, changing nothing, once the
  /// account holds [noteDayRecordsMax] of them.
  bool setDay(String noteId, DateTime day) {
    final wanted = dayKey(day);
    final slot = _days.slots[noteId];
    final held = slot == null || slot.deleted ? null : slot.value.day.v;
    if (held == wanted) return true;
    if (held == null && room < 1) return false;
    final now = _stamp();
    final stamped = switch (slot) {
      null => Stamped(wanted, now),
      final slot when slot.deleted => Stamped(
        wanted,
        now > slot.updatedAt ? now : _past(slot.updatedAt),
      ),
      final slot => _over(slot.value.day, wanted, now),
    };
    _days.write(
      noteId,
      NoteDay(
        noteId: noteId,
        day: stamped,
        extra: slot?.value.extra ?? const {},
      ),
      now,
    );
    _changed();
    return true;
  }

  /// Takes the day away, so the note goes back to the day it was last edited.
  /// False, changing nothing, when it had no day of its own.
  bool clearDay(String noteId) {
    final slot = _days.slots[noteId];
    if (slot == null || slot.deleted) return false;
    _days.delete(noteId, _stamp());
    _changed();
    return true;
  }

  /// A note deleted for good takes its day with it, and once the server has
  /// that, nothing of it stays: the note is never dated again.
  void forgetNote(String noteId) {
    final slot = _days.slots[noteId];
    if (slot == null || (slot.deleted && slot.dirty)) return;
    if (slot.deleted) {
      _days.slots.remove(noteId);
      _save();
    } else {
      _days.delete(noteId, _stamp());
      _changed();
    }
  }

  /// A note the server never had takes its day with it, unsent.
  void dropNote(String noteId) {
    if (_days.slots.remove(noteId) != null) _changed();
  }

  /// Lets go of [noteId]'s record once it is a delete the server has and this
  /// device's clock has passed: a day given from then on outranks it by its
  /// own time.
  void _letGo(String noteId) {
    final slot = _days.slots[noteId];
    if (slot != null &&
        slot.deleted &&
        !slot.dirty &&
        slot.updatedAt < _stamp()) {
      _days.slots.remove(noteId);
    }
  }

  Future<bool>? _loading;

  /// Reads what this device holds, once. False when it held nothing yet,
  /// which a build from before days leaves behind; the record is written at
  /// once, so that is false only the first time.
  Future<bool> load() => _loading ??= _load();

  Future<bool> _load() async {
    await _store.load();
    final raw = _store.data[_key];
    if (raw is! Map) {
      _store.put(_key, _toJson());
      return false;
    }
    _days.load(raw['days']);
    notifyListeners();
    return true;
  }

  Map<String, Object?> _toJson() => {'days': _days.toJson()};

  bool _held = false;
  bool _unsaved = false;
  bool _untold = false;

  /// Defers the file write and the telling until [release], so a pull of
  /// many records writes once and tells once.
  void hold() => _held = true;

  void release() {
    _held = false;
    if (_unsaved) _save();
    if (_untold) {
      _untold = false;
      notifyListeners();
    }
  }

  void _save() {
    _unsaved = _held;
    if (!_held) _store.put(_key, _toJson());
  }

  void _changed() {
    _save();
    if (_held) {
      _untold = true;
    } else {
      notifyListeners();
    }
  }

  // -------------------------------------------------------------------------
  // Sync

  /// The notes this device holds a day record for, cleared ones included.
  Iterable<String> get noteIds => _days.slots.keys;

  /// Whether the server is owed anything.
  bool get owes => _days.owes;

  /// What the server has not been told, dated and cleared.
  List<OwedRecord> get owed => _days.owed(NoteDay.kind);

  /// The server took the record as sent. Anything changed since stays owed.
  void acknowledge(OwedRecord record) {
    _days.acknowledge(record.key, record.updatedAt);
    _letGo(record.key);
    _save();
  }

  /// A live day as the server holds it.
  void applyRemote(NoteDay day, int updatedAt) {
    _days.applyRemote(day.noteId, day, updatedAt);
    _changed();
  }

  /// A deleted record as the server holds it: a day by [noteId] where the
  /// record id is known to be that note's. A newer local change survives it
  /// and goes up again.
  void applyRemoteDelete(String noteId, int updatedAt) {
    if (_days.applyRemoteDelete(noteId, updatedAt)) {
      _letGo(noteId);
      _changed();
    }
  }

  /// Signing out: the days stay, and everything live is owed to the next
  /// account, whose record ids are its own. A cleared day was this account's
  /// record, and goes.
  void forgetAccount() {
    _days.slots.removeWhere((_, slot) => slot.deleted);
    _days.forgetAccount();
    _save();
  }

  /// Drops everything, for notes let go of on signing in as someone else.
  void clear() {
    _days.slots.clear();
    _changed();
  }
}
