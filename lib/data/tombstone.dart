/// A deleted note, kept as a record of the deletion.
///
/// Without this, sync silently resurrects notes: device A deletes a note,
/// device B still holds its copy and pushes it, and the note comes back. The
/// deletion has to be a fact that travels, not the absence of one.
///
/// Only the id, the space and the time survive — the body and formats are
/// dropped at delete time, so a tombstone carries nothing worth encrypting.
class Tombstone {
  final String id;
  final DateTime deletedAt;

  /// The [deletedAt] the server has confirmed, or null if the deletion has
  /// never been pushed.
  final DateTime? syncedAt;

  /// Which space the note was deleted from. Null is the personal space.
  ///
  /// A tombstone is scoped to a space because a note that moved leaves one
  /// behind where it was: per-space cursors mean a device pulling the old
  /// space would otherwise never see it go.
  final String? spaceId;

  const Tombstone({
    required this.id,
    required this.deletedAt,
    this.syncedAt,
    this.spaceId,
  });

  /// How long a confirmed tombstone is kept before being dropped.
  ///
  /// It only has to outlive the longest plausible gap between a device syncing
  /// and any other device syncing. A month covers a phone left in a drawer
  /// over a holiday; beyond that, resurrection is the lesser evil against
  /// growing this list forever.
  static const Duration retention = Duration(days: 30);

  /// See [Note.isDirty] on why this compares epoch milliseconds.
  bool get isDirty =>
      syncedAt == null ||
      syncedAt!.millisecondsSinceEpoch != deletedAt.millisecondsSinceEpoch;

  Tombstone markSynced(DateTime at) =>
      Tombstone(id: id, deletedAt: deletedAt, syncedAt: at, spaceId: spaceId);

  /// A tombstone is safe to forget once the server has it and it has aged out.
  /// An unsynced one is kept regardless of age — dropping it would resurrect
  /// the note on the next pull.
  bool isExpired(DateTime now) =>
      !isDirty && now.difference(deletedAt) > retention;

  Map<String, Object?> toJson() => {
    'id': id,
    'deletedAt': deletedAt.millisecondsSinceEpoch,
    if (syncedAt != null) 'syncedAt': syncedAt!.millisecondsSinceEpoch,
    if (spaceId != null) 'spaceId': spaceId,
  };

  static Tombstone? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final deletedAt = raw['deletedAt'];
    if (id is! String || deletedAt is! int) return null;
    final syncedAt = raw['syncedAt'];
    final spaceId = raw['spaceId'];
    return Tombstone(
      id: id,
      deletedAt: DateTime.fromMillisecondsSinceEpoch(deletedAt),
      syncedAt: syncedAt is int
          ? DateTime.fromMillisecondsSinceEpoch(syncedAt)
          : null,
      spaceId: spaceId is String && spaceId.isNotEmpty ? spaceId : null,
    );
  }
}
