import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import 'tag_ui.dart' show TagDot;

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

/// A note's tags as dots, side by side: 6 px and 2 apart on the Mac and
/// the desktops, 8 px and 4 apart on phones. A tag with no colour is a
/// hollow dot.
class TagDots extends StatelessWidget {
  const TagDots({super.key, required this.tags});

  final List<TagMark> tags;

  static double get size => AppPlatform.hasPointer ? 6 : 8;
  static double get gap => AppPlatform.hasPointer ? 2 : 4;

  /// How many dots show at most; past that more dots say nothing more.
  static const int most = 3;

  static double widthFor(int count) {
    final shown = count > most ? most : count;
    return shown == 0 ? 0 : size * shown + gap * (shown - 1);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: gap,
      children: [
        for (final tag in tags.take(most)) TagDot(tag.colour, size: size),
      ],
    );
  }
}
