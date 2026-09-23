import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// What a drawing element is.
///
/// Stored by [name], so the order here is free to change. An element of a
/// kind this build does not know is skipped when read — a newer build's shape
/// stays in the document, where that build can still draw it.
enum DrawKind { pen, rect, ellipse, line, arrow, text }

/// One shape on a drawing's canvas.
///
/// Every element is a whole value: moving a rectangle writes the rectangle
/// again. That is what lets sync treat each one as a last-writer-wins cell
/// keyed by [id], so two people drawing on the same canvas keep each other's
/// strokes, and only two people dragging the *same* shape have to lose one
/// drag.
class DrawElement {
  DrawElement({
    required this.id,
    required this.kind,
    required this.points,
    required this.z,
    this.color,
    this.width = 2,
    this.text = '',
    this.fontSize = 20,
  });

  final String id;
  final DrawKind kind;

  /// Canvas coordinates, flat: `[x0, y0, x1, y1, …]`.
  ///
  /// A pen stroke has as many as were drawn; a rectangle, ellipse, line or
  /// arrow has exactly two corners/ends; text has one, its top-left.
  final List<double> points;

  /// Stacking order: higher draws on top. Ties break on [id], so every
  /// device stacks two elements added at the same moment the same way.
  final int z;

  /// ARGB, or null for the theme's ink — which is what keeps a drawing made
  /// in light mode legible in dark mode.
  final int? color;

  /// Stroke width in canvas units.
  final double width;

  /// The words of a [DrawKind.text] element; empty for every other kind.
  final String text;

  final double fontSize;

  int get pointCount => points.length ~/ 2;

  Offset pointAt(int index) => Offset(points[index * 2], points[index * 2 + 1]);

  Iterable<Offset> get offsets sync* {
    for (var i = 0; i < pointCount; i++) {
      yield pointAt(i);
    }
  }

  /// The box the geometry covers, before stroke width. Text is measured by
  /// the painter, so here it is only an estimate from its length.
  Rect get bounds {
    if (points.length < 2) return Rect.zero;
    if (kind == DrawKind.text) {
      final lines = text.split('\n');
      final longest = lines.fold<int>(0, (m, l) => math.max(m, l.length));
      return Rect.fromLTWH(
        points[0],
        points[1],
        math.max(fontSize, longest * fontSize * 0.55),
        lines.length * fontSize * 1.3,
      );
    }
    var left = points[0], right = points[0];
    var top = points[1], bottom = points[1];
    for (var i = 2; i + 1 < points.length; i += 2) {
      left = math.min(left, points[i]);
      right = math.max(right, points[i]);
      top = math.min(top, points[i + 1]);
      bottom = math.max(bottom, points[i + 1]);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  DrawElement copyWith({
    List<double>? points,
    int? z,
    Object? color = _keep,
    double? width,
    String? text,
    double? fontSize,
  }) => DrawElement(
    id: id,
    kind: kind,
    points: points ?? this.points,
    z: z ?? this.z,
    color: identical(color, _keep) ? this.color : color as int?,
    width: width ?? this.width,
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
  );

  DrawElement translated(Offset delta) => copyWith(
    points: [
      for (var i = 0; i < points.length; i++)
        points[i] + (i.isEven ? delta.dx : delta.dy),
    ],
  );

  /// Everything but [id], which is the key it is stored under.
  Map<String, Object?> toJson() => {
    'k': kind.name,
    'p': [for (final v in points) _round(v)],
    'z': z,
    if (color != null) 'c': color,
    'w': _round(width),
    if (kind == DrawKind.text) 's': text,
    if (kind == DrawKind.text) 'f': _round(fontSize),
  };

  static DrawElement? fromJson(String id, Object? raw) {
    if (raw is! Map) return null;
    final kindName = raw['k'];
    DrawKind? kind;
    for (final candidate in DrawKind.values) {
      if (candidate.name == kindName) kind = candidate;
    }
    final rawPoints = raw['p'];
    if (kind == null || rawPoints is! List || rawPoints.length < 2) {
      return null;
    }
    final points = <double>[];
    for (final value in rawPoints) {
      if (value is! num || !value.isFinite) return null;
      points.add(value.toDouble());
    }
    if (points.length.isOdd) points.removeLast();
    final z = raw['z'];
    final color = raw['c'];
    final width = raw['w'];
    final text = raw['s'];
    final fontSize = raw['f'];
    return DrawElement(
      id: id,
      kind: kind,
      points: List.unmodifiable(points),
      z: z is num ? z.toInt() : 0,
      color: color is num ? color.toInt() : null,
      width: width is num && width > 0 ? width.toDouble() : 2,
      text: text is String ? text : '',
      fontSize: fontSize is num && fontSize > 0 ? fontSize.toDouble() : 20,
    );
  }

  /// A tenth of a unit is finer than any screen draws, and keeps a long pen
  /// stroke from carrying sixteen digits per coordinate into every sync.
  static num _round(double value) {
    final rounded = (value * 10).roundToDouble() / 10;
    return rounded == rounded.truncateToDouble() ? rounded.toInt() : rounded;
  }

  late final String _encoded = jsonEncode([id, toJson()]);

  @override
  bool operator ==(Object other) =>
      other is DrawElement && other._encoded == _encoded;

  @override
  int get hashCode => _encoded.hashCode;
}

const Object _keep = Object();

/// A note's canvas: its elements, bottom to top.
///
/// A note with a drawing is a drawing note — its body is only a title. A
/// build from before drawings shows that title and an otherwise empty note,
/// and leaves the canvas where it found it.
class NoteDrawing {
  NoteDrawing([Iterable<DrawElement> elements = const []])
    : elements = List.unmodifiable((elements.toList()..sort(_stacking)));

  static final NoteDrawing empty = NoteDrawing();

  final List<DrawElement> elements;

  bool get isEmpty => elements.isEmpty;

  /// The next [DrawElement.z] that stacks above everything here.
  int get nextZ => elements.isEmpty ? 0 : elements.last.z + 1;

  DrawElement? byId(String id) {
    for (final element in elements) {
      if (element.id == id) return element;
    }
    return null;
  }

  Rect? get bounds {
    Rect? all;
    for (final element in elements) {
      final box = element.bounds.inflate(element.width);
      all = all == null ? box : all.expandToInclude(box);
    }
    return all;
  }

  /// Replaces elements by id, adding any that are new.
  NoteDrawing upsert(Iterable<DrawElement> changed) {
    final byId = {for (final e in elements) e.id: e};
    for (final element in changed) {
      byId[element.id] = element;
    }
    return NoteDrawing(byId.values);
  }

  NoteDrawing remove(Iterable<String> ids) {
    final gone = ids.toSet();
    return NoteDrawing(elements.where((e) => !gone.contains(e.id)));
  }

  Map<String, Object?> toJson() => {
    'elements': [
      for (final element in elements) {'id': element.id, ...element.toJson()},
    ],
  };

  static NoteDrawing? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final list = raw['elements'];
    if (list is! List) return NoteDrawing.empty;
    return NoteDrawing([
      for (final entry in list)
        if (entry is Map && entry['id'] is String)
          ?DrawElement.fromJson(entry['id'] as String, entry),
    ]);
  }

  static int _stacking(DrawElement a, DrawElement b) {
    final byZ = a.z.compareTo(b.z);
    return byZ != 0 ? byZ : a.id.compareTo(b.id);
  }

  @override
  bool operator ==(Object other) {
    if (other is! NoteDrawing || other.elements.length != elements.length) {
      return false;
    }
    for (var i = 0; i < elements.length; i++) {
      if (other.elements[i] != elements[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(elements);
}
