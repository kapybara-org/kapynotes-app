import 'dart:typed_data';

/// What an edit did to a note's lines: from [line] on, [removed] lines gave
/// way to [inserted] new ones. Every line before [line] is untouched, and
/// every line after the removed ones is the same line, moved by
/// `inserted - removed`.
typedef LineEdit = ({int line, int removed, int inserted});

/// The note as the editor holds it: its lines, and an index that turns an
/// offset into a line and back in O(log n).
///
/// An edit replaces a range of the text and reports the lines it took out and
/// put in, so whatever the editor keeps per line is redone for those lines
/// alone. The text as one string is built only when something asks for it,
/// and kept until the next edit.
class NoteLines {
  NoteLines(String text) : _lines = text.split('\n') {
    _index();
  }

  final List<String> _lines;

  /// A Fenwick tree over every line's length plus its newline, so a line's
  /// start is a prefix sum.
  Int32List _tree = Int32List(1);

  String? _text;

  /// How many lines the note has: one more than it has newlines.
  int get length => _lines.length;

  String operator [](int line) => _lines[line];

  String get text => _text ??= _lines.join('\n');

  int get textLength => _prefix(_lines.length) - 1;

  /// Where [line] starts in [text].
  int startOf(int line) => _prefix(line);

  /// Where [line] ends in [text]: before its newline, or at the note's end.
  int endOf(int line) => _prefix(line) + _lines[line].length;

  /// The line [offset] falls in. An offset at a line's end, before its
  /// newline, belongs to that line, which is where a caret there sits.
  int lineAt(int offset) {
    var line = 0;
    var rest = offset;
    for (var step = 1 << (_lines.length.bitLength - 1); step > 0; step >>= 1) {
      final next = line + step;
      if (next <= _lines.length && _tree[next] <= rest) {
        line = next;
        rest -= _tree[next];
      }
    }
    return line;
  }

  /// Replaces `[start, end)` of [text] with [replacement].
  LineEdit replace(int start, int end, String replacement) {
    final first = lineAt(start);
    if (start == end && replacement.isEmpty) {
      return (line: first, removed: 0, inserted: 0);
    }
    final last = lineAt(end);
    final head = _lines[first].substring(0, start - startOf(first));
    final tail = _lines[last].substring(end - startOf(last));
    final inserted = '$head$replacement$tail'.split('\n');
    final removed = last - first + 1;
    _text = null;
    if (inserted.length == removed) {
      for (var i = 0; i < removed; i++) {
        final change = inserted[i].length - _lines[first + i].length;
        _lines[first + i] = inserted[i];
        for (
          var node = first + i + 1;
          node < _tree.length;
          node += node & -node
        ) {
          _tree[node] += change;
        }
      }
    } else {
      _lines.replaceRange(first, last + 1, inserted);
      _index();
    }
    return (line: first, removed: removed, inserted: inserted.length);
  }

  int _prefix(int lines) {
    var sum = 0;
    for (var node = lines; node > 0; node -= node & -node) {
      sum += _tree[node];
    }
    return sum;
  }

  void _index() {
    final tree = Int32List(_lines.length + 1);
    for (var i = 1; i < tree.length; i++) {
      tree[i] += _lines[i - 1].length + 1;
      final parent = i + (i & -i);
      if (parent < tree.length) tree[parent] += tree[i];
    }
    _tree = tree;
  }
}
