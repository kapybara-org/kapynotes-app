import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/note.dart';
import '../data/notes_store.dart';
import '../sync/account.dart';
import 'billing.dart';
import 'plan_terms.dart';

/// Which notes may be edited, for an account on Free.
///
/// The note limit is the one limit the server cannot enforce: Free does not
/// sync, so its notes are only on the device and only the app can count them.
/// Going over deletes nothing. The first [limit] notes in the list, taken as
/// the list is drawn — pinned first, then the most recently edited — stay
/// editable. Every other note can still be opened, copied, exported, archived
/// and deleted, but not changed, and no new note can be started until there
/// are fewer than [limit]. Pinning is how somebody chooses which notes those
/// are, and deleting is how they get back under.
///
/// Archived notes count, or the archive would be a way round the limit, and
/// they stay read-only while the account is over. Notes in a space somebody
/// else owns are that owner's to count, and never count here.
///
/// The limit itself is never worked out here. Signed in it is the server's
/// `noteLimit` — null until plans are enforced, and for as long as Pro or a
/// trial of it lasts. Signed out it is [PlanTerms]'s, once this device's own
/// fourteen days are over, unless Pro was bought here before anybody signed
/// in: unlimited notes is the one part of Pro that needs no account behind
/// it, so it is the one part a purchase can unlock without one. While the account is still being read at launch
/// there is none, so no note locks for the moment before a Pro account is
/// known to be one.
class NoteLimit extends ChangeNotifier {
  NoteLimit({
    required NotesStore notes,
    required Account account,
    required PlanTerms terms,
    DateTime Function()? now,
  }) : _notes = notes,
       _account = account,
       _terms = terms,
       _now = now ?? DateTime.now {
    _notes.addListener(_update);
    _account.addListener(_onAccount);
    _terms.addListener(_update);
    _onAccount();
  }

  final NotesStore _notes;
  final Account _account;
  final PlanTerms _terms;
  final DateTime Function() _now;

  Billing? _billing;
  AccountState? _state;
  Timer? _deviceTrialEnd;
  DateTime? _deviceTrialEndArmedFor;
  bool _disposed = false;

  int? _limit;
  int _count = 0;
  Set<String> _locked = const {};

  /// How many notes may be kept editable, or null for no limit at all.
  int? get limit => _limit;

  /// The notes that count against [limit]: this account's own, archive
  /// included. Zero while there is no limit, when nobody is counting.
  int get count => _count;

  /// Whether a new note may be started.
  bool get canCreate {
    final limit = _limit;
    return limit == null || _count < limit;
  }

  /// Whether the limit holds [note] read-only.
  bool isLocked(Note note) => _locked.contains(note.id);

  /// Every note the limit holds read-only.
  Set<String> get lockedIds => _locked;

  void _onAccount() {
    final billing = _account.billing;
    if (!identical(billing, _billing)) {
      _billing?.removeListener(_onBilling);
      _billing = billing?..addListener(_onBilling);
    }
    final state = _account.state;
    if (state != _state) {
      _state = state;
      // The only time this device asks: there is no account to ask instead.
      if (state == AccountState.signedOut) unawaited(_terms.refreshIfStale());
    }
    _update();
  }

  void _onBilling() {
    final now = _billing?.entitlements;
    // A trial or a limit in the account's answer means plans are enforced,
    // which is the moment this device's own clock has to have started by.
    if (now != null && (now.noteLimit != null || now.trialEndsAt != null)) {
      _terms.noteEnforced();
    }
    _update();
  }

  int? _limitNow() => switch (_account.state) {
    AccountState.restoring => null,
    // Pro bought before signing in unlocks exactly this, because it is the
    // only part of Pro that works with no account behind it.
    AccountState.signedOut =>
      _terms.limitApplies && !(_billing?.proOnThisDevice ?? false)
          ? _terms.freeNoteLimit
          : null,
    _ => _billing?.entitlements?.noteLimit,
  };

  /// This account's own: personal, or in a space it owns. Signed out there
  /// is no telling who owns a shared space, and those notes are read-only
  /// for that reason already, so only personal ones count.
  bool _counts(Note note) =>
      note.spaceId == null ||
      (_account.sharing?.spaceOf(note)?.isOwner ?? false);

  void _update() {
    if (_disposed) return;
    final limit = _limitNow();
    var count = 0;
    var locked = const <String>{};
    if (limit != null) {
      final own = _notes.allNotes.where(_counts).toList(growable: false);
      count = own.length;
      if (count > limit) {
        final pinned = _notes.pinnedNoteIds;
        final active = _notes.notes.where(_counts);
        final editable = {
          for (final note in [
            ...active.where((note) => pinned.contains(note.id)),
            ...active.where((note) => !pinned.contains(note.id)),
          ].take(limit))
            note.id,
        };
        locked = {
          for (final note in own)
            if (!editable.contains(note.id)) note.id,
        };
      }
    }
    _armDeviceTrialEnd();
    if (limit == _limit && count == _count && setEquals(locked, _locked)) {
      return;
    }
    _limit = limit;
    _count = count;
    _locked = Set.unmodifiable(locked);
    notifyListeners();
  }

  /// Signed out, the limit starts when this device's fortnight ends, and
  /// nothing else happens at that moment to say so.
  void _armDeviceTrialEnd() {
    final ends = _account.state == AccountState.signedOut && _terms.enforced
        ? _terms.deviceTrialEndsAt
        : null;
    final pending = ends != null && ends.isAfter(_now()) ? ends : null;
    if (pending == _deviceTrialEndArmedFor) return;
    _deviceTrialEnd?.cancel();
    _deviceTrialEnd = null;
    _deviceTrialEndArmedFor = pending;
    if (pending == null) return;
    _deviceTrialEnd = Timer(pending.difference(_now()), () {
      _deviceTrialEnd = null;
      _deviceTrialEndArmedFor = null;
      _update();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _deviceTrialEnd?.cancel();
    _notes.removeListener(_update);
    _account.removeListener(_onAccount);
    _terms.removeListener(_update);
    _billing?.removeListener(_onBilling);
    super.dispose();
  }
}
