import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/tex.dart';

/// One formula, ready for a line of the note: the widget that draws it and
/// the room it takes, with how far down that room its baseline sits.
typedef NoteFormula = ({
  Widget child,
  double width,
  double height,
  double baseline,
});

/// One formula as it is drawn: its TeX, set apart or not, at a size, in a
/// colour.
typedef _Drawn = (String tex, bool display, double fontSize, Color color);

/// Formulas in TeX, drawn by flutter_math_fork and sized before the text
/// around them is laid out.
///
/// A formula stands in its line as a placeholder, and a text engine has to be
/// told how big every placeholder is before it can break lines: the field asks
/// the widget, and everything that measures the note apart from the field has
/// only the numbers. So each formula is laid out once, in a widget tree of its
/// own that is never shown, and its size kept.
///
/// The widgets handed to the field are kept as well, so that a formula nobody
/// touched is never built twice — one for every formula in the note, never
/// one for two. flutter_math_fork keys each line it builds with a [GlobalKey]
/// kept in the formula's parsed TeX, so a widget shown in two places is one
/// key in two places, and the second takes the line away from the first.
class NoteMath {
  final Map<String, bool> _drawable = {};
  final Map<_Drawn, ({double width, double height, double baseline})> _boxes =
      {};
  final Map<(_Drawn, int), Widget> _widgets = {};
  _Offscreen? _offscreen;

  /// Whether [tex] is TeX flutter_math_fork reads. One it cannot is shown as
  /// written instead.
  bool draws(String tex) {
    final known = _drawable[tex];
    if (known != null) return known;
    if (_drawable.length > 512) _drawable.clear();
    return _drawable[tex] =
        Math.tex(_readable(tex), settings: _settings).parseError == null;
  }

  /// [tex] with what pandoc and Wikipedia write and flutter_math_fork does
  /// not read, as what it does. The environments of a LaTeX document become
  /// the ones it has: `align` is drawn as `aligned` is, `alignat` as
  /// `alignedat`, a `split` as `aligned`, and an `equation` is only the
  /// number a note has no use for. A phantom of a sized delimiter written
  /// without braces, `\vphantom\bigg)`, which Wikipedia's TeX reads as one
  /// argument, gets its braces.
  static String _readable(String tex) => tex
      .replaceAllMapped(
        _environment,
        (match) => switch (match[2]) {
          'equation' => '',
          'alignat' => '\\${match[1]}{alignedat}',
          _ => '\\${match[1]}{aligned}',
        },
      )
      .replaceAllMapped(
        _phantomDelimiter,
        (match) => '\\${match[1]}{${match[2]}}',
      );

  static final _environment = RegExp(
    r'\\(begin|end)\{(align|alignat|equation|split)\*?\}',
  );

  static final _phantomDelimiter = RegExp(
    r'\\([vh]?phantom)\s*(\\[Bb]igg?[lmr]?\s*(?:\\[A-Za-z]+|\\.|[^\s\\{}]))',
  );

  /// The commands Wikipedia's TeX has that flutter_math_fork lacks: `\sgn`,
  /// the sign function.
  static final _settings = TexParserSettings(
    macros: {r'\sgn': MacroDefinition.fromString(r'\operatorname{sgn}')},
  );

  /// [tex] drawn at [fontSize] in [color], set apart from the words around it
  /// when [display], and no wider than [maxWidth]: a formula wider than the
  /// writing column is drawn smaller rather than cut off.
  ///
  /// [copy] says which of the note's formulas with this TeX it is, counting
  /// from 0 in the order they are written, and each gets a widget of its own.
  NoteFormula formula(
    String tex, {
    required bool display,
    required double fontSize,
    required Color color,
    required double maxWidth,
    required int copy,
  }) {
    var drawn = (tex, display, fontSize, color);
    var box = _box(drawn);
    if (box.width > maxWidth && maxWidth > 0) {
      // Rules and spacing scale with the size, so this is close to exact; what
      // little is not is taken up by asking for a touch less.
      final fitted =
          (fontSize * maxWidth / box.width * 0.98 * 10).floorToDouble() / 10;
      drawn = (tex, display, fitted, color);
      box = _box(drawn);
    }
    if (_widgets.length > 1024) _widgets.clear();
    return (
      child: _widgets[(drawn, copy)] ??= _math(drawn),
      width: box.width,
      height: box.height,
      baseline: box.baseline,
    );
  }

  /// How big [drawn] is, measured with a widget of its own that is never
  /// shown.
  ({double width, double height, double baseline}) _box(_Drawn drawn) {
    final known = _boxes[drawn];
    if (known != null) return known;
    if (_boxes.length > 512) _boxes.clear();
    return _boxes[drawn] = (_offscreen ??= _Offscreen()).measure(_math(drawn));
  }

  /// [drawn] as a widget, with nothing of it in the semantics tree. A screen
  /// reader reads the note's text, where a formula is its TeX, and
  /// flutter_math_fork gives every glyph a node of its own, which in a note
  /// with hundreds of formulas is most of the tree.
  Widget _math(_Drawn drawn) {
    final (tex, display, fontSize, color) = drawn;
    return ExcludeSemantics(
      child: Math.tex(
        _readable(tex),
        settings: _settings,
        options: MathOptions(
          style: display ? MathStyle.display : MathStyle.text,
          fontSize: fontSize,
          color: color,
        ),
        // Only what TeX parses and still cannot build gets here: shown as its
        // TeX, which is what a formula that does not parse is shown as too.
        onErrorFallback: (_) => Text(
          tex,
          style: TextStyle(fontSize: fontSize, color: color),
          textDirection: TextDirection.ltr,
        ),
      ),
    );
  }

  void dispose() {
    _offscreen?.dispose();
    _offscreen = null;
    _boxes.clear();
    _widgets.clear();
  }
}

/// A widget tree of its own, laid out and never painted, for knowing how big
/// a widget is before it is shown.
class _Offscreen {
  _Offscreen() {
    _pipeline.rootNode = _root;
    _root.scheduleInitialLayout();
    _element = RenderObjectToWidgetAdapter<RenderBox>(
      container: _root,
      child: const SizedBox.shrink(),
    ).attachToRenderTree(_owner);
  }

  final _pipeline = PipelineOwner();
  final _owner = BuildOwner(focusManager: FocusManager());
  final _root = _Measure();
  late final RenderObjectToWidgetElement<RenderBox> _element;

  ({double width, double height, double baseline}) measure(Widget widget) {
    RenderObjectToWidgetAdapter<RenderBox>(
      container: _root,
      child: Directionality(textDirection: TextDirection.ltr, child: widget),
    ).attachToRenderTree(_owner, _element);
    _owner.buildScope(_element);
    _pipeline.flushLayout();
    // The formula measured before this one is done with.
    _owner.finalizeTree();
    return (
      width: _root.size.width,
      height: _root.size.height,
      baseline: _root.baseline,
    );
  }

  void dispose() {
    RenderObjectToWidgetAdapter<RenderBox>(
      container: _root,
    ).attachToRenderTree(_owner, _element);
    _owner.buildScope(_element);
    _owner.finalizeTree();
    _owner.focusManager.dispose();
    _pipeline.rootNode = null;
    _pipeline.dispose();
  }
}

/// The root of [_Offscreen]: lays its one child out at the size it wants, and
/// asks it for its baseline, which only a parent laying it out may do.
class _Measure extends RenderObject with RenderObjectWithChildMixin<RenderBox> {
  Size size = Size.zero;
  double baseline = 0;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) return;
    child.layout(const BoxConstraints(), parentUsesSize: true);
    size = child.size;
    baseline =
        child.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true) ??
        size.height;
  }

  @override
  void performResize() {}

  @override
  void debugAssertDoesMeetConstraints() {}

  @override
  Rect get paintBounds => Offset.zero & size;

  @override
  Rect get semanticBounds => paintBounds;
}
