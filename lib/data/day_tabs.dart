import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'note_days.dart' show dayKey, dayOfKey;
import 'record_book.dart';
import 'stamped.dart';

/// The most day-tabs records an account holds. Mirrors
/// `DAY_TABS_RECORDS_MAX` in `packages/contract/src/days.ts`.
const int dayTabsRecordsMax = 2000;

/// The most notes one day's order names. Mirrors `DAY_TABS_ORDER_MAX`.
const int dayTabsOrderMax = 64;

/// The largest stamp a record may carry: JavaScript's largest safe integer,
/// where the contract's integers stop.
const int _stampMax = 9007199254740991;

/// One past [at], short of [_stampMax].
int _past(int at) => at < _stampMax ? at + 1 : _stampMax;

/// One day's tabs as a person arranged them: the notes in the order their
/// tabs show, the first [pinned] of them pinned. Mirrors `tabs.v` in
/// `DayTabsPayload`.
@immutable
class TabOrder {
  const TabOrder(this.order, this.pinned, {this.extra = const {}});

  final List<String> order;
  final int pinned;

  /// Fields a later build wrote, kept and written back untouched.
  final Map<String, Object?> extra;

  static const _known = {'order', 'pinned'};

  Map<String, Object?> toJson() => {...extra, 'order': order, 'pinned': pinned};

  /// Null for an order this build can't take: one that names a note twice or
  /// more than [dayTabsOrderMax] of them, or pins more than it names.
  static TabOrder? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final order = raw['order'];
    final pinned = raw['pinned'];
    if (order is! List || pinned is! int) return null;
    final ids = List<String>.unmodifiable(order.whereType<String>());
    if (ids.length != order.length ||
        ids.length > dayTabsOrderMax ||
        ids.toSet().length != ids.length ||
        pinned < 0 ||
        pinned > ids.length) {
      return null;
    }
    return TabOrder(ids, pinned, extra: extraOf(raw, _known));
  }
}

/// A day whose tabs the person put in an order of their own, as its record
/// holds it.
@immutable
class DayTabs {
  const DayTabs({required this.day, required this.tabs, this.extra = const {}});

  static const String kind = 'dayTabs';

  /// The day, `YYYY-MM-DD`, the person's own, as a note's day is.
  final String day;

  /// The order and the pins, one value with one stamp.
  final Stamped<TabOrder> tabs;

  /// Fields a later build wrote, kept and written back untouched.
  final Map<String, Object?> extra;

  static const _known = {'kind', 'day', 'tabs'};

  /// The later arrangement wins, its order and its pins together, the same
  /// whichever side merges.
  DayTabs merge(DayTabs other) => DayTabs(
    day: day,
    tabs: tabs.merge(other.tabs),
    extra: mergeExtra(extra, other.extra),
  );

  Map<String, Object?> toPayload() => {
    ...extra,
    'kind': kind,
    'day': day,
    'tabs': {'v': tabs.v.toJson(), 'at': tabs.at},
  };

  /// Null for a payload missing anything this build needs, for a day that
  /// is not a calendar date, or for an order it can't take.
  static DayTabs? fromPayload(Object? raw) {
    if (raw is! Map) return null;
    final day = raw['day'];
    final tabs = raw['tabs'];
    if (day is! String || dayOfKey(day) == null || tabs is! Map) return null;
    final at = tabs['at'];
    final order = TabOrder.fromJson(tabs['v']);
    if (at is! int || at < 0 || at > _stampMax || order == null) return null;
    return DayTabs(
      day: day,
      tabs: Stamped(order, at),
      extra: extraOf(raw, _known),
    );
  }
}

/// The order a person put each day's notes in as tabs, and which of them are
/// pinned, kept on this device signed in or not and synced on the account's
/// record stream beside the notes' days, as one record per day that has one
/// (see `TaskSync`).
///
/// A day with no record, or whose record is deleted, shows its notes in the
/// order they were started, earliest first, with none pinned. Putting a day
/// back in that order deletes its record.
class DayTabsStore extends ChangeNotifier {
  DayTabsStore(this._store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final LocalStore _store;
  final DateTime Function() _now;

  static const String _key = 'dayTabs.v1';

  /// Keyed by day. A day put back in its own order keeps its record, deleted,
  /// while that delete is ahead of this device's clock, so ordering the day
  /// again is stamped past it (see [_letGo]).
  final _days = RecordBook<DayTabs>(
    keepDeleted: true,
    merge: (mine, theirs) => mine.merge(theirs),
    encode: (tabs) => tabs.toPayload(),
    decode: (day, raw) {
      final tabs = DayTabs.fromPayload(raw);
      return tabs?.day == day ? tabs : null;
    },
  );

  int _stamp() => _now().millisecondsSinceEpoch;

  /// How many more days may be put in an order of their own.
  int get room {
    final live = _days.slots.values.where((slot) => !slot.deleted).length;
    return live >= dayTabsRecordsMax ? 0 : dayTabsRecordsMax - live;
  }

  /// [notes], the ids of [day]'s notes earliest first, in the order their
  /// tabs show, and how many from the front are pinned. A note the record
  /// names that is no longer on the day is skipped, and its pin goes with
  /// it; the notes it doesn't name follow, earliest first.
  ({List<String> order, int pinned}) arrange(DateTime day, List<String> notes) {
    final tabs = _days.live(dayKey(day))?.tabs.v;
    if (tabs == null) return (order: notes, pinned: 0);
    final on = notes.toSet();
    final order = <String>[];
    var pinned = 0;
    for (final (index, id) in tabs.order.indexed) {
      if (!on.contains(id)) continue;
      order.add(id);
      if (index < tabs.pinned) pinned++;
    }
    final named = order.toSet();
    return (
      order: [
        ...order,
        for (final id in notes)
          if (!named.contains(id)) id,
      ],
      pinned: pinned,
    );
  }

  /// Moves [noteId]'s tab to [to] among [day]'s tabs, a pinned one among the
  /// pinned and any other among the rest. False, changing nothing, when the
  /// account already holds [dayTabsRecordsMax] days in orders of their own.
  bool move(DateTime day, List<String> notes, String noteId, int to) {
    final (:order, :pinned) = arrange(day, notes);
    final from = order.indexOf(noteId);
    if (from < 0) return true;
    final place = from < pinned
        ? to.clamp(0, pinned - 1)
        : to.clamp(pinned, order.length - 1);
    if (place == from) return true;
    return _arrange(
      day,
      notes,
      [...order]
        ..removeAt(from)
        ..insert(place, noteId),
      pinned,
    );
  }

  /// Pins [noteId]'s tab, which moves to the front. False, changing nothing,
  /// once [dayTabsOrderMax] tabs are pinned, or when the account already
  /// holds [dayTabsRecordsMax] days in orders of their own.
  bool pin(DateTime day, List<String> notes, String noteId) {
    final (:order, :pinned) = arrange(day, notes);
    final from = order.indexOf(noteId);
    if (from < 0 || from < pinned) return true;
    if (pinned >= dayTabsOrderMax) return false;
    final rest = [...order]..removeAt(from);
    return _arrange(day, notes, [noteId, ...rest], pinned + 1);
  }

  /// Unpins [noteId]'s tab, which moves to just after the tabs still pinned.
  /// False, changing nothing, when the account already holds
  /// [dayTabsRecordsMax] days in orders of their own.
  bool unpin(DateTime day, List<String> notes, String noteId) {
    final (:order, :pinned) = arrange(day, notes);
    final from = order.indexOf(noteId);
    if (from < 0 || from >= pinned) return true;
    return _arrange(
      day,
      notes,
      [...order]
        ..removeAt(from)
        ..insert(pinned - 1, noteId),
      pinned - 1,
    );
  }

  /// Keeps [order] with its first [pinned] pinned as [day]'s, naming at most
  /// [dayTabsOrderMax] notes: the last unpinned go first, and show after the
  /// rest as notes the record doesn't name do. Back in [notes]' own order
  /// with none pinned, the record is deleted.
  bool _arrange(
    DateTime day,
    List<String> notes,
    List<String> order,
    int pinned,
  ) {
    final key = dayKey(day);
    final slot = _days.slots[key];
    final held = slot == null || slot.deleted ? null : slot.value;
    if (pinned == 0 && listEquals(order, notes)) {
      if (held == null) return true;
      _days.delete(key, _stamp());
      _changed();
      return true;
    }
    final named = List<String>.unmodifiable(order.take(dayTabsOrderMax));
    final current = held?.tabs.v;
    if (current != null &&
        current.pinned == pinned &&
        listEquals(current.order, named)) {
      return true;
    }
    if (held == null && room < 1) return false;
    final now = _stamp();
    final value = TabOrder(named, pinned, extra: current?.extra ?? const {});
    final replaced = switch (slot) {
      null => null,
      final slot when slot.deleted => slot.updatedAt,
      final slot => slot.value.tabs.at,
    };
    _days.write(
      key,
      DayTabs(
        day: key,
        tabs: Stamped(
          value,
          replaced == null || now > replaced ? now : _past(replaced),
        ),
        extra: slot?.value.extra ?? const {},
      ),
      now,
    );
    _changed();
    return true;
  }

  /// Lets go of [day]'s record once it is a delete the server has and this
  /// device's clock has passed: an order given from then on outranks it by
  /// its own time.
  void _letGo(String day) {
    final slot = _days.slots[day];
    if (slot != null &&
        slot.deleted &&
        !slot.dirty &&
        slot.updatedAt < _stamp()) {
      _days.slots.remove(day);
    }
  }

  Future<bool>? _loading;

  /// Reads what this device holds, once. False when it held nothing yet,
  /// which a build from before day tabs leaves behind; the record is written
  /// at once, so that is false only the first time.
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

  /// The days this device holds a record for, deleted ones included.
  Iterable<String> get days => _days.slots.keys;

  /// Whether the server is owed anything.
  bool get owes => _days.owes;

  /// What the server has not been told, ordered and put back.
  List<OwedRecord> get owed => _days.owed(DayTabs.kind);

  /// The server took the record as sent. Anything changed since stays owed.
  void acknowledge(OwedRecord record) {
    _days.acknowledge(record.key, record.updatedAt);
    _letGo(record.key);
    _save();
  }

  /// A live record as the server holds it.
  void applyRemote(DayTabs tabs, int updatedAt) {
    _days.applyRemote(tabs.day, tabs, updatedAt);
    _changed();
  }

  /// A deleted record as the server holds it, by [day], where the record id
  /// is known to be that day's. A newer local change survives it and goes up
  /// again.
  void applyRemoteDelete(String day, int updatedAt) {
    if (_days.applyRemoteDelete(day, updatedAt)) {
      _letGo(day);
      _changed();
    }
  }

  /// Signing out: the orders stay, and everything live is owed to the next
  /// account, whose record ids are its own. A deleted record was this
  /// account's, and goes.
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
