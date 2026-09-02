enum NoteFormat { bold, italic, heading, subtitle }

extension NoteFormatKind on NoteFormat {
  bool get isInline => this == NoteFormat.bold || this == NoteFormat.italic;

  bool get isParagraph => !isInline;
}

/// A persisted text style over the half-open text range [start, end).
class NoteFormatRange {
  const NoteFormatRange({
    required this.start,
    required this.end,
    required this.format,
  });

  final int start;
  final int end;
  final NoteFormat format;

  Map<String, Object> toJson() => {
    'start': start,
    'end': end,
    'format': format.name,
  };

  static NoteFormatRange? fromJson(Object? raw, int textLength) {
    if (raw is! Map) return null;
    final start = raw['start'];
    final end = raw['end'];
    final formatName = raw['format'];
    if (start is! int || end is! int || formatName is! String) return null;

    NoteFormat? format;
    for (final candidate in NoteFormat.values) {
      if (candidate.name == formatName) {
        format = candidate;
        break;
      }
    }
    if (format == null) return null;

    final clippedStart = start.clamp(0, textLength);
    final clippedEnd = end.clamp(0, textLength);
    if (clippedEnd <= clippedStart) return null;
    return NoteFormatRange(
      start: clippedStart,
      end: clippedEnd,
      format: format,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NoteFormatRange &&
      other.start == start &&
      other.end == end &&
      other.format == format;

  @override
  int get hashCode => Object.hash(start, end, format);
}

/// Clips, sorts, and merges touching ranges of the same style.
List<NoteFormatRange> normalizeNoteFormats(
  Iterable<NoteFormatRange> ranges,
  int textLength,
) {
  final byFormat = <NoteFormat, List<NoteFormatRange>>{
    for (final format in NoteFormat.values) format: [],
  };
  for (final range in ranges) {
    final start = range.start.clamp(0, textLength);
    final end = range.end.clamp(0, textLength);
    if (end <= start) continue;
    byFormat[range.format]!.add(
      NoteFormatRange(start: start, end: end, format: range.format),
    );
  }

  final normalized = <NoteFormatRange>[];
  for (final format in NoteFormat.values) {
    final matching = byFormat[format]!
      ..sort((a, b) {
        final startOrder = a.start.compareTo(b.start);
        return startOrder != 0 ? startOrder : a.end.compareTo(b.end);
      });
    for (final range in matching) {
      if (normalized.isNotEmpty &&
          normalized.last.format == format &&
          range.start <= normalized.last.end) {
        final previous = normalized.removeLast();
        normalized.add(
          NoteFormatRange(
            start: previous.start,
            end: range.end > previous.end ? range.end : previous.end,
            format: format,
          ),
        );
      } else {
        normalized.add(range);
      }
    }
  }
  normalized.sort((a, b) {
    final startOrder = a.start.compareTo(b.start);
    if (startOrder != 0) return startOrder;
    final endOrder = a.end.compareTo(b.end);
    return endOrder != 0 ? endOrder : a.format.index.compareTo(b.format.index);
  });
  return List.unmodifiable(normalized);
}

List<NoteFormatRange> noteFormatsFromJson(Object? raw, int textLength) {
  if (raw is! List) return const [];
  return normalizeNoteFormats(
    raw
        .map((entry) => NoteFormatRange.fromJson(entry, textLength))
        .whereType<NoteFormatRange>(),
    textLength,
  );
}
