import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// The eight colours a tag can take. A tag stores its colour as this key,
/// never as a value, so each theme gives it its own dot.
enum TagColour {
  mustard,
  rust,
  olive,
  teal,
  sage,
  slate,
  plum,
  rose;

  /// The tag's dot, beside its name wherever the name appears.
  Color dot(CalcPalette palette) => palette.tagDots[index];
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
