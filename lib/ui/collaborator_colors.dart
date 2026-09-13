import 'package:material_ui/material_ui.dart';

/// The colour somebody's caret, name flag and avatar ring are drawn in.
///
/// Keyed by account rather than by who happens to be in the note, so a
/// person keeps one colour in every note and on every device that shows them
/// — which is what lets a flag in the text be matched to a face in the title
/// bar at a glance. Each colour carries white text at flag size.
Color collaboratorColor(String userId, {Brightness? on}) {
  final base = _colors[_hash(userId) % _colors.length];
  // A caret is a two-pixel line; on dark paper the deeper shades sink into
  // it, so they are lifted a little there.
  return on == Brightness.dark
      ? Color.lerp(base, const Color(0xFFFFFFFF), 0.18)!
      : base;
}

/// Eight hues far enough apart to tell a small group apart, all dark enough
/// for white text: none of them red, which this app keeps for errors.
const List<Color> _colors = [
  Color(0xFF1971C2), // blue
  Color(0xFFC2410C), // orange
  Color(0xFF2B8A3E), // green
  Color(0xFF9C36B5), // purple
  Color(0xFFC2255C), // pink
  Color(0xFF0B7285), // cyan
  Color(0xFFA16207), // amber
  Color(0xFF6741D9), // violet
];

int _hash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}
