/// A single note. Title and preview are always derived from [body] rather
/// than stored, so they can never drift out of sync with the text.
class Note {
  final String id;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Note({
    required this.id,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
  });

  static const String untitled = 'New Note';
  static const String noPreview = 'No additional text';
  static const int _titleLimit = 60;

  Note copyWith({String? body, DateTime? updatedAt}) => Note(
    id: id,
    body: body ?? this.body,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// First non-empty line, without heading markers or a trailing colon.
  String get title {
    final line = _firstNonEmptyLine();
    if (line == null) return untitled;

    var text = line.trimLeft();
    text = text.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    text = text.trimRight();
    if (text.endsWith(':')) {
      text = text.substring(0, text.length - 1).trimRight();
    }
    if (text.isEmpty) return untitled;

    return text.length > _titleLimit
        ? '${text.substring(0, _titleLimit).trimRight()}…'
        : text;
  }

  /// The next non-empty line after the one used for the title.
  String get preview {
    final lines = body.split('\n');
    var seenTitle = false;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      if (!seenTitle) {
        seenTitle = true;
        continue;
      }
      return line.trim();
    }
    return noPreview;
  }

  bool get isEmpty => body.trim().isEmpty;

  /// Case-insensitive match against the whole body, not just the title.
  bool matches(String query) =>
      body.toLowerCase().contains(query.toLowerCase());

  /// The first line containing [query], shown instead of the preview so the
  /// user can see *why* a note matched.
  String? matchSnippet(String query) {
    if (query.isEmpty) return null;
    final needle = query.toLowerCase();
    for (final line in body.split('\n')) {
      if (line.toLowerCase().contains(needle)) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) return trimmed;
      }
    }
    return null;
  }

  String? _firstNonEmptyLine() {
    for (final line in body.split('\n')) {
      if (line.trim().isNotEmpty) return line;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'body': body,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  static Note? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final body = raw['body'];
    if (id is! String || body is! String) return null;
    return Note(
      id: id,
      body: body,
      createdAt: _date(raw['createdAt']),
      updatedAt: _date(raw['updatedAt']),
    );
  }

  static DateTime _date(Object? value) =>
      DateTime.fromMillisecondsSinceEpoch(value is int ? value : 0);
}
