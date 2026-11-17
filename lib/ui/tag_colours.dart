import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// The eight colours a tag can take. A tag stores its colour as this key,
/// never as a value, so each theme gives it its own card and dot.
enum TagColour {
  mustard(
    Color(0xFF393425),
    Color(0xFFF4EBC8),
    Color(0xFFC9A447),
    Color(0xFFA88424),
  ),
  rust(
    Color(0xFF372B26),
    Color(0xFFF2E0D4),
    Color(0xFFC4734F),
    Color(0xFFB5643F),
  ),
  olive(
    Color(0xFF2B3125),
    Color(0xFFE6EBD5),
    Color(0xFF8F9B55),
    Color(0xFF6F7B38),
  ),
  teal(
    Color(0xFF273133),
    Color(0xFFDCE8E6),
    Color(0xFF4F9A9B),
    Color(0xFF3D8586),
  ),
  sage(
    Color(0xFF25332A),
    Color(0xFFD9EAD9),
    Color(0xFF5FA071),
    Color(0xFF4B8A5D),
  ),
  slate(
    Color(0xFF282D38),
    Color(0xFFDEE4F0),
    Color(0xFF6D88BE),
    Color(0xFF5873A8),
  ),
  plum(
    Color(0xFF322A37),
    Color(0xFFEADFEC),
    Color(0xFF9C77B4),
    Color(0xFF8A64A3),
  ),
  rose(
    Color(0xFF38292D),
    Color(0xFFF3DDE2),
    Color(0xFFC46F84),
    Color(0xFFB25C72),
  );

  const TagColour(
    this._darkCard,
    this._lightCard,
    this._darkDot,
    this._lightDot,
  );

  final Color _darkCard;
  final Color _lightCard;
  final Color _darkDot;
  final Color _lightDot;

  /// The colour of a card or row the tag colours.
  Color card(CalcPalette palette) =>
      palette.brightness == Brightness.dark ? _darkCard : _lightCard;

  /// The tag's dot, beside its name wherever the name appears.
  Color dot(CalcPalette palette) =>
      palette.brightness == Brightness.dark ? _darkDot : _lightDot;
}

/// A tag as a card, a row or a note square shows it. A null colour is No
/// colour: a plain card, and a ring for a dot.
typedef TagMark = ({String name, TagColour? colour});

/// Which tags each note carries, in the note's own order, for whatever below
/// it draws a note: the first one colours it.
class TagMarks extends InheritedWidget {
  const TagMarks({super.key, required this.marksOf, required super.child});

  final List<TagMark> Function(String noteId) marksOf;

  /// [noteId]'s tags; none where nothing above [context] keeps them.
  static List<TagMark> of(BuildContext context, String noteId) =>
      context.dependOnInheritedWidgetOfExactType<TagMarks>()?.marksOf(noteId) ??
      const [];

  @override
  bool updateShouldNotify(TagMarks oldWidget) =>
      !identical(oldWidget.marksOf, marksOf);
}

/// A note's tags as dots: the first in front, the rest overlapping behind it
/// 3 px apart, each ringed in [ground] so the overlap reads.
class TagDots extends StatelessWidget {
  const TagDots({super.key, required this.tags, required this.ground});

  final List<TagMark> tags;

  /// The card or row the dots sit on.
  final Color ground;

  static const double size = 6;
  static const double step = 3;

  /// How many dots show at most; past that the overlap says nothing more.
  static const int most = 3;

  static double widthFor(int count) =>
      count == 0 ? 0 : size + step * ((count > most ? most : count) - 1);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final shown = tags.take(most).toList();
    Widget dot(TagMark tag) {
      final colour = tag.colour;
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colour?.dot(palette) ?? ground,
          border: colour == null
              ? Border.all(color: palette.textMuted, width: 1.2)
              : null,
          boxShadow: [BoxShadow(color: ground, spreadRadius: 1.5)],
        ),
      );
    }

    return SizedBox(
      width: widthFor(shown.length),
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var index = shown.length - 1; index >= 0; index--)
            Positioned(
              left: step * (shown.length - 1 - index),
              top: 0,
              child: dot(shown[index]),
            ),
        ],
      ),
    );
  }
}
