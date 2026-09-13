import 'package:flutter/foundation.dart';

import '../crdt/crdt.dart';

/// Somebody else who has a shared note open right now.
@immutable
class Collaborator {
  const Collaborator({
    required this.userId,
    required this.name,
    required this.fullName,
    this.image,
    this.typing = false,
  });

  final String userId;

  /// What to call them in a sentence, unique within the note's space.
  final String name;

  /// What to call them in a list or a tooltip.
  final String fullName;
  final String? image;

  /// Whether they have typed in the last moment, as against only being there.
  final bool typing;

  @override
  bool operator ==(Object other) =>
      other is Collaborator &&
      other.userId == userId &&
      other.name == name &&
      other.fullName == fullName &&
      other.image == image &&
      other.typing == typing;

  @override
  int get hashCode => Object.hash(userId, name, fullName, image, typing);
}

/// Where one of their devices has its caret, as offsets into
/// [RemoteCarets.text].
@immutable
class RemoteCaret {
  const RemoteCaret({
    required this.id,
    required this.userId,
    required this.name,
    required this.base,
    required this.extent,
    required this.typing,
    required this.movedAt,
    this.leaving = false,
  });

  /// One per device, so a person with the note open twice shows twice.
  final String id;
  final String userId;
  final String name;
  final int base;
  final int extent;
  final bool typing;

  /// When the caret last moved or typed, which is how long its name flag
  /// stays up.
  final DateTime movedAt;

  /// Their device has said it is leaving; the caret lingers a moment first.
  final bool leaving;
}

/// Every caret in one note, resolved against the text they point into.
///
/// The text travels with the offsets because the editor may already be a
/// keystroke past it — its own, not yet absorbed into the document — and has
/// to map the offsets across that difference before it draws them.
@immutable
class RemoteCarets {
  const RemoteCarets({required this.text, required this.carets});

  static const empty = RemoteCarets(text: '', carets: []);

  final String text;
  final List<RemoteCaret> carets;

  bool get isEmpty => carets.isEmpty;
}

/// What an editor reads other people's carets from.
abstract interface class RemoteCaretSource {
  /// Fires whenever a caret moves, arrives or goes. Deliberately separate
  /// from the roster: a caret moves a dozen times a second, and nothing but
  /// the layer that draws it should rebuild for that.
  Listenable get caretChanges;

  RemoteCarets caretsFor(String noteId);
}

/// A selection as the characters it sits after, so it survives the edits that
/// land between being sent and being drawn.
@immutable
class AnchoredSelection {
  const AnchoredSelection(this.base, this.extent);

  final Anchor base;
  final Anchor extent;

  /// `[base, extent]`, each `[replica, counter]` or null for the start.
  List<Object?> toJson() => [_anchorJson(base), _anchorJson(extent)];

  /// Null for anything malformed, which a newer or corrupt client may send.
  static AnchoredSelection? fromJson(Object? raw) {
    if (raw is! List || raw.length != 2) return null;
    final base = _anchorFrom(raw[0]);
    final extent = _anchorFrom(raw[1]);
    if (base == null || extent == null) return null;
    return AnchoredSelection(base, extent);
  }

  @override
  bool operator ==(Object other) =>
      other is AnchoredSelection &&
      other.base == base &&
      other.extent == extent;

  @override
  int get hashCode => Object.hash(base, extent);

  static Object? _anchorJson(Anchor anchor) {
    final id = anchor.id;
    return id == null ? null : [id.replica, id.counter];
  }

  static Anchor? _anchorFrom(Object? raw) {
    if (raw == null) return Anchor.start;
    if (raw is! List || raw.length != 2) return null;
    final replica = raw[0];
    final counter = raw[1];
    if (replica is! String || replica.isEmpty || replica.length > 64) {
      return null;
    }
    if (counter is! num || counter < 0) return null;
    return Anchor(NodeId(replica, counter.toInt()));
  }
}
