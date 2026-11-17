/// The one contiguous edit that turns [oldText] into [newText].
///
/// `[start, oldEnd)` of the old text was replaced by `[start, newEnd)` of the
/// new one. Either side may be empty: a pure insert has `oldEnd == start`, a
/// pure delete has `newEnd == start`, and no change at all reports the whole
/// document as unchanged with every field equal to `oldText.length`.
typedef TextEdit = ({int start, int oldEnd, int newEnd});

/// Finds the edit by matching a common prefix and a common suffix.
///
/// This is deliberately the same shape of diff the editor already uses for
/// rebasing styles (`insertedTextForChange`), because the CRDT is fed the
/// controller's text after each keystroke and a keystroke is exactly one
/// contiguous replacement. Anything fancier — a real LCS diff — would only
/// matter for a paste that happens to share characters with what it replaced,
/// and would cost O(n·m) on every keystroke to get there.
///
/// The suffix scan is capped so the two matches never overlap; without that
/// cap, replacing "aa" with "a" would claim both a prefix and a suffix of
/// length 1 and report a negative edit.
///
/// [near] is where the editor saw the change happen. Text alone cannot say
/// which of two lines that start alike went — deleting "Buy milk" from
/// between "Buy oats" and "Buy eggs" reads just as well as deleting the end
/// of one and the start of the next — so when [near] fits the two texts the
/// match is taken only inside it. One that does not fit is ignored.
TextEdit diffTexts(String oldText, String newText, {TextEdit? near}) {
  final oldLength = oldText.length;
  final newLength = newText.length;
  final shorter = oldLength < newLength ? oldLength : newLength;
  final fits =
      near != null &&
      near.start >= 0 &&
      near.start <= near.oldEnd &&
      near.start <= near.newEnd &&
      near.oldEnd <= oldLength &&
      oldLength - near.oldEnd == newLength - near.newEnd &&
      oldText.startsWith(newText.substring(0, near.start)) &&
      oldText.endsWith(newText.substring(near.newEnd));

  var prefix = fits ? near.start : 0;
  final tail = fits ? oldLength - near.oldEnd : 0;
  while (prefix < shorter - tail &&
      oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
    prefix++;
  }

  final suffixLimit = shorter - prefix;
  var suffix = tail;
  while (suffix < suffixLimit &&
      oldText.codeUnitAt(oldLength - suffix - 1) ==
          newText.codeUnitAt(newLength - suffix - 1)) {
    suffix++;
  }

  return (
    start: prefix,
    oldEnd: oldLength - suffix,
    newEnd: newLength - suffix,
  );
}

/// [first] then [then] as one edit: the stretch either touched, from the
/// text before [first] to the text after [then].
TextEdit composeEdits(TextEdit first, TextEdit then) {
  final end = first.newEnd > then.oldEnd ? first.newEnd : then.oldEnd;
  return (
    start: first.start < then.start ? first.start : then.start,
    oldEnd: end - first.newEnd + first.oldEnd,
    newEnd: end - then.oldEnd + then.newEnd,
  );
}

/// Where [offset] in the old text of [edit] lands in the new text.
///
/// Before the edit it stays put; after it, it moves by the edit's change in
/// length; inside the replaced run it keeps its distance from the start,
/// clamped to the replacement. The same rule the editor applies to its own
/// caret when somebody else's words land around it.
int mapOffsetAcross(TextEdit edit, int offset) {
  if (offset <= edit.start) return offset < 0 ? 0 : offset;
  if (offset >= edit.oldEnd) return offset + edit.newEnd - edit.oldEnd;
  final into = offset - edit.start;
  final span = edit.newEnd - edit.start;
  return edit.start + (into < span ? into : span);
}
