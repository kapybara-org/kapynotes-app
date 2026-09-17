/// One held-modifier navigation session for the desktop note switch shortcut.
///
/// A switch has two phases. [advance] walks a frozen snapshot while the
/// shortcut modifier is held, then [commit] returns the final preview. The
/// caller owns MRU order so the sidebar and the shortcut have one source of
/// truth rather than two lists that can disagree.
class NoteSwitcher {
  List<String>? _session;
  int _sessionIndex = 0;

  bool get isActive => _session != null;

  String? get previewId {
    final session = _session;
    if (session == null || session.isEmpty) return null;
    return session[_sessionIndex];
  }

  /// Ends an unfinished preview when another interaction takes over.
  void cancel() => _clearSession();

  /// Moves through [eligibleIds] in the order the sidebar is currently using.
  ///
  /// That order is frozen for the held-modifier session so the preview does
  /// not jump as the selected editor changes. The caller promotes the final
  /// note only after [commit], which is what makes every new forward switch
  /// start on the row directly below the active note.
  String? advance({
    required String? currentId,
    required Iterable<String> eligibleIds,
    required int delta,
  }) {
    if (delta == 0) return previewId;
    final eligible = _unique(eligibleIds);
    if (eligible.length < 2) {
      _clearSession();
      return null;
    }

    if (_session == null) {
      _session = eligible;
      final current = currentId == null ? -1 : eligible.indexOf(currentId);
      _sessionIndex = current >= 0 ? current : (delta > 0 ? -1 : 0);
    } else {
      _reconcileSession(eligible);
      if (_session == null) return null;
    }

    final session = _session!;
    _sessionIndex = (_sessionIndex + delta) % session.length;
    return session[_sessionIndex];
  }

  /// Finishes the current preview and returns the note that became active.
  String? commit() {
    final selected = previewId;
    _clearSession();
    return selected;
  }

  /// Drops unavailable notes from an active snapshot.
  void retain(Iterable<String> noteIds) {
    final available = noteIds.toSet();
    final session = _session;
    if (session != null) {
      _reconcileSession(session.where(available.contains).toList());
    }
  }

  void _reconcileSession(List<String> eligible) {
    final session = _session;
    if (session == null) return;
    final selected = previewId;
    final allowed = eligible.toSet();
    final alreadyInSession = session.toSet();
    final reconciled = <String>[
      for (final id in session)
        if (allowed.contains(id)) id,
      for (final id in eligible)
        if (!alreadyInSession.contains(id)) id,
    ];
    if (reconciled.length < 2) {
      _clearSession();
      return;
    }
    _session = reconciled;
    final selectedIndex = selected == null ? -1 : reconciled.indexOf(selected);
    _sessionIndex = selectedIndex >= 0 ? selectedIndex : 0;
  }

  void _clearSession() {
    _session = null;
    _sessionIndex = 0;
  }

  static List<String> _unique(Iterable<String> ids) {
    final seen = <String>{};
    return [
      for (final id in ids)
        if (seen.add(id)) id,
    ];
  }
}
