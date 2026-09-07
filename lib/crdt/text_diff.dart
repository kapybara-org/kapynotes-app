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
TextEdit diffTexts(String oldText, String newText) {
  final oldLength = oldText.length;
  final newLength = newText.length;
  final shorter = oldLength < newLength ? oldLength : newLength;

  var prefix = 0;
  while (prefix < shorter &&
      oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
    prefix++;
  }

  final suffixLimit = shorter - prefix;
  var suffix = 0;
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
