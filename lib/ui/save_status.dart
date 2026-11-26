import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../data/local_store.dart' show StoreWrite;
import '../sync/sync_service.dart' show SyncStatus;

/// What the bar says about saving: an icon, a word or two, and what hovering
/// it adds.
typedef SaveNotice = ({KapyIconData icon, String label, String? tooltip});

/// Where the person's own writing is: nothing to say, being saved, just
/// saved, fading out, or not saved because the disk refused it.
enum SavePhase { rest, saving, saved, fading, failed }

/// Says "Saving…" while the person writes and "Saved" once it is on disk,
/// for [linger], then fades over [fade] and says nothing.
///
/// The store writes to disk 250 ms after the last change, so it goes from
/// unsaved to saved between words. "Saving…" holds until no edit has come
/// for [settle] and every edit is written, so steady typing reads as one
/// save rather than a label flipping between words. A write nobody typed,
/// such as a note arriving from another device, says nothing, and a failed
/// write says so until a retry lands.
class SaveStatus extends ChangeNotifier {
  SaveStatus(
    this._writes, {
    this.settle = const Duration(seconds: 1),
    this.linger = const Duration(seconds: 2),
    this.fade = const Duration(milliseconds: 300),
  }) {
    _writes.addListener(_onWrites);
    _onWrites();
  }

  final ValueListenable<StoreWrite> _writes;
  final Duration settle;
  final Duration linger;
  final Duration fade;

  SavePhase _phase = SavePhase.rest;
  Timer? _timer;
  bool _settling = false;
  bool _failed = false;

  SavePhase get phase => _failed ? SavePhase.failed : _phase;

  /// The person changed something: "Saving…" until it settles.
  void edited() {
    _settling = true;
    _after(settle, () {
      _settling = false;
      _onWrites();
    });
    _go(SavePhase.saving);
  }

  void _onWrites() {
    final write = _writes.value;
    if (write == StoreWrite.failed) {
      if (_failed) return;
      _failed = true;
      _settling = false;
      _timer?.cancel();
      // The retry that lands says Saved.
      _phase = SavePhase.saving;
      notifyListeners();
      return;
    }
    if (_failed) {
      _failed = false;
      notifyListeners();
    }
    if (_settling ||
        write != StoreWrite.written ||
        _phase != SavePhase.saving) {
      return;
    }
    _go(SavePhase.saved);
    _after(linger, () {
      _go(SavePhase.fading);
      _after(fade, () => _go(SavePhase.rest));
    });
  }

  void _after(Duration wait, VoidCallback then) {
    _timer?.cancel();
    _timer = Timer(wait, then);
  }

  void _go(SavePhase phase) {
    if (phase == _phase) return;
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _writes.removeListener(_onWrites);
    super.dispose();
  }
}

/// What keeps the open note from reaching the person's other devices, or
/// null while nothing does. Every keystroke is saved on this device first,
/// so each says the note is safe here and what it waits for.
SaveNotice? syncProblem(
  SyncStatus? status, {
  bool paused = false,
  bool signInAgain = false,
}) {
  SaveNotice notSyncing(String label, String waits) => (
    icon: KapyIcons.cloudOffRounded,
    label: label,
    tooltip: 'Saved on this device. $waits',
  );
  if (signInAgain) {
    return notSyncing('Signed out', 'Sign in again to keep syncing.');
  }
  return switch (status) {
    SyncStatus.offline => notSyncing(
      'Offline',
      'It syncs once you are back online.',
    ),
    SyncStatus.keysChanged => notSyncing(
      'Not syncing',
      'It syncs once you enter your new passphrase.',
    ),
    SyncStatus.locked => notSyncing(
      'Not syncing',
      'It syncs once you unlock your notes in Account & sync.',
    ),
    SyncStatus.outdated => notSyncing(
      'Not syncing',
      'It syncs once you update Kapy Notes.',
    ),
    SyncStatus.failed => notSyncing(
      'Sync failed',
      'Account & sync says what went wrong.',
    ),
    _ when paused => notSyncing(
      'Sync paused',
      'Upgrade to Pro to sync it again.',
    ),
    _ => null,
  };
}

/// The open note's save status and the problem in its way, as the bar or a
/// narrow page's date line shows it.
typedef SaveState = ({SaveStatus status, SaveNotice? problem});

/// "Saving…", "Saved" fading away, or what is wrong for as long as it is:
/// in the bar with its icon, or with [icon] false as words alone on the
/// note's date line. Says nothing at rest.
class SaveStatusLabel extends StatelessWidget {
  const SaveStatusLabel(
    this.state, {
    super.key,
    required this.style,
    this.icon = true,
  });

  final SaveState state;
  final TextStyle style;
  final bool icon;

  static const SaveNotice _saving = (
    icon: KapyIcons.cloudRounded,
    label: 'Saving…',
    tooltip: null,
  );
  static const SaveNotice _saved = (
    icon: KapyIcons.cloudRounded,
    label: 'Saved',
    tooltip: null,
  );
  static const SaveNotice _notSaved = (
    icon: KapyIcons.cloudOffRounded,
    label: "Couldn't save",
    tooltip: "Couldn't save on this device. It tries again in a few seconds.",
  );

  /// What [state] says now, or null at rest.
  static SaveNotice? noticeOf(SaveState state) => switch (state.status.phase) {
    SavePhase.failed => _notSaved,
    _ when state.problem != null => state.problem,
    SavePhase.rest => null,
    SavePhase.saving => _saving,
    SavePhase.saved || SavePhase.fading => _saved,
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state.status,
    builder: (context, _) {
      final notice = noticeOf(state);
      if (notice == null) return const SizedBox.shrink();
      final fading =
          state.problem == null && state.status.phase == SavePhase.fading;
      Widget row = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon) ...[
            KapyIcon(notice.icon, size: 16, color: style.color),
            const SizedBox(width: 4),
          ],
          Text(notice.label, maxLines: 1, style: style),
        ],
      );
      if (notice.tooltip case final tooltip?) {
        row = Tooltip(message: tooltip, child: row);
      }
      return AnimatedOpacity(
        opacity: fading ? 0 : 1,
        duration: fading ? state.status.fade : Duration.zero,
        child: fading
            ? ExcludeSemantics(child: row)
            : Semantics(container: true, liveRegion: true, child: row),
      );
    },
  );
}
