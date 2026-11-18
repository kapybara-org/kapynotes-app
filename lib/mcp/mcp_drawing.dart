import 'dart:math' as math;

import '../data/note_drawing.dart';
import 'mcp_library.dart';

/// Drawings as an assistant reads and writes them.
///
/// The canvas is vector already, so reading is exact: each element becomes
/// one SVG element carrying its id. Writing takes elements in the canvas's
/// own kinds, never SVG, so nothing arrives that the app can't draw.
abstract final class McpDrawing {
  static const int maxPerCall = 500;
  static const int maxElements = 10000;
  static const int maxPenPoints = 5000;
  static const double maxCoordinate = 100000;
  static const int maxText = 2000;

  /// Past this an SVG is left out of a read; the element count still says
  /// what is there.
  static const int maxSvg = 200000;

  static const List<String> kinds = [
    'pen',
    'line',
    'arrow',
    'rect',
    'ellipse',
    'text',
  ];

  /// The whole canvas as an SVG. Elements in the theme's ink use
  /// `currentColor`, as the app draws them in whichever ink the theme has.
  static String svg(NoteDrawing drawing) {
    final elements = drawing.elements;
    var box = elements.isEmpty
        ? const (left: 0.0, top: 0.0, right: 400.0, bottom: 300.0)
        : null;
    for (final element in elements) {
      final b = element.bounds.inflate(element.width + 4);
      box = box == null
          ? (left: b.left, top: b.top, right: b.right, bottom: b.bottom)
          : (
              left: math.min(box.left, b.left),
              top: math.min(box.top, b.top),
              right: math.max(box.right, b.right),
              bottom: math.max(box.bottom, b.bottom),
            );
    }
    final out = StringBuffer(
      '<svg xmlns="http://www.w3.org/2000/svg" '
      'viewBox="${_n(box!.left)} ${_n(box.top)} '
      '${_n(box.right - box.left)} ${_n(box.bottom - box.top)}" '
      'fill="none" stroke-linecap="round" stroke-linejoin="round">',
    );
    for (final element in elements) {
      out.write(_element(element));
    }
    out.write('</svg>');
    return out.toString();
  }

  static String _element(DrawElement e) {
    final paint = _paint(e.color);
    final stroke = 'stroke="$paint" stroke-width="${_n(e.width)}"';
    final id = 'id="${_escape(e.id)}"';
    switch (e.kind) {
      case DrawKind.pen:
        final points = [
          for (final p in e.offsets) '${_n(p.dx)},${_n(p.dy)}',
        ].join(' ');
        return '<polyline $id points="$points" $stroke/>';
      case DrawKind.line:
        return '<line $id ${_ends(e)} $stroke/>';
      case DrawKind.arrow:
        final from = e.pointAt(0), to = e.pointAt(1);
        final angle = math.atan2(to.dy - from.dy, to.dx - from.dx);
        final head = math.max(10.0, e.width * 4);
        String wing(double turn) =>
            '${_n(to.dx - head * math.cos(angle + turn))},'
            '${_n(to.dy - head * math.sin(angle + turn))}';
        return '<g $id $stroke><line ${_ends(e)}/>'
            '<polyline points="${wing(0.45)} ${_n(to.dx)},${_n(to.dy)} '
            '${wing(-0.45)}"/></g>';
      case DrawKind.rect:
        final b = e.bounds;
        return '<rect $id x="${_n(b.left)}" y="${_n(b.top)}" '
            'width="${_n(b.width)}" height="${_n(b.height)}" $stroke/>';
      case DrawKind.ellipse:
        final b = e.bounds;
        return '<ellipse $id cx="${_n(b.center.dx)}" cy="${_n(b.center.dy)}" '
            'rx="${_n(b.width / 2)}" ry="${_n(b.height / 2)}" $stroke/>';
      case DrawKind.text:
        final at = e.pointAt(0);
        final lines = [
          for (final (i, line) in e.text.split('\n').indexed)
            '<tspan x="${_n(at.dx)}" dy="${i == 0 ? _n(e.fontSize) : _n(e.fontSize * 1.3)}">'
                '${_escape(line)}</tspan>',
        ].join();
        return '<text $id x="${_n(at.dx)}" y="${_n(at.dy)}" '
            'font-size="${_n(e.fontSize)}" fill="$paint" stroke="none">'
            '$lines</text>';
    }
  }

  static String _ends(DrawElement e) =>
      'x1="${_n(e.points[0])}" y1="${_n(e.points[1])}" '
      'x2="${_n(e.points[2])}" y2="${_n(e.points[3])}"';

  static String _paint(int? argb) {
    if (argb == null) return 'currentColor';
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  static String _n(double value) {
    final rounded = (value * 10).round() / 10;
    return rounded == rounded.roundToDouble()
        ? rounded.toInt().toString()
        : rounded.toString();
  }

  static String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// One element an assistant asked to add, checked as the canvas would
  /// have it. [id] and [z] are the canvas's to give.
  static DrawElement parse(Object? raw, {required String id, required int z}) {
    if (raw is! Map<String, Object?>) {
      throw const McpRefusal('Each element is an object.');
    }
    final kind = DrawKind.values
        .where((kind) => kind.name == raw['kind'])
        .firstOrNull;
    if (kind == null) {
      throw McpRefusal('An element’s kind is one of ${kinds.join(', ')}.');
    }
    final rawPoints = raw['points'];
    if (rawPoints is! List) {
      throw const McpRefusal('An element needs points, as [x, y] pairs.');
    }
    final points = <double>[];
    for (final pair in rawPoints) {
      if (pair is! List || pair.length != 2) {
        throw const McpRefusal('Each point is an [x, y] pair.');
      }
      for (final value in pair) {
        if (value is! num || !value.isFinite || value.abs() > maxCoordinate) {
          throw McpRefusal(
            'Coordinates are numbers from -${maxCoordinate.toInt()} to '
            '${maxCoordinate.toInt()}.',
          );
        }
        points.add(value.toDouble());
      }
    }
    final count = points.length ~/ 2;
    final wanted = switch (kind) {
      DrawKind.pen => count >= 1 && count <= maxPenPoints,
      DrawKind.text => count == 1,
      _ => count == 2,
    };
    if (!wanted) {
      throw McpRefusal(switch (kind) {
        DrawKind.pen => 'A pen stroke has 1 to $maxPenPoints points.',
        DrawKind.text => 'Text has one point, its top-left corner.',
        _ => 'A ${kind.name} has two points.',
      });
    }
    final text = raw['text'];
    if (kind == DrawKind.text) {
      if (text is! String || text.trim().isEmpty || text.length > maxText) {
        throw const McpRefusal('Text needs 1 to $maxText characters of text.');
      }
      McpLibrary.checkText(text, 'text');
    }
    return DrawElement(
      id: id,
      kind: kind,
      points: points,
      z: z,
      color: _color(raw['color']),
      width: _number(raw['width'], 'width', 0.5, 40) ?? 2,
      text: kind == DrawKind.text ? text! as String : '',
      fontSize: _number(raw['font_size'], 'font_size', 8, 200) ?? 20,
    );
  }

  static final RegExp _hex = RegExp(r'^#[0-9a-fA-F]{6}$');

  static int? _color(Object? raw) {
    if (raw == null) return null;
    if (raw is! String || !_hex.hasMatch(raw)) {
      throw const McpRefusal('A colour is #RRGGBB, or left out for ink.');
    }
    return 0xFF000000 | int.parse(raw.substring(1), radix: 16);
  }

  static double? _number(Object? raw, String key, double min, double max) {
    if (raw == null) return null;
    if (raw is! num || raw < min || raw > max) {
      throw McpRefusal('$key is a number from ${_n(min)} to ${_n(max)}.');
    }
    return raw.toDouble();
  }
}
