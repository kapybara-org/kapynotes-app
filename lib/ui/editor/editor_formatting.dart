import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart'
    show Color, FontStyle, FontWeight, TextStyle;

import '../../data/note_format.dart';

const bulletPrefix = '• ';
const uncheckedPrefix = '☐ ';
const checkedPrefix = '☑ ';

enum NoteLineStyle { bullet, checklist }

/// Semantic styles that apply to whole logical lines.
///
/// Plain [text] is represented by the absence of a paragraph format, which
/// keeps existing notes and their persisted JSON backwards-compatible.
enum NoteParagraphStyle { heading, text, subtitle }

extension NoteParagraphStyleDetails on NoteParagraphStyle {
  String get label => switch (this) {
    NoteParagraphStyle.heading => 'Heading',
    NoteParagraphStyle.text => 'Text',
    NoteParagraphStyle.subtitle => 'Subtitle',
  };

  NoteFormat? get format => switch (this) {
    NoteParagraphStyle.heading => NoteFormat.heading,
    NoteParagraphStyle.text => null,
    NoteParagraphStyle.subtitle => NoteFormat.subtitle,
  };
}

/// Returns the style a direct click should apply next.
///
/// Mixed selections first become plain text, then each click walks the compact
/// writing hierarchy without opening a secondary surface.
NoteParagraphStyle nextParagraphStyle(NoteParagraphStyle? current) {
  return switch (current) {
    null => NoteParagraphStyle.text,
    NoteParagraphStyle.text => NoteParagraphStyle.heading,
    NoteParagraphStyle.heading => NoteParagraphStyle.subtitle,
    NoteParagraphStyle.subtitle => NoteParagraphStyle.text,
  };
}

TextStyle paragraphTextStyle(
  TextStyle base,
  NoteParagraphStyle paragraphStyle, {
  Color? primaryColor,
  Color? secondaryColor,
}) {
  final scale = switch (paragraphStyle) {
    NoteParagraphStyle.heading => 1.28,
    NoteParagraphStyle.text => 1.0,
    NoteParagraphStyle.subtitle => 0.92,
  };
  return base.copyWith(
    color: paragraphStyle == NoteParagraphStyle.subtitle
        ? secondaryColor ?? base.color
        : primaryColor ?? base.color,
    fontSize: base.fontSize == null ? null : base.fontSize! * scale,
    // Preserve the editor's fixed 29px row while changing visual size.
    height: base.height == null ? null : base.height! / scale,
    fontWeight: switch (paragraphStyle) {
      NoteParagraphStyle.heading => FontWeight.w700,
      NoteParagraphStyle.text => FontWeight.w400,
      NoteParagraphStyle.subtitle => FontWeight.w400,
    },
    fontStyle: paragraphStyle == NoteParagraphStyle.subtitle
        ? FontStyle.italic
        : FontStyle.normal,
  );
}

NoteParagraphStyle? paragraphStyleForSelection(
  String text,
  List<NoteFormatRange> formats,
  TextSelection selection,
) {
  if (!selection.isValid) return NoteParagraphStyle.text;
  NoteParagraphStyle? common;
  for (final line in _selectedLineRanges(text, selection)) {
    final style = _paragraphStyleForLine(formats, line);
    if (common == null) {
      common = style;
    } else if (common != style) {
      return null;
    }
  }
  return common ?? NoteParagraphStyle.text;
}

List<NoteFormatRange> applyParagraphStyle(
  List<NoteFormatRange> formats,
  String text,
  TextSelection selection,
  NoteParagraphStyle style,
) {
  if (!selection.isValid) return formats;
  final lines = _selectedLineRanges(text, selection);
  final updated = <NoteFormatRange>[];

  for (final format in formats) {
    if (!format.format.isParagraph) {
      updated.add(format);
      continue;
    }

    var fragments = <TextRange>[
      TextRange(start: format.start, end: format.end),
    ];
    for (final line in lines) {
      final next = <TextRange>[];
      for (final fragment in fragments) {
        if (fragment.end <= line.start || fragment.start >= line.end) {
          next.add(fragment);
          continue;
        }
        if (fragment.start < line.start) {
          next.add(TextRange(start: fragment.start, end: line.start));
        }
        if (fragment.end > line.end) {
          next.add(TextRange(start: line.end, end: fragment.end));
        }
      }
      fragments = next;
    }
    for (final fragment in fragments) {
      if (fragment.end > fragment.start) {
        updated.add(
          NoteFormatRange(
            start: fragment.start,
            end: fragment.end,
            format: format.format,
          ),
        );
      }
    }
  }

  final paragraphFormat = style.format;
  if (paragraphFormat != null) {
    for (final line in lines) {
      if (line.end > line.start) {
        updated.add(
          NoteFormatRange(
            start: line.start,
            end: line.end,
            format: paragraphFormat,
          ),
        );
      }
    }
  }
  return normalizeNoteFormats(updated, text.length);
}

String insertedTextForChange(String oldText, String newText) {
  if (oldText == newText) return '';
  var editStart = 0;
  final sharedStartLimit = oldText.length < newText.length
      ? oldText.length
      : newText.length;
  while (editStart < sharedStartLimit &&
      oldText.codeUnitAt(editStart) == newText.codeUnitAt(editStart)) {
    editStart++;
  }

  var sharedEnd = 0;
  final oldRemaining = oldText.length - editStart;
  final newRemaining = newText.length - editStart;
  final sharedEndLimit = oldRemaining < newRemaining
      ? oldRemaining
      : newRemaining;
  while (sharedEnd < sharedEndLimit &&
      oldText.codeUnitAt(oldText.length - sharedEnd - 1) ==
          newText.codeUnitAt(newText.length - sharedEnd - 1)) {
    sharedEnd++;
  }
  return newText.substring(editStart, newText.length - sharedEnd);
}

bool selectionHasLineStyle(TextEditingValue value, NoteLineStyle style) {
  if (!value.selection.isValid) return false;
  final starts = _selectedLineStarts(value.text, value.selection);
  return starts.every((start) {
    final prefix = _prefixAt(value.text, start).value;
    return switch (style) {
      NoteLineStyle.bullet => prefix == bulletPrefix,
      NoteLineStyle.checklist =>
        prefix == uncheckedPrefix || prefix == checkedPrefix,
    };
  });
}

bool selectionHasFormat(
  List<NoteFormatRange> formats,
  TextSelection selection,
  NoteFormat format,
) {
  if (!selection.isValid) return false;
  if (selection.isCollapsed) {
    final offset = selection.extentOffset;
    return formats.any(
      (range) =>
          range.format == format && range.start < offset && range.end >= offset,
    );
  }

  var coveredUntil = selection.start;
  for (final range in formats.where((range) => range.format == format)) {
    if (range.end <= coveredUntil) continue;
    if (range.start > coveredUntil) return false;
    coveredUntil = range.end;
    if (coveredUntil >= selection.end) return true;
  }
  return false;
}

List<NoteFormatRange> toggleNoteFormat(
  List<NoteFormatRange> formats,
  TextSelection selection,
  NoteFormat format,
  int textLength,
) {
  if (!selection.isValid || selection.isCollapsed) return formats;
  if (!selectionHasFormat(formats, selection, format)) {
    return normalizeNoteFormats([
      ...formats,
      NoteFormatRange(
        start: selection.start,
        end: selection.end,
        format: format,
      ),
    ], textLength);
  }

  final updated = <NoteFormatRange>[];
  for (final range in formats) {
    if (range.format != format ||
        range.end <= selection.start ||
        range.start >= selection.end) {
      updated.add(range);
      continue;
    }
    if (range.start < selection.start) {
      updated.add(
        NoteFormatRange(
          start: range.start,
          end: selection.start,
          format: format,
        ),
      );
    }
    if (range.end > selection.end) {
      updated.add(
        NoteFormatRange(start: selection.end, end: range.end, format: format),
      );
    }
  }
  return normalizeNoteFormats(updated, textLength);
}

/// Rebases style ranges across the one contiguous edit represented by two
/// successive controller values.
List<NoteFormatRange> rebaseNoteFormats({
  required String oldText,
  required String newText,
  required List<NoteFormatRange> formats,
  required Set<NoteFormat> insertedFormats,
}) {
  if (oldText == newText) return formats;

  var editStart = 0;
  final sharedStartLimit = oldText.length < newText.length
      ? oldText.length
      : newText.length;
  while (editStart < sharedStartLimit &&
      oldText.codeUnitAt(editStart) == newText.codeUnitAt(editStart)) {
    editStart++;
  }

  var sharedEnd = 0;
  final oldRemaining = oldText.length - editStart;
  final newRemaining = newText.length - editStart;
  final sharedEndLimit = oldRemaining < newRemaining
      ? oldRemaining
      : newRemaining;
  while (sharedEnd < sharedEndLimit &&
      oldText.codeUnitAt(oldText.length - sharedEnd - 1) ==
          newText.codeUnitAt(newText.length - sharedEnd - 1)) {
    sharedEnd++;
  }

  final oldEditEnd = oldText.length - sharedEnd;
  final newEditEnd = newText.length - sharedEnd;
  final insertedLength = newEditEnd - editStart;
  final delta = newText.length - oldText.length;
  final rebased = <NoteFormatRange>[];

  for (final range in formats) {
    final beforeEnd = range.end < editStart ? range.end : editStart;
    if (range.start < beforeEnd) {
      rebased.add(
        NoteFormatRange(
          start: range.start,
          end: beforeEnd,
          format: range.format,
        ),
      );
    }

    final afterStart = range.start > oldEditEnd ? range.start : oldEditEnd;
    if (range.end > afterStart) {
      rebased.add(
        NoteFormatRange(
          start: afterStart + delta,
          end: range.end + delta,
          format: range.format,
        ),
      );
    }
  }

  if (insertedLength > 0) {
    for (final format in insertedFormats) {
      rebased.add(
        NoteFormatRange(start: editStart, end: newEditEnd, format: format),
      );
    }
  }
  return normalizeNoteFormats(rebased, newText.length);
}

TextEditingValue toggleLineStyle(TextEditingValue value, NoteLineStyle style) {
  final text = value.text;
  final selection = value.selection.isValid
      ? value.selection
      : TextSelection.collapsed(offset: text.length);
  final lineStarts = _selectedLineStarts(text, selection);
  final prefixes = [for (final start in lineStarts) _prefixAt(text, start)];
  final allAlreadyStyled = prefixes.every(
    (prefix) => switch (style) {
      NoteLineStyle.bullet => prefix.value == bulletPrefix,
      NoteLineStyle.checklist =>
        prefix.value == uncheckedPrefix || prefix.value == checkedPrefix,
    },
  );

  final edits = <_TextEdit>[];
  for (var index = 0; index < lineStarts.length; index++) {
    final prefix = prefixes[index];
    final replacement = allAlreadyStyled
        ? ''
        : switch (style) {
            NoteLineStyle.bullet => bulletPrefix,
            NoteLineStyle.checklist => uncheckedPrefix,
          };
    if (prefix.value == replacement) continue;
    edits.add(
      _TextEdit(
        start: prefix.start,
        end: prefix.start + prefix.value.length,
        replacement: replacement,
      ),
    );
  }
  if (edits.isEmpty) return value;

  edits.sort((a, b) => a.start.compareTo(b.start));
  var updatedText = text;
  for (final edit in edits.reversed) {
    updatedText = updatedText.replaceRange(
      edit.start,
      edit.end,
      edit.replacement,
    );
  }
  return TextEditingValue(
    text: updatedText,
    selection: TextSelection(
      baseOffset: _mapOffset(selection.baseOffset, edits),
      extentOffset: _mapOffset(selection.extentOffset, edits),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    ),
  );
}

int checkboxLineStartAt(String text, int offset) {
  if (text.isEmpty) return -1;
  final clipped = offset.clamp(0, text.length);
  final lineStart = clipped == 0 ? 0 : text.lastIndexOf('\n', clipped - 1) + 1;
  final prefix = _prefixAt(text, lineStart);
  if (prefix.value != uncheckedPrefix && prefix.value != checkedPrefix) {
    return -1;
  }
  return offset <= prefix.start + 1 ? prefix.start : -1;
}

TextEditingValue toggleCheckboxAt(TextEditingValue value, int start) {
  if (start < 0 || start >= value.text.length) return value;
  final current = value.text[start];
  if (current != '☐' && current != '☑') return value;
  return value.copyWith(
    text: value.text.replaceRange(start, start + 1, current == '☐' ? '☑' : '☐'),
    selection: TextSelection.collapsed(offset: start + 2),
    composing: TextRange.empty,
  );
}

List<int> _selectedLineStarts(String text, TextSelection selection) {
  final first = selection.start.clamp(0, text.length);
  var last = selection.end.clamp(0, text.length);
  if (!selection.isCollapsed && last > first && text[last - 1] == '\n') {
    last--;
  }

  final firstStart = first == 0 ? 0 : text.lastIndexOf('\n', first - 1) + 1;
  final starts = <int>[firstStart];
  var cursor = firstStart;
  while (true) {
    final newline = text.indexOf('\n', cursor);
    if (newline < 0 || newline + 1 > last) break;
    cursor = newline + 1;
    starts.add(cursor);
  }
  return starts;
}

List<TextRange> _selectedLineRanges(String text, TextSelection selection) {
  return [
    for (final start in _selectedLineStarts(text, selection))
      TextRange(
        // Indentation and list markers stay structural. The semantic style is
        // applied to the paragraph content that follows them.
        start: switch (_prefixAt(text, start)) {
          final prefix => prefix.start + prefix.value.length,
        },
        end: switch (text.indexOf('\n', start)) {
          -1 => text.length,
          final newline => newline,
        },
      ),
  ];
}

NoteParagraphStyle _paragraphStyleForLine(
  List<NoteFormatRange> formats,
  TextRange line,
) {
  if (line.isCollapsed) return NoteParagraphStyle.text;
  for (final style in NoteParagraphStyle.values) {
    final format = style.format;
    if (format == null) continue;
    if (selectionHasFormat(
      formats,
      TextSelection(baseOffset: line.start, extentOffset: line.end),
      format,
    )) {
      return style;
    }
  }
  return NoteParagraphStyle.text;
}

({int start, String value}) _prefixAt(String text, int lineStart) {
  var prefixStart = lineStart;
  while (prefixStart < text.length &&
      (text[prefixStart] == ' ' || text[prefixStart] == '\t')) {
    prefixStart++;
  }
  for (final prefix in [bulletPrefix, uncheckedPrefix, checkedPrefix]) {
    if (text.startsWith(prefix, prefixStart)) {
      return (start: prefixStart, value: prefix);
    }
  }
  return (start: prefixStart, value: '');
}

int _mapOffset(int offset, List<_TextEdit> edits) {
  var delta = 0;
  for (final edit in edits) {
    if (offset < edit.start) break;
    if (offset <= edit.end) return edit.start + delta + edit.replacement.length;
    delta += edit.replacement.length - (edit.end - edit.start);
  }
  return offset + delta;
}

class _TextEdit {
  const _TextEdit({
    required this.start,
    required this.end,
    required this.replacement,
  });

  final int start;
  final int end;
  final String replacement;
}
