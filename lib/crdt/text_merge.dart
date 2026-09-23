import 'dart:typed_data';

/// One stretch where one text differs from another: `[start, end)` of the
/// old text became [insert].
class TextHunk {
  const TextHunk(this.start, this.end, this.insert);

  final int start;
  final int end;
  final String insert;

  @override
  bool operator ==(Object other) =>
      other is TextHunk &&
      other.start == start &&
      other.end == end &&
      other.insert == insert;

  @override
  int get hashCode => Object.hash(start, end, insert);

  @override
  String toString() => 'TextHunk($start, $end, "$insert")';
}

/// Every stretch where [b] differs from [a], in order, as few characters as
/// possible apart.
///
/// [diffTexts](text_diff.dart) is one stretch, which is exactly a keystroke.
/// This is for a change that may be several — another device typing above
/// and below the caret — where one stretch spanning both would claim that
/// everything between them was rewritten, and put the caret, or a keystroke
/// made meanwhile, a line off.
///
/// Myers' algorithm on what is left once the common ends are trimmed. Past
/// [maxCost] edits it stops looking and reports that middle as one stretch,
/// which is never wrong, only coarse; a change that large is a paste or a
/// rewrite, not two people typing.
List<TextHunk> diffHunks(String a, String b, {int maxCost = 1000}) {
  final n = a.length;
  final m = b.length;
  var prefix = 0;
  while (prefix < n && prefix < m && a.codeUnitAt(prefix) == b.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < n - prefix &&
      suffix < m - prefix &&
      a.codeUnitAt(n - 1 - suffix) == b.codeUnitAt(m - 1 - suffix)) {
    suffix++;
  }
  final aEnd = n - suffix;
  final bEnd = m - suffix;
  if (prefix == aEnd && prefix == bEnd) return const [];
  if (prefix == aEnd || prefix == bEnd) {
    return [TextHunk(prefix, aEnd, b.substring(prefix, bEnd))];
  }
  final hunks = _myers(a, prefix, aEnd, b, prefix, bEnd, maxCost);
  return hunks ?? [TextHunk(prefix, aEnd, b.substring(prefix, bEnd))];
}

/// Myers' greedy shortest edit script between `a[aStart, aEnd)` and
/// `b[bStart, bEnd)`, as hunks in [a]'s offsets; null past [maxCost].
List<TextHunk>? _myers(
  String a,
  int aStart,
  int aEnd,
  String b,
  int bStart,
  int bEnd,
  int maxCost,
) {
  final n = aEnd - aStart;
  final m = bEnd - bStart;
  final maxD = n + m < maxCost ? n + m : maxCost;
  final offset = maxD + 1;
  final v = Int32List(2 * maxD + 3);
  // The furthest x on each diagonal before each round, kept only for the
  // diagonals that round can read: what the walk back needs.
  final trace = <Int32List>[];
  var found = -1;
  for (var d = 0; d <= maxD && found < 0; d++) {
    final low = offset - d - 1;
    trace.add(Int32List.fromList(v.sublist(low, offset + d + 2)));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
        x = v[offset + k + 1];
      } else {
        x = v[offset + k - 1] + 1;
      }
      var y = x - k;
      while (x < n &&
          y < m &&
          a.codeUnitAt(aStart + x) == b.codeUnitAt(bStart + y)) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) {
        found = d;
        break;
      }
    }
  }
  if (found < 0) return null;

  // Walk back from the end, one edit per round, collecting the stretches.
  final edits = <({int x, int y, bool delete})>[];
  var x = n;
  var y = m;
  for (var d = found; d > 0; d--) {
    final saved = trace[d];
    int at(int k) => saved[k + d + 1];
    final k = x - y;
    final int previousK;
    if (k == -d || (k != d && at(k - 1) < at(k + 1))) {
      previousK = k + 1;
    } else {
      previousK = k - 1;
    }
    final previousX = at(previousK);
    final previousY = previousX - previousK;
    while (x > previousX && y > previousY) {
      x--;
      y--;
    }
    // The single step off the diagonal: down is an insert of b[y - 1],
    // right a delete of a[x - 1].
    if (x == previousX) {
      edits.add((x: x, y: previousY, delete: false));
    } else {
      edits.add((x: previousX, y: y, delete: true));
    }
    x = previousX;
    y = previousY;
  }

  final hunks = <TextHunk>[];
  int? start;
  var end = 0;
  final inserted = StringBuffer();
  void close() {
    if (start == null) return;
    hunks.add(TextHunk(aStart + start!, aStart + end, inserted.toString()));
    start = null;
    inserted.clear();
  }

  for (final edit in edits.reversed) {
    final editStart = edit.x;
    if (start != null && editStart != end) close();
    start ??= editStart;
    if (edit.delete) {
      end = edit.x + 1;
    } else {
      end = edit.x;
      inserted.writeCharCode(b.codeUnitAt(bStart + edit.y));
    }
  }
  close();
  return hunks;
}

/// Three texts brought together: what both sides started from, and what each
/// made of it.
class TextMerge {
  TextMerge._(
    this.text,
    this._localBefore,
    this._localAfter,
    this._remoteBefore,
    this._remoteAfter,
  );

  /// Both sides' changes, applied to the text they started from.
  final String text;

  final Int32List _localBefore;
  final Int32List _localAfter;
  final Int32List _remoteBefore;
  final Int32List _remoteAfter;

  /// Where a caret in the local text lands in [text]: just after the local
  /// character before it. So it stays against the words it was typed after,
  /// ahead of anything the other side put in the same place.
  int mapLocal(int offset) => _after(_localAfter, offset);

  /// Where a stretch of the local text that starts at [offset] starts in
  /// [text]: at the local character there. For styles and pictures.
  int mapLocalStart(int offset) => _before(_localBefore, offset);

  /// Where a stretch of the remote text that starts at [offset] starts in
  /// [text].
  int mapRemoteStart(int offset) => _before(_remoteBefore, offset);

  /// Where a stretch of the remote text that ends at [offset] ends in [text]:
  /// just after the remote character before it.
  int mapRemoteEnd(int offset) => _after(_remoteAfter, offset);

  int _before(Int32List before, int offset) {
    if (offset <= 0) return before.isEmpty ? 0 : before[0];
    return offset >= before.length ? text.length : before[offset];
  }

  static int _after(Int32List after, int offset) {
    final clamped = offset > after.length ? after.length : offset;
    return clamped <= 0 ? 0 : after[clamped - 1];
  }
}

/// Merges two edits of one text the way the note's CRDT would.
///
/// A character goes if either side deleted it. Everything either side
/// inserted stays, even inside a stretch the other deleted. Where both
/// inserted at the same place the local words come first, then the remote
/// ones, so a word being typed is never split by one arriving.
///
/// For the editor, whose text can fall behind the store's while a keyboard
/// holds a composition, or for one frame after another device's words land:
/// a keystroke made then is carried onto the store's text instead of
/// replacing it, which is what deleted other people's words.
TextMerge mergeTexts({
  required String base,
  required String local,
  required String remote,
}) {
  final localHunks = diffHunks(base, local);
  final remoteHunks = diffHunks(base, remote);
  final out = StringBuffer();
  var written = 0;
  final localBefore = Int32List(local.length);
  final localAfter = Int32List(local.length);
  final remoteBefore = Int32List(remote.length);
  final remoteAfter = Int32List(remote.length);
  var localAt = 0;
  var remoteAt = 0;
  var li = 0;
  var ri = 0;
  var localDeletesTo = 0;
  var remoteDeletesTo = 0;

  for (var i = 0; i <= base.length; i++) {
    if (li < localHunks.length && localHunks[li].start == i) {
      final hunk = localHunks[li++];
      for (var c = 0; c < hunk.insert.length; c++) {
        localBefore[localAt] = written;
        out.writeCharCode(hunk.insert.codeUnitAt(c));
        written++;
        localAfter[localAt++] = written;
      }
      localDeletesTo = hunk.end;
    }
    if (ri < remoteHunks.length && remoteHunks[ri].start == i) {
      final hunk = remoteHunks[ri++];
      for (var c = 0; c < hunk.insert.length; c++) {
        remoteBefore[remoteAt] = written;
        out.writeCharCode(hunk.insert.codeUnitAt(c));
        written++;
        remoteAfter[remoteAt++] = written;
      }
      remoteDeletesTo = hunk.end;
    }
    if (i == base.length) break;
    final keptLocally = i >= localDeletesTo;
    final keptRemotely = i >= remoteDeletesTo;
    if (keptLocally) localBefore[localAt] = written;
    if (keptRemotely) remoteBefore[remoteAt] = written;
    if (keptLocally && keptRemotely) {
      out.writeCharCode(base.codeUnitAt(i));
      written++;
    }
    if (keptLocally) localAfter[localAt++] = written;
    if (keptRemotely) remoteAfter[remoteAt++] = written;
  }
  return TextMerge._(
    out.toString(),
    localBefore,
    localAfter,
    remoteBefore,
    remoteAfter,
  );
}
