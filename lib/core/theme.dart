import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'appearance.dart';
import 'editor_font.dart';
import 'platform.dart';

export 'iconography.dart';

/// A window's two themes and the mode that picks between them.
typedef WindowLook = ({ThemeData light, ThemeData dark, ThemeMode mode});

/// Colours for calculator-specific surfaces: syntax highlighting and result
/// chips. Carried as a [ThemeExtension] so widgets read them from the theme
/// rather than importing a palette directly.
@immutable
class CalcPalette extends ThemeExtension<CalcPalette> {
  final Color number;
  final Color keyword;
  final Color unit;
  final Color currency;
  final Color function;
  final Color variable;
  final Color operator;
  final Color comment;

  final Color chipNumber;
  final Color chipCurrency;
  final Color chipUnit;
  final Color chipBoolean;
  final Color chipOther;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color separator;
  final Color sidebarBackground;
  final Color editorBackground;
  final Color gutterBackground;
  final Color surfaceBackground;
  final Color controlBackground;
  final Color controlBorder;
  final Color selectedBackground;
  final Color selectedBorder;
  final Color selection;
  final Color hover;
  final Color paperFiber;

  /// The hairline under each row when the paper is ruled.
  ///
  /// Its own colour rather than [paperFiber]'s, which is a warm ink tone that
  /// only exists on the light theme — ruling asked for in the dark has to be
  /// visible there too. Fainter than [separator], because this repeats down
  /// the whole page and a divider's weight would read as a form to fill in.
  final Color paperRuling;

  /// The spaces rail down the window's left edge: a step behind the canvas,
  /// with a hairline where it meets the notes list.
  final Color railBackground;
  final Color railBorder;

  /// The tonal button: the calm primary action, a sage label on its own
  /// quiet sage tint, and the chip that names its shortcut.
  final Color tonalBackground;
  final Color tonalForeground;
  final Color tonalKeyBackground;
  final Color tonalKeyText;

  /// A key printed the way the keyboard prints it: ⌘F, /, esc.
  final Color keycapBackground;
  final Color keycapBorder;
  final Color keycapText;

  /// What dims the window behind a modal.
  final Color scrim;

  /// A calculation's result, set as a pill at the end of its line, and the
  /// stronger pill the total line gets.
  final Color resultPillBackground;
  final Color resultPillText;
  final Color totalPillBackground;
  final Color totalPillText;

  /// Riverbank's clay, the one warm mark on the page: a pinned note's pin,
  /// the note title's hand-drawn underline, the streak's flame, the badge
  /// that counts invitations and what marks a picture that didn't load.
  final Color clay;

  /// Clay as words: deeper than [clay] on light paper and paler on dark, so
  /// it reads as text. What says a note's pictures didn't load.
  final Color clayText;

  /// The type ladder under the primary ink: a window or dialog's own title,
  /// the heading over a group, the label of a row that is not selected, and
  /// the line that describes what a row does.
  final Color textHeading;
  final Color textSubheading;
  final Color textMuted;
  final Color textDescription;

  /// A card of rows inside a dialog, a step off the pane it sits on, and the
  /// edge between a dialog's navigation and its pane.
  final Color cardBackground;
  final Color paneEdge;

  /// A switch that is off: the track reads as a slot, not as a control.
  final Color switchTrackOff;

  /// The edge of a checkbox that is not ticked, on the page.
  final Color checkboxBorder;

  /// The "+" beside an empty line that opens Commands, at rest.
  final Color lineCommand;

  /// What an empty line says before anything is typed on it.
  final Color writingHint;

  /// The title on a note's sticky card or list row, and the sage that marks
  /// a link inside the list, such as See all.
  final Color cardTitle;
  final Color accentText;

  /// The page's edge, and the slash between a breadcrumb's steps or the dot
  /// between a note's dates: fainter than any text that is meant to be read.
  final Color pageBorder;
  final Color textDivider;

  /// A switch's thumb while it is on, standing on the sage track.
  final Color switchThumb;

  /// The sunken track a segmented choice or a stepper sits in, below the
  /// card it is on, and the raised segment that is chosen inside it.
  final Color wellBackground;
  final Color segmentSelected;

  /// What casts every shadow, with its alpha as the strength: black in dark,
  /// the ink at a fraction of that in light, where a black shadow reads as
  /// dirt on the paper.
  final Color shadow;

  /// What marks focus, the caret, the open note and whatever is on or done:
  /// Riverbank's sage, and each theme's own accent.
  final Color accent;

  /// Ink set on [accent]: the check in a ticked box, a filled button's label.
  final Color onAccent;

  /// Code in a note, Paper's p-5-0: clay keywords, sage strings, ochre
  /// numbers and teal built-ins, each a shade deeper in light.
  final Color codeKeyword;
  final Color codeString;
  final Color codeNumber;
  final Color codeBuiltIn;

  /// The panel under a code block, a step below the page.
  final Color codePanel;

  /// The pill under inline code and a formula's TeX.
  final Color codeChip;

  /// The rail's icons and labels at rest. Paper's dark rail is a step
  /// lighter than the tertiary ink the rest of the app shares.
  final Color railInk;

  /// A quote's bar, Paper's.
  final Color quoteBar;

  /// Each tag colour's card and dot, in tag order: mustard, rust, olive,
  /// teal, sage, slate, plum and rose. A tag keeps its name in every theme;
  /// only these change.
  final List<Color> tagCards;
  final List<Color> tagDots;

  /// Whether this is Increase contrast's version of the palette, which also
  /// draws keyboard focus as a ring rather than a tint.
  final bool increasedContrast;

  /// The shadow a black at [alpha] casts in dark, scaled by [shadow]'s own
  /// strength so the dark values stay exact and light ones soften with it.
  Color shadowAt(int alpha) => shadow.withAlpha((shadow.a * alpha).round());

  /// How much of the desktop the window's chrome lets through: a multiplier on
  /// the alpha of every [GlassSurface]. 1 is fully opaque.
  ///
  /// The toolbar and the note footer read this. The writing surfaces have
  /// their own knob, [paperTranslucency], because a paragraph needs more body
  /// under it than a row of buttons does. The sidebar reads neither: see
  /// [sidebarColor].
  final double translucency;

  /// How much of the desktop the writing surfaces let through: a multiplier
  /// on the alpha of the paper, the results gutter and the empty pane. 1 is
  /// fully opaque.
  ///
  /// Dialogs, menus, popovers and tooltips never read either knob. They float
  /// over the note, and a menu you can read the note through is a menu you
  /// cannot read.
  final double paperTranslucency;

  /// Whether the desktop shows through the window at all: the transparency
  /// setting, on a platform that can blur what is behind the window, with no
  /// accessibility mode asking for solid surfaces.
  bool get isGlass => translucency < 1 || paperTranslucency < 1;

  /// The writing surface as painted in this mode.
  Color get paperColor =>
      editorBackground.withMultipliedAlpha(paperTranslucency);

  /// The results gutter as painted in this mode.
  Color get gutterColor =>
      gutterBackground.withMultipliedAlpha(paperTranslucency);

  /// The sidebar's own fill — solid, in both modes.
  ///
  /// The notes list is a panel you summon over the writing surface, not part
  /// of it, and it is the one place the desktop showing through costs more
  /// than it gives: a column of note titles has no body of its own to hold
  /// them off a wallpaper. Thinned with the rest of the chrome it also came
  /// out further through than the paper beside it — [translucency] sits a
  /// step below [paperTranslucency] — which read as the list being the more
  /// transparent of the two rather than the steadier one.
  ///
  /// The 0.96 is not translucency. It is the shade the sidebar has always sat
  /// at against the paper, resolved to a colour here rather than left as an
  /// alpha for whatever happens to be behind the window.
  Color get sidebarColor => Color.alphaBlend(
    sidebarBackground.withMultipliedAlpha(0.96),
    editorBackground,
  );

  /// The glass rim: a hairline of light along the top edge of a translucent
  /// surface, the way a real pane catches the light. Nothing in an opaque
  /// palette, so the chrome does not grow an edge with transparency off, and
  /// nothing in the dark, where a lit edge on charcoal reads as an outline
  /// rather than a reflection.
  Color get glassHighlight => isGlass && brightness == Brightness.light
      ? const Color(0x8CFFFFFF)
      : const Color(0x00000000);

  /// Which appearance the palette is drawn for, judged from its paper.
  Brightness get brightness =>
      ThemeData.estimateBrightnessForColor(editorBackground);

  /// The same palette with every surface solid: what Increase contrast,
  /// Reduce Transparency and a desktop with no blur behind the window all ask
  /// for.
  CalcPalette get opaque =>
      isGlass ? copyWith(translucency: 1, paperTranslucency: 1) : this;

  /// Increase contrast (Themes r2, p-N-0): one transform over whichever
  /// palette is on screen, so no theme keeps a second set of colours in step.
  ///
  /// Body text, headings and card titles move 60% of the way to white in the
  /// dark and to black in the light. Secondary text moves halfway to that new
  /// ink, and muted and faint text 45%. Lines become mixes of the page and the
  /// new ink: borders 42% in the dark and 52% in the light, hairlines 22%,
  /// dividers 45%, checkbox outlines and a quote's bar 50%. The accent moves
  /// 18% toward white or black, links 30% and the tonal button's label 45%.
  /// Tag cards and dots stay as they are, so a tag looks the same and its
  /// label, in the stronger ink, reads more easily. Channels are mixed in
  /// whole steps and rounded half up, which is how the spec's table of
  /// values was worked out.
  CalcPalette withIncreasedContrast() {
    if (increasedContrast) return this;
    final dark = brightness == Brightness.dark;
    final extreme = dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
    final ink = _mix(textPrimary, extreme, 0.6);
    final faint = _mix(textTertiary, ink, 0.45);
    final secondary = _mix(textSecondary, ink, 0.5);
    final border = _mix(editorBackground, ink, dark ? 0.42 : 0.52);
    final hairline = _mix(editorBackground, ink, 0.22);
    final outline = _mix(editorBackground, ink, 0.5);
    final strongAccent = _mix(accent, extreme, 0.18);
    return copyWith(
      number: ink,
      keyword: ink,
      function: ink,
      variable: ink,
      unit: faint,
      currency: faint,
      operator: faint,
      comment: faint,
      textPrimary: ink,
      textHeading: ink,
      cardTitle: ink,
      textSubheading: _mix(textSubheading, extreme, 0.6),
      textSecondary: secondary,
      keycapText: secondary,
      textDescription: _mix(textDescription, ink, 0.5),
      textMuted: _mix(textMuted, ink, 0.45),
      textTertiary: faint,
      controlBorder: border,
      paneEdge: border,
      pageBorder: hairline,
      paperRuling: hairline,
      textDivider: _mix(editorBackground, ink, 0.45),
      checkboxBorder: outline,
      quoteBar: outline,
      accent: strongAccent,
      selectedBorder: strongAccent,
      totalPillBackground: strongAccent,
      accentText: _mix(accentText, extreme, 0.3),
      tonalForeground: _mix(tonalForeground, extreme, 0.45),
      increasedContrast: true,
    );
  }

  const CalcPalette({
    required this.number,
    required this.keyword,
    required this.unit,
    required this.currency,
    required this.function,
    required this.variable,
    required this.operator,
    required this.comment,
    required this.chipNumber,
    required this.chipCurrency,
    required this.chipUnit,
    required this.chipBoolean,
    required this.chipOther,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.separator,
    required this.sidebarBackground,
    required this.editorBackground,
    required this.gutterBackground,
    required this.surfaceBackground,
    required this.controlBackground,
    required this.controlBorder,
    required this.selectedBackground,
    required this.selectedBorder,
    required this.selection,
    required this.hover,
    required this.paperFiber,
    required this.paperRuling,
    required this.railBackground,
    required this.railBorder,
    required this.tonalBackground,
    required this.tonalForeground,
    required this.tonalKeyBackground,
    required this.tonalKeyText,
    required this.keycapBackground,
    required this.keycapBorder,
    required this.keycapText,
    required this.scrim,
    required this.resultPillBackground,
    required this.resultPillText,
    required this.totalPillBackground,
    required this.totalPillText,
    required this.clay,
    required this.clayText,
    required this.textHeading,
    required this.textSubheading,
    required this.textMuted,
    required this.textDescription,
    required this.cardBackground,
    required this.paneEdge,
    required this.switchTrackOff,
    required this.checkboxBorder,
    required this.lineCommand,
    required this.writingHint,
    required this.cardTitle,
    required this.accentText,
    required this.pageBorder,
    required this.textDivider,
    required this.switchThumb,
    required this.wellBackground,
    required this.segmentSelected,
    required this.shadow,
    required this.accent,
    required this.onAccent,
    required this.codeKeyword,
    required this.codeString,
    required this.codeNumber,
    required this.codeBuiltIn,
    required this.codePanel,
    required this.codeChip,
    required this.railInk,
    required this.quoteBar,
    required this.tagCards,
    required this.tagDots,
    this.increasedContrast = false,
    this.translucency = 1,
    this.paperTranslucency = 1,
  });

  @override
  CalcPalette copyWith({
    Color? number,
    Color? keyword,
    Color? unit,
    Color? currency,
    Color? function,
    Color? variable,
    Color? operator,
    Color? comment,
    Color? chipNumber,
    Color? chipCurrency,
    Color? chipUnit,
    Color? chipBoolean,
    Color? chipOther,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? separator,
    Color? sidebarBackground,
    Color? editorBackground,
    Color? gutterBackground,
    Color? surfaceBackground,
    Color? controlBackground,
    Color? controlBorder,
    Color? selectedBackground,
    Color? selectedBorder,
    Color? selection,
    Color? hover,
    Color? paperFiber,
    Color? paperRuling,
    Color? railBackground,
    Color? railBorder,
    Color? tonalBackground,
    Color? tonalForeground,
    Color? tonalKeyBackground,
    Color? tonalKeyText,
    Color? keycapBackground,
    Color? keycapBorder,
    Color? keycapText,
    Color? scrim,
    Color? resultPillBackground,
    Color? resultPillText,
    Color? totalPillBackground,
    Color? totalPillText,
    Color? clay,
    Color? clayText,
    Color? textHeading,
    Color? textSubheading,
    Color? textMuted,
    Color? textDescription,
    Color? cardBackground,
    Color? paneEdge,
    Color? switchTrackOff,
    Color? checkboxBorder,
    Color? lineCommand,
    Color? writingHint,
    Color? cardTitle,
    Color? accentText,
    Color? pageBorder,
    Color? textDivider,
    Color? switchThumb,
    Color? wellBackground,
    Color? segmentSelected,
    Color? shadow,
    Color? accent,
    Color? onAccent,
    Color? codeKeyword,
    Color? codeString,
    Color? codeNumber,
    Color? codeBuiltIn,
    Color? codePanel,
    Color? codeChip,
    Color? railInk,
    Color? quoteBar,
    List<Color>? tagCards,
    List<Color>? tagDots,
    bool? increasedContrast,
    double? translucency,
    double? paperTranslucency,
  }) => CalcPalette(
    number: number ?? this.number,
    keyword: keyword ?? this.keyword,
    unit: unit ?? this.unit,
    currency: currency ?? this.currency,
    function: function ?? this.function,
    variable: variable ?? this.variable,
    operator: operator ?? this.operator,
    comment: comment ?? this.comment,
    chipNumber: chipNumber ?? this.chipNumber,
    chipCurrency: chipCurrency ?? this.chipCurrency,
    chipUnit: chipUnit ?? this.chipUnit,
    chipBoolean: chipBoolean ?? this.chipBoolean,
    chipOther: chipOther ?? this.chipOther,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
    separator: separator ?? this.separator,
    sidebarBackground: sidebarBackground ?? this.sidebarBackground,
    editorBackground: editorBackground ?? this.editorBackground,
    gutterBackground: gutterBackground ?? this.gutterBackground,
    surfaceBackground: surfaceBackground ?? this.surfaceBackground,
    controlBackground: controlBackground ?? this.controlBackground,
    controlBorder: controlBorder ?? this.controlBorder,
    selectedBackground: selectedBackground ?? this.selectedBackground,
    selectedBorder: selectedBorder ?? this.selectedBorder,
    selection: selection ?? this.selection,
    hover: hover ?? this.hover,
    paperFiber: paperFiber ?? this.paperFiber,
    paperRuling: paperRuling ?? this.paperRuling,
    railBackground: railBackground ?? this.railBackground,
    railBorder: railBorder ?? this.railBorder,
    tonalBackground: tonalBackground ?? this.tonalBackground,
    tonalForeground: tonalForeground ?? this.tonalForeground,
    tonalKeyBackground: tonalKeyBackground ?? this.tonalKeyBackground,
    tonalKeyText: tonalKeyText ?? this.tonalKeyText,
    keycapBackground: keycapBackground ?? this.keycapBackground,
    keycapBorder: keycapBorder ?? this.keycapBorder,
    keycapText: keycapText ?? this.keycapText,
    scrim: scrim ?? this.scrim,
    resultPillBackground: resultPillBackground ?? this.resultPillBackground,
    resultPillText: resultPillText ?? this.resultPillText,
    totalPillBackground: totalPillBackground ?? this.totalPillBackground,
    totalPillText: totalPillText ?? this.totalPillText,
    clay: clay ?? this.clay,
    clayText: clayText ?? this.clayText,
    textHeading: textHeading ?? this.textHeading,
    textSubheading: textSubheading ?? this.textSubheading,
    textMuted: textMuted ?? this.textMuted,
    textDescription: textDescription ?? this.textDescription,
    cardBackground: cardBackground ?? this.cardBackground,
    paneEdge: paneEdge ?? this.paneEdge,
    switchTrackOff: switchTrackOff ?? this.switchTrackOff,
    checkboxBorder: checkboxBorder ?? this.checkboxBorder,
    lineCommand: lineCommand ?? this.lineCommand,
    writingHint: writingHint ?? this.writingHint,
    cardTitle: cardTitle ?? this.cardTitle,
    accentText: accentText ?? this.accentText,
    pageBorder: pageBorder ?? this.pageBorder,
    textDivider: textDivider ?? this.textDivider,
    switchThumb: switchThumb ?? this.switchThumb,
    wellBackground: wellBackground ?? this.wellBackground,
    segmentSelected: segmentSelected ?? this.segmentSelected,
    shadow: shadow ?? this.shadow,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    codeKeyword: codeKeyword ?? this.codeKeyword,
    codeString: codeString ?? this.codeString,
    codeNumber: codeNumber ?? this.codeNumber,
    codeBuiltIn: codeBuiltIn ?? this.codeBuiltIn,
    codePanel: codePanel ?? this.codePanel,
    codeChip: codeChip ?? this.codeChip,
    railInk: railInk ?? this.railInk,
    quoteBar: quoteBar ?? this.quoteBar,
    tagCards: tagCards ?? this.tagCards,
    tagDots: tagDots ?? this.tagDots,
    increasedContrast: increasedContrast ?? this.increasedContrast,
    translucency: translucency ?? this.translucency,
    paperTranslucency: paperTranslucency ?? this.paperTranslucency,
  );

  @override
  CalcPalette lerp(ThemeExtension<CalcPalette>? other, double t) {
    if (other is! CalcPalette) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return CalcPalette(
      number: mix(number, other.number),
      keyword: mix(keyword, other.keyword),
      unit: mix(unit, other.unit),
      currency: mix(currency, other.currency),
      function: mix(function, other.function),
      variable: mix(variable, other.variable),
      operator: mix(operator, other.operator),
      comment: mix(comment, other.comment),
      chipNumber: mix(chipNumber, other.chipNumber),
      chipCurrency: mix(chipCurrency, other.chipCurrency),
      chipUnit: mix(chipUnit, other.chipUnit),
      chipBoolean: mix(chipBoolean, other.chipBoolean),
      chipOther: mix(chipOther, other.chipOther),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textTertiary: mix(textTertiary, other.textTertiary),
      separator: mix(separator, other.separator),
      sidebarBackground: mix(sidebarBackground, other.sidebarBackground),
      editorBackground: mix(editorBackground, other.editorBackground),
      gutterBackground: mix(gutterBackground, other.gutterBackground),
      surfaceBackground: mix(surfaceBackground, other.surfaceBackground),
      controlBackground: mix(controlBackground, other.controlBackground),
      controlBorder: mix(controlBorder, other.controlBorder),
      selectedBackground: mix(selectedBackground, other.selectedBackground),
      selectedBorder: mix(selectedBorder, other.selectedBorder),
      selection: mix(selection, other.selection),
      hover: mix(hover, other.hover),
      paperFiber: mix(paperFiber, other.paperFiber),
      paperRuling: mix(paperRuling, other.paperRuling),
      railBackground: mix(railBackground, other.railBackground),
      railBorder: mix(railBorder, other.railBorder),
      tonalBackground: mix(tonalBackground, other.tonalBackground),
      tonalForeground: mix(tonalForeground, other.tonalForeground),
      tonalKeyBackground: mix(tonalKeyBackground, other.tonalKeyBackground),
      tonalKeyText: mix(tonalKeyText, other.tonalKeyText),
      keycapBackground: mix(keycapBackground, other.keycapBackground),
      keycapBorder: mix(keycapBorder, other.keycapBorder),
      keycapText: mix(keycapText, other.keycapText),
      scrim: mix(scrim, other.scrim),
      resultPillBackground: mix(
        resultPillBackground,
        other.resultPillBackground,
      ),
      resultPillText: mix(resultPillText, other.resultPillText),
      totalPillBackground: mix(totalPillBackground, other.totalPillBackground),
      totalPillText: mix(totalPillText, other.totalPillText),
      clay: mix(clay, other.clay),
      clayText: mix(clayText, other.clayText),
      textHeading: mix(textHeading, other.textHeading),
      textSubheading: mix(textSubheading, other.textSubheading),
      textMuted: mix(textMuted, other.textMuted),
      textDescription: mix(textDescription, other.textDescription),
      cardBackground: mix(cardBackground, other.cardBackground),
      paneEdge: mix(paneEdge, other.paneEdge),
      switchTrackOff: mix(switchTrackOff, other.switchTrackOff),
      checkboxBorder: mix(checkboxBorder, other.checkboxBorder),
      lineCommand: mix(lineCommand, other.lineCommand),
      writingHint: mix(writingHint, other.writingHint),
      cardTitle: mix(cardTitle, other.cardTitle),
      accentText: mix(accentText, other.accentText),
      pageBorder: mix(pageBorder, other.pageBorder),
      textDivider: mix(textDivider, other.textDivider),
      switchThumb: mix(switchThumb, other.switchThumb),
      wellBackground: mix(wellBackground, other.wellBackground),
      segmentSelected: mix(segmentSelected, other.segmentSelected),
      shadow: mix(shadow, other.shadow),
      accent: mix(accent, other.accent),
      onAccent: mix(onAccent, other.onAccent),
      codeKeyword: mix(codeKeyword, other.codeKeyword),
      codeString: mix(codeString, other.codeString),
      codeNumber: mix(codeNumber, other.codeNumber),
      codeBuiltIn: mix(codeBuiltIn, other.codeBuiltIn),
      codePanel: mix(codePanel, other.codePanel),
      codeChip: mix(codeChip, other.codeChip),
      railInk: mix(railInk, other.railInk),
      quoteBar: mix(quoteBar, other.quoteBar),
      tagCards: [
        for (var i = 0; i < tagCards.length; i++)
          mix(tagCards[i], other.tagCards[i]),
      ],
      tagDots: [
        for (var i = 0; i < tagDots.length; i++)
          mix(tagDots[i], other.tagDots[i]),
      ],
      increasedContrast: t < 0.5 ? increasedContrast : other.increasedContrast,
      translucency: translucency + (other.translucency - translucency) * t,
      paperTranslucency:
          paperTranslucency + (other.paperTranslucency - paperTranslucency) * t,
    );
  }
}

/// Editor metrics shared by the text field, its measurer and the gutter.
/// Any mismatch between these three shows up as misaligned results, so they
/// are defined exactly once.
class EditorMetrics {
  const EditorMetrics._();

  /// Whether the note is laid out as Riverbank's page: a 680px column under
  /// a title with its meta row, headings with room above them, and rows of
  /// [lineHeight] that may grow. Phones keep their own structure.
  static bool get page => !AppPlatform.isMobile;

  /// How far in a quote's words start on the page, past its 3px bar and the
  /// 14px after it.
  static const double quoteIndent = 17;

  /// One row of writing: Paper's 28px line, and 27pt on a phone.
  static double get lineHeight => AppPlatform.isMobile ? 27 : 28;

  /// The writing column on the page. A window narrower than this plus
  /// [padding] gives the column what it has.
  static const double columnWidth = 680;

  /// The note's first line, its title: under twice the writing's size and a
  /// step lighter than a heading's weight, so it names the note without
  /// shouting over it. The meta row sits under it, 10 below the title and 24
  /// above the body; on a phone the tags take a line of their own.
  static double get titleFontSize => AppPlatform.isMobile ? 28 : 30;
  static double get titleRow => AppPlatform.isMobile ? 36 : 38;
  static const FontWeight titleWeight = FontWeight.w500;
  static const double metaGap = 10;
  static double get metaRow => AppPlatform.isMobile ? 16 + 8 + 22 : 16;
  static const double metaBottom = 24;
  static double get titleReserve => metaGap + metaRow + metaBottom;

  /// A heading against 16px writing: on the page 22, 19 and 17, each in a
  /// 28px line at the bottom of a row of 40 for the first level and 36 below
  /// it, and a step smaller on a phone. Set with proportional leading, nearly
  /// all of what the row adds goes above the words. Deeper levels are the
  /// writing's own size. Every level stays well under the title.
  static double headingFontSize(int level) => switch (level) {
    <= 1 => AppPlatform.isMobile ? 20 : 22,
    2 => AppPlatform.isMobile ? 18 : 19,
    3 => 17,
    _ => 16,
  };
  static double headingRow(int level) => level <= 1 ? 40 : 36;

  /// A fenced code block on the page, Paper's CYZ-0: 24px rows of code in a
  /// panel under a 30px header and its 6px margin, 8px clear of the writing
  /// above, with 10px of panel under the code and 8px clear below.
  static const double codeRow = 24;
  static const double codeGapBefore = 8;
  static const double codeHeader = 30;
  static const double codeHeaderMargin = 6;
  static const double codePanelBottom = 10;
  static const double codeGapAfter = 8;

  /// The rows a hidden opening fence and a hidden closing fence keep.
  static const double codeOpenRow =
      codeGapBefore + codeHeader + codeHeaderMargin;
  static const double codeCloseRow = codePanelBottom + codeGapAfter;

  /// How far a code block's lines start in from the panel's edge: its 1px
  /// border and the 14px of padding inside it, and as much again after.
  static const double codeInset = 15;

  /// A table row on the page, Paper's CYZ-0: 36px and the 1px rule under it.
  static const double tableRow = 37;

  /// How far Paper's link chip reaches before the address it holds: 8px, a
  /// 14px link icon and 6px, then after it 12px. And how far the pill under
  /// inline code reaches past its words.
  static const double linkChipLead = 28;
  static const double linkChipTrail = 12;
  static const double linkChipIcon = 14;
  static const double codeChipReach = 6;

  static const EdgeInsets padding = EdgeInsets.symmetric(
    horizontal: 28,
    vertical: 20,
  );
  static const EdgeInsets phonePadding = EdgeInsets.symmetric(
    horizontal: 20,
    vertical: 14,
  );

  /// The editor's text style.
  ///
  /// Every property that affects glyph advances is pinned, including ones
  /// that look redundant. A [TextField] merges this over the Material text
  /// theme, so anything left unset — `letterSpacing` above all — is inherited
  /// and the field renders wider than anything measuring the same string with
  /// this style alone. That difference moves wrap points, and a moved wrap
  /// point puts every result below it on the wrong line.
  static TextStyle textStyle(
    Color color,
    WritingFont font, {
    double editorScale = 1,
  }) {
    final fontSize = font.editorSize * editorScale;
    final rowHeight = lineHeight * editorScale;
    return TextStyle(
      fontFamily: font.fontFamily,
      fontFamilyFallback: font.fontFamilyFallback,
      fontSize: fontSize,
      height: rowHeight / fontSize,
      color: color,
      letterSpacing: 0,
      wordSpacing: 0,
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
      fontVariations: [
        ...font.faceVariations,
        if (color.computeLuminance() > 0.5) const FontVariation('wght', 370),
      ],
      textBaseline: TextBaseline.alphabetic,
      // A calculator column only lines up with tabular figures.
      fontFeatures: const [FontFeature.tabularFigures()],
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  static const double cursorWidth = 1.7;

  /// The caret is drawn to the text, not to the line box.
  ///
  /// [lineHeight] is deliberately generous — it is what gives a note its air,
  /// and what the results gutter aligns to — but a caret filling it overshot
  /// the glyphs by eight pixels above and nine below, which is what made it
  /// read as a slab dropped between the letters rather than a place to type.
  /// Ascender to descender is the job.
  ///
  /// Derived from the font so the three writing faces each get a caret in
  /// proportion to their own size rather than a number tuned for one of them.
  static double cursorHeight(
    WritingFont font, {
    double editorScale = 1,
    TextScaler textScaler = TextScaler.noScaling,
  }) => textScaler.scale(font.editorSize * editorScale) * 1.28;

  /// Width `RenderEditable` reserves beside the text for the caret: a fixed
  /// 1px gap plus the cursor itself. Text wraps inside what is left, so
  /// anything measuring the note has to subtract it or it will place wraps
  /// later than the field does.
  static const double caretMargin = 1.0 + cursorWidth;

  /// The width text actually wraps within, given a field of [fieldWidth].
  static double textLayoutWidth(double fieldWidth) =>
      math.max(0, fieldWidth - caretMargin);

  /// The row geometry of a note.
  ///
  /// Never forced: the title, headings and pictures are taller than a row by
  /// design, and [lineHeight] is only the floor. Results sit on each line's
  /// own last row, measured, so nothing needs rows even.
  static StrutStyle strut(WritingFont font, {double editorScale = 1}) {
    final fontSize = font.editorSize * editorScale;
    final rowHeight = lineHeight * editorScale;
    return StrutStyle(
      fontFamily: font.fontFamily,
      fontFamilyFallback: font.fontFamilyFallback,
      fontSize: fontSize,
      height: rowHeight / fontSize,
      forceStrutHeight: false,
      leading: 0,
    );
  }
}

/// The small radius system shared by controls and surfaces.
///
/// Keeping these steps close makes the app feel friendly without turning
/// every panel into a pill. Borders, never shadows, separate one layer from
/// another. Controls of every kind share one radius: buttons, icon actions,
/// fields and toggles. Menus, floating panels and the cards inside a dialog
/// share the next.
class AppRadii {
  const AppRadii._();

  static const double small = 4;
  static const double compact = 6;
  static const double control = 9;
  static const double surface = 12;
  static const double dialog = 18;
  static const double pill = 999;
}

class AppHairline {
  const AppHairline._();

  /// One physical pixel at every display scale. A fixed 0.5 is crisp only at
  /// 2x and blurs to grey at 1x, 125% and 150%.
  static double of(BuildContext context) =>
      1 / MediaQuery.devicePixelRatioOf(context);
}

/// Control geometry shared by every app surface, resolved per input device.
///
/// This is two apps wearing one codebase: a dense desktop tool whose controls
/// sit at macOS menu-bar scale, and a phone app that has to clear Apple's 44pt
/// and Material's 48dp minimums with glyphs legible at arm's length. One
/// number cannot serve both. A 17px icon in a 40pt bar is correct on a Mac and
/// miniature on a 6.7" phone, which is exactly how the footer read before
/// these tokens existed: the desktop geometry was the only geometry, and touch
/// inherited it whole.
///
/// So every size the chrome uses is named here once and answers to
/// [AppPlatform.hasPointer]. Pointer controls stay compact, but bar-specific
/// roles are allowed to differ: a repeated formatting strip needs more rhythm
/// than a pair of title-bar actions. The touch column is pitched from the iOS
/// HIG and Material 3 rather than scaled down from the desktop.
class AppControlMetrics {
  const AppControlMetrics._();

  /// Fingers, so every target has to clear 44pt and every glyph has to read
  /// without leaning in.
  static bool get _touch => !AppPlatform.hasPointer;

  // ── Tap targets ─────────────────────────────────────────────────────────

  /// The painted extent of an icon action.
  ///
  /// Pointer devices get a compact hover chip barely larger than the glyph,
  /// because a cursor lands where it is aimed. Touch gets 44, Apple's stated
  /// minimum: [iconButtonTapTargetSize] then pads the hit area out to
  /// Material's 48, so the target satisfies both guidelines while the painted
  /// surface stays the size the layout was drawn around.
  static double get iconButtonExtent => _touch ? 44 : 24;

  /// The space an icon action occupies during layout.
  ///
  /// Material expands a 44pt painted touch surface to a 48pt semantic target,
  /// while pointer controls keep their painted and layout extents identical.
  static double get iconButtonSlotExtent => _touch ? 48 : iconButtonExtent;

  /// The painted surface of an action in the persistent bottom bars.
  ///
  /// A footer is read as a strip of tools, not isolated title-bar actions. Its
  /// desktop controls therefore get a 32pt surface: large enough to scan and
  /// acquire without making the low-priority chrome feel touch-sized.
  static double get footerButtonExtent => _touch ? 44 : 32;

  /// Air between adjacent actions in the footer formatting group.
  ///
  /// Touch targets remain contiguous at 44pt so the strip still fits a phone.
  /// A pointer has enough width for a visible 4pt beat between hover surfaces.
  static double get footerButtonGap => _touch ? 0 : 4;

  static MaterialTapTargetSize get iconButtonTapTargetSize =>
      AppPlatform.hasPointer
      ? MaterialTapTargetSize.shrinkWrap
      : MaterialTapTargetSize.padded;

  /// Height of a text button, filled button or outlined button.
  static double get buttonHeight => _touch ? 48 : 36;

  /// Visible breathing room above and below a button label.
  ///
  /// Declared explicitly because the app's compact desktop density otherwise
  /// subtracts from a button's vertical geometry and turns a 32px control into
  /// a cramped 24px one.
  static double get buttonVerticalPadding => _touch ? 12 : 8;

  /// Actions inside a popover, which is tighter than a dialog but still has to
  /// be hittable. Below [iconButtonExtent] on touch only because a popover is
  /// already anchored under the thumb that opened it.
  static double get popoverActionExtent => _touch ? 40 : 26;

  /// Height of a tonal button, and the side of one that is only an icon.
  /// A step under [buttonHeight] on a desktop, because it sits in bars and
  /// headers rather than at the foot of a dialog.
  static double get tonalButtonHeight => _touch ? 44 : 30;

  /// The square a text field reserves for a leading or trailing glyph, and the
  /// padding above and below its text. Together these set how tall a field is:
  /// a search box a thumb can land in cannot be built out of a 28pt slot.
  static double get fieldAdornmentSlot => _touch ? 40 : 28;

  static double get fieldVerticalPadding => _touch ? 13 : 9;

  // ── Bars ────────────────────────────────────────────────────────────────

  /// The title bar. 48 is right for a desktop window whose chrome should
  /// disappear; 56 is the Material app-bar height and leaves a 44pt action
  /// room to breathe above and below.
  static double get toolbarHeight => _touch ? 56 : 48;

  /// The note status bar and its twin at the foot of the sidebar.
  ///
  /// 48 matches the desktop title-bar rhythm while leaving 8pt around a 32pt
  /// footer action. It cannot fit a 44pt touch action, so phones use 56: the
  /// action plus a 6pt gutter on each side.
  static double get footerHeight => _touch ? 56 : 48;

  /// A row in the notes list. Touch carries a full point larger title and
  /// snippet than pointer does, and needs the height to seat them.
  static double get sidebarNoteRowExtent => _touch ? 64 : 54;

  // ── Icon glyphs ─────────────────────────────────────────────────────────
  //
  // The desktop ramp had grown to eight steps between 11 and 21, most of them
  // a pixel apart and none of them named. These five roles cover the same
  // ground, and touch collapses them further into four distinct sizes:
  // [iconControl] and [iconAction] are a pixel apart on a Mac, where that
  // reads as the difference between a gear and a formatting button, and
  // identical on a phone, where it would read as a mistake.

  /// Inline marks set against text: the clock beside a timestamp, the tick in
  /// a result chip.
  static double get iconInline => _touch ? 14 : 12;

  /// Adornments inside a control — a field's search glyph, a row's clear
  /// button, a hover-revealed delete.
  static double get iconAdornment => _touch ? 18 : 14;

  /// Search is visually circular and reads larger than other adornments at
  /// the same box size, so it uses a slightly quieter glyph.
  static double get iconSearch => _touch ? 16 : 14;

  /// A secondary icon that is itself the button.
  static double get iconControl => _touch ? 22 : 16;

  /// A primary icon that is itself the button. The workhorse of every bar.
  static double get iconAction => _touch ? 22 : 16;

  /// Primary and secondary glyphs inside the roomier footer controls.
  ///
  /// These sit one or two points above title-bar glyphs so the repeated strip
  /// reads at the same visual weight as the surrounding editor and sidebar.
  static double get footerIconAction => _touch ? 22 : 18;
  static double get footerIconControl => _touch ? 22 : 18;

  /// Feature icons that head a pane or an empty state.
  static double get iconFeature => _touch ? 26 : 20;

  /// What an `Icon` with no size of its own gets, via the theme.
  static double get iconDefault => _touch ? 22 : 18;

  /// The brand mark in the toolbar and sidebar lockups.
  static double get wordmarkMark => _touch ? 22 : 19;

  /// The same mark at empty-state size.
  static double get wordmarkMarkLarge => _touch ? 56 : 48;

  /// A member's default avatar in the title bar.
  ///
  /// Small enough that three of them and a name still fit beside the lockup
  /// on a phone, large enough that a single initial reads at arm's length.
  static double get avatarExtent => _touch ? 26 : 22;

  // ── Text scaling ────────────────────────────────────────────────────────

  /// A fixed-height bar sized for the default text scale clips its own label
  /// the moment the user raises Dynamic Type, which is the single most common
  /// accessibility failure in a Flutter app that hardcodes bar heights. Bars
  /// grow with the scale instead.
  ///
  /// Capped at 1.4: past that the chrome would eat the note it exists to
  /// frame, and the label inside is already ellipsised rather than truncated.
  static double scaleBar(BuildContext context, double height) =>
      height * MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.4);
}

/// The app's type ramp, in the same two densities as [AppControlMetrics].
///
/// Every size the chrome renders comes from here rather than from a literal at
/// the call site. macOS keeps its compact 10–16px desktop rhythm. Windows gets
/// a slightly larger optical column because type there is commonly rasterised
/// at 96dpi: the old 10.5px subtitles lost both shape and hierarchy. The
/// touch column is pitched to iOS Dynamic Type at its default Large setting,
/// where 17 is body and 13 is the smallest size Apple sets anything a user is
/// meant to actually read.
///
/// As with the icons, touch is the shorter ramp on purpose: desktop steps half
/// a pixel apart collapse into one touch size, because they were never telling
/// the reader anything at that distance.
class AppTypeScale {
  const AppTypeScale._();

  static bool get _touch => !AppPlatform.hasPointer;
  static bool get _windows => AppPlatform.isWindows;

  /// The smallest legible annotation: an uppercase section label, the key
  /// chip in a tonal button. 10.5 is a real size on a Mac but too fine on a
  /// typical Windows display and unreadable on a phone held at arm's length,
  /// so each gets a larger floor suited to its viewing distance and
  /// rasterisation.
  static double get micro => _touch
      ? 13
      : _windows
      ? 12
      : 11;

  /// A keycap's legend: ⌘F, esc. Mono, and a half point over [micro] on a
  /// Mac, where the keycap sits beside 13pt controls and has to read as a
  /// key rather than a speck.
  static double get keycap => _touch
      ? 13
      : _windows
      ? 12
      : 11;

  /// The names under the spaces rail's tiles, and the streak's run of days.
  /// A step under [caption], because each sits under its own icon rather
  /// than being read on its own.
  static double get railLabel => _touch
      ? 13
      : _windows
      ? 12
      : 11;

  /// The figure in a count badge, such as the invitations on Shared. Smaller
  /// than [micro], because it is bold, it sits in a coloured dot, and it is
  /// never more than two digits.
  static double get badge => _touch
      ? 11
      : _windows
      ? 11
      : 10;

  /// Metadata, list snippets, the helper line under a control.
  static double get caption => _touch
      ? 13
      : _windows
      ? 13
      : 12;

  /// Dense secondary copy that is still read as a sentence.
  static double get small => _touch
      ? 14
      : _windows
      ? 13
      : 12;

  /// Running paragraph copy inside dialogs and panes.
  static double get body => _touch
      ? 15
      : _windows
      ? 14
      : 13;

  /// A calculation's result: its pill at the end of the line, or a figure in
  /// a phone's results column.
  ///
  /// Its own step rather than [body], because it is monospace figures set
  /// against the writing rather than prose. Touch gains what a phone's column
  /// can actually seat without pushing the writing area below half the screen.
  static double get result => _touch ? 14 : 13;

  /// Control labels: buttons, list rows, fields, menu items.
  static double get control => _touch
      ? 15
      : _windows
      ? 14
      : 13;

  /// Section titles, the app-bar title, an empty state's first line.
  static double get title => _touch
      ? 17
      : _windows
      ? 16
      : 15;

  /// Dialog titles — the largest step in ordinary chrome.
  static double get heading => _touch
      ? 20
      : _windows
      ? 19
      : 16;

  /// The name of the space the notes list is showing, over the list: the
  /// window's own heading, set in Shantell Sans.
  static double get spaceTitle => _touch
      ? 20
      : _windows
      ? 18
      : 17;

  /// The brand lockup, which is set in its own face and carries its own
  /// optical size a half point off [title].
  static double get wordmark => _touch
      ? 17
      : _windows
      ? 16
      : 15;

  /// The lockup on the empty state, the one display-sized thing in the app.
  static double get display => _touch ? 34 : 32;
}

/// The two faces the interface is set in, bundled so that every platform
/// renders the same letters. The writing surface has its own: see
/// [WritingFont].
class AppFonts {
  const AppFonts._();

  /// Every control and label: menus, buttons, fields, lists.
  static const String ui = 'Figtree';

  /// A note's title in the default writing font.
  static const String title = 'Newsreader';

  /// Figures that have to line up and keys that have to look like keys:
  /// calculation results and keycaps.
  static const String mono = 'Geist Mono';

  /// What draws the scripts and symbols Figtree does not have: the system's
  /// own interface face first.
  static List<String> get uiFallback => [
    AppPlatform.uiFontFamily,
    ...AppPlatform.uiFontFallback,
  ];

  /// The same for Geist Mono, which has no ⌘ or ⌥ of its own.
  static const List<String> monoFallback = AppPlatform.monoFontFallback;
}

class KapyTheme {
  const KapyTheme._();

  /// A filled control's background in each state: [fill] at rest, with a
  /// little of its [ink] laid over it when hovered or focused and a little
  /// more while pressed, and [disabled] when it has nothing to do. The accent
  /// button and the tonal one share it, so both answer the pointer alike.
  static WidgetStateProperty<Color> fillStates(
    Color fill, {
    required Color ink,
    required Color disabled,
  }) => WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.disabled)) return disabled;
    if (states.contains(WidgetState.pressed)) {
      return Color.alphaBlend(ink.withValues(alpha: 0.13), fill);
    }
    if (states.contains(WidgetState.hovered) ||
        states.contains(WidgetState.focused)) {
      return Color.alphaBlend(ink.withValues(alpha: 0.07), fill);
    }
    return fill;
  });

  static ThemeData light({
    AppTheme theme = AppTheme.riverbank,
    bool increaseContrast = false,
    bool transparency = false,
    double amount = defaultGlassAmount,
  }) => _themed(
    palette(theme, Brightness.light),
    increaseContrast: increaseContrast,
    transparency: transparency,
    amount: amount,
  );
  static ThemeData dark({
    AppTheme theme = AppTheme.riverbank,
    bool increaseContrast = false,
    bool transparency = false,
    double amount = defaultGlassAmount,
  }) => _themed(
    palette(theme, Brightness.dark),
    increaseContrast: increaseContrast,
    transparency: transparency,
    amount: amount,
  );

  static ThemeData _themed(
    CalcPalette palette, {
    required bool increaseContrast,
    required bool transparency,
    required double amount,
  }) {
    final colours = increaseContrast
        ? palette.withIncreasedContrast()
        : palette;
    return _build(transparency ? glassPalette(colours, amount) : colours);
  }

  /// [theme]'s palette for [brightness]. Midnight has no light side of its
  /// own: by day it is Riverbank light.
  static CalcPalette palette(AppTheme theme, Brightness brightness) {
    final (dark, light) = _palettes[theme]!;
    return brightness == Brightness.dark ? dark : light;
  }

  /// What a window wears for these choices at [wallClock], the time on the
  /// clock the app shows: [theme]'s two sides in [mode], or, while At night
  /// covers the hour, the night theme's dark side whatever the mode.
  static WindowLook window({
    required AppearanceMode mode,
    required AppTheme theme,
    required NightTheme night,
    required DateTime wallClock,
    bool increaseContrast = false,
    bool transparency = false,
    double amount = defaultGlassAmount,
  }) {
    final atNight = night.activeAt(wallClock);
    return (
      light: light(
        theme: theme,
        increaseContrast: increaseContrast,
        transparency: transparency,
        amount: amount,
      ),
      dark: dark(
        theme: atNight ? night.theme : theme,
        increaseContrast: increaseContrast,
        transparency: transparency,
        amount: amount,
      ),
      mode: atNight ? ThemeMode.dark : mode.themeMode,
    );
  }

  static final Map<AppTheme, (CalcPalette, CalcPalette)> _palettes = {
    AppTheme.riverbank: (darkPalette, lightPalette),
    AppTheme.graphite: (_fromTones(_graphiteDark), _fromTones(_graphiteLight)),
    AppTheme.midnight: (_fromTones(_midnightDark), lightPalette),
    AppTheme.dusk: (_fromTones(_duskDark), _fromTones(_duskLight)),
    AppTheme.lamplight: (
      _fromTones(_lamplightDark),
      _fromTones(_lamplightLight),
    ),
    AppTheme.fjord: (_fromTones(_fjordDark), _fromTones(_fjordLight)),
  };

  /// Riverbank dark: warm charcoal, cream ink and a sage accent.
  ///
  /// The window is a step behind the page and the rail a step behind the
  /// window, so the note is the clearest layer. Nothing light is used for an
  /// edge or a shadow: borders and dividers are warm darks, and buttons are
  /// flat sage tints. In a calculation the names and figures stay in the
  /// note's ink, and only the operators and units step back.
  static const CalcPalette darkPalette = CalcPalette(
    number: Color(0xFFE2DCCF),
    keyword: Color(0xFFE2DCCF),
    unit: Color(0xFFA09A8C),
    currency: Color(0xFFA09A8C),
    function: Color(0xFFE2DCCF),
    variable: Color(0xFFE2DCCF),
    operator: Color(0xFFA09A8C),
    comment: Color(0xFFA09A8C),
    chipNumber: Color(0xFFB3C79C),
    chipCurrency: Color(0xFFB3C79C),
    chipUnit: Color(0xFFB3C79C),
    chipBoolean: Color(0xFFB3C79C),
    chipOther: Color(0xFFB3C79C),
    textPrimary: Color(0xFFE2DCCF),
    textSecondary: Color(0xFFA29A8A),
    textTertiary: Color(0xFFA09A8C),
    separator: Color(0xFF35312B),
    sidebarBackground: Color(0xFF1C1A17),
    editorBackground: Color(0xFF23201C),
    gutterBackground: Color(0xFF23201C),
    surfaceBackground: Color(0xFF23201C),
    controlBackground: Color(0xFF2A2722),
    controlBorder: Color(0xFF312D27),
    selectedBackground: Color(0xFF36322B),
    selectedBorder: Color(0xFF7D9468),
    selection: Color(0x4D7D9468),
    hover: Color(0xFF2E2A25),
    paperFiber: Color(0x00000000),
    paperRuling: Color(0xFF2E2A25),
    railBackground: Color(0xFF171512),
    railBorder: Color(0x0FE2DCCF),
    tonalBackground: Color(0xFF2E3828),
    tonalForeground: Color(0xFFC2D6AC),
    tonalKeyBackground: Color(0xFF3A4733),
    tonalKeyText: Color(0xFFA9C08F),
    keycapBackground: Color(0xFF2B2823),
    keycapBorder: Color(0xFF36322B),
    keycapText: Color(0xFFA29A8A),
    scrim: Color(0xB30B0A09),
    resultPillBackground: Color(0xFF2B3326),
    resultPillText: Color(0xFFB3C79C),
    totalPillBackground: Color(0xFF7D9468),
    totalPillText: Color(0xFF1C1A17),
    clay: Color(0xFFCF7A57),
    clayText: Color(0xFFE0A285),
    textHeading: Color(0xFFDAD4C7),
    textSubheading: Color(0xFFD3CCBE),
    textMuted: Color(0xFFB2AA9A),
    textDescription: Color(0xFF9C9485),
    cardBackground: Color(0xFF292621),
    paneEdge: Color(0xFF2C2924),
    switchTrackOff: Color(0xFF3A362F),
    checkboxBorder: Color(0xFF645D51),
    lineCommand: Color(0xFF6B6458),
    writingHint: Color(0xFF4F4A42),
    cardTitle: Color(0xFFD9D3C6),
    accentText: Color(0xFF9DB384),
    pageBorder: Color(0xFF2E2A25),
    textDivider: Color(0xFF554F47),
    switchThumb: Color(0xFFE2DCCF),
    wellBackground: Color(0xFF1F1D19),
    segmentSelected: Color(0xFF35312B),
    shadow: Color(0xFF000000),
    accent: Color(0xFF7D9468),
    onAccent: Color(0xFF1C1A17),
    codeKeyword: Color(0xFFCF7A57),
    codeString: Color(0xFFB3C79C),
    codeNumber: Color(0xFFD4B26A),
    codeBuiltIn: Color(0xFF8FB3B0),
    codePanel: Color(0xFF1E1C19),
    codeChip: Color(0xFF2E2A25),
    railInk: Color(0xFF8F8778),
    quoteBar: Color(0xFF4A453D),
    tagCards: [
      Color(0xFF393425),
      Color(0xFF372B26),
      Color(0xFF2B3125),
      Color(0xFF273133),
      Color(0xFF25332A),
      Color(0xFF282D38),
      Color(0xFF322A37),
      Color(0xFF38292D),
    ],
    tagDots: [
      Color(0xFFC9A447),
      Color(0xFFC4734F),
      Color(0xFF8F9B55),
      Color(0xFF4F9A9B),
      Color(0xFF5FA071),
      Color(0xFF6D88BE),
      Color(0xFF9C77B4),
      Color(0xFFC46F84),
    ],
  );

  /// Riverbank light: warm paper, ink-brown text and a deeper sage.
  ///
  /// The dark palette turned over, from the light page in Paper: the page is
  /// the lightest layer, the window a step behind it and the rail a step
  /// behind that. Edges are warm tints rather than grey lines, shadows come
  /// from the ink at low alpha, and sage and clay deepen so that what sits on
  /// them keeps its contrast.
  static const CalcPalette lightPalette = CalcPalette(
    number: Color(0xFF2A2620),
    keyword: Color(0xFF2A2620),
    unit: Color(0xFF666054),
    currency: Color(0xFF666054),
    function: Color(0xFF2A2620),
    variable: Color(0xFF2A2620),
    operator: Color(0xFF666054),
    comment: Color(0xFF666054),
    chipNumber: Color(0xFF445A2F),
    chipCurrency: Color(0xFF445A2F),
    chipUnit: Color(0xFF445A2F),
    chipBoolean: Color(0xFF445A2F),
    chipOther: Color(0xFF445A2F),
    textPrimary: Color(0xFF2A2620),
    textSecondary: Color(0xFF666054),
    textTertiary: Color(0xFF666054),
    separator: Color(0xFFD9D2C1),
    sidebarBackground: Color(0xFFF3EFE4),
    editorBackground: Color(0xFFFCFAF4),
    gutterBackground: Color(0xFFFCFAF4),
    surfaceBackground: Color(0xFFFCFAF4),
    controlBackground: Color(0xFFEFEADD),
    controlBorder: Color(0xFFE2DCCB),
    selectedBackground: Color(0xFFE2DCCB),
    selectedBorder: Color(0xFF56703C),
    selection: Color(0x3356703C),
    hover: Color(0xFFEBE5D6),
    // The optional notepad style keeps a barely visible fibre. Plain remains
    // the default, and dark paper stays completely clean.
    paperFiber: Color(0x085B5148),
    paperRuling: Color(0xFFE6E0D0),
    railBackground: Color(0xFFECE6D8),
    railBorder: Color(0x0F2A2620),
    tonalBackground: Color(0xFFE6ECDB),
    tonalForeground: Color(0xFF445A2F),
    tonalKeyBackground: Color(0xFFD3DEC2),
    tonalKeyText: Color(0xFF56703C),
    keycapBackground: Color(0xFFEFEADD),
    keycapBorder: Color(0xFFD9D2C1),
    keycapText: Color(0xFF666054),
    scrim: Color(0x332A2620),
    resultPillBackground: Color(0xFFE3EBD8),
    resultPillText: Color(0xFF445A2F),
    totalPillBackground: Color(0xFF56703C),
    totalPillText: Color(0xFFFCFAF4),
    clay: Color(0xFFD0663B),
    clayText: Color(0xFFB5552F),
    textHeading: Color(0xFF2A2620),
    textSubheading: Color(0xFF3A352D),
    textMuted: Color(0xFF4A453B),
    textDescription: Color(0xFF666054),
    cardBackground: Color(0xFFF6F2E8),
    paneEdge: Color(0xFFE2DCCB),
    switchTrackOff: Color(0xFFDCD5C4),
    checkboxBorder: Color(0xFFB1A996),
    lineCommand: Color(0xFFA39B8A),
    writingHint: Color(0xFFBDB6A6),
    cardTitle: Color(0xFF2A2620),
    accentText: Color(0xFF56703C),
    pageBorder: Color(0xFFE6E0D0),
    textDivider: Color(0xFFBDB6A6),
    switchThumb: Color(0xFFFCFAF4),
    wellBackground: Color(0xFFEFEADD),
    segmentSelected: Color(0xFFFCFAF4),
    shadow: Color(0x662A2620),
    accent: Color(0xFF56703C),
    onAccent: Color(0xFFFCFAF4),
    codeKeyword: Color(0xFFB5552F),
    codeString: Color(0xFF56703C),
    codeNumber: Color(0xFF8A6A1E),
    codeBuiltIn: Color(0xFF3F7470),
    codePanel: Color(0xFFF6F2E8),
    codeChip: Color(0xFFEFEADD),
    railInk: Color(0xFF666054),
    quoteBar: Color(0xFFD0C8B5),
    tagCards: [
      Color(0xFFF4EBC8),
      Color(0xFFF2E0D4),
      Color(0xFFE6EBD5),
      Color(0xFFDCE8E6),
      Color(0xFFD9EAD9),
      Color(0xFFDEE4F0),
      Color(0xFFEADFEC),
      Color(0xFFF3DDE2),
    ],
    tagDots: [
      Color(0xFFA88424),
      Color(0xFFB5643F),
      Color(0xFF6F7B38),
      Color(0xFF3D8586),
      Color(0xFF4B8A5D),
      Color(0xFF5873A8),
      Color(0xFF8A64A3),
      Color(0xFFB25C72),
    ],
  );

  /// Transparency mode.
  ///
  /// The whole window becomes a pane of glass: the desktop shows through the
  /// paper as well as the chrome. What keeps a paragraph readable over a
  /// wallpaper is not the tint Flutter paints but the blur the window puts
  /// behind it — macOS' visual effect material, Windows' acrylic — which
  /// turns whatever is there into soft colour with no edges for the type to
  /// fight. The tints here only need enough body to hold the text's contrast
  /// steady from one wallpaper to the next. Dialogs, menus and tooltips keep
  /// their usual opacity: they sit over the note, and have to hide it.
  ///
  /// [amount] is the setting's slider, 0 to 1. Even 0 is properly see-through
  /// — the desktop reads clearly through the note — and 1 leaves barely a
  /// film, the type standing on the window's blur with almost nothing behind
  /// it. Light carries more body than dark at every point, because dark text
  /// over a bright, busy wallpaper loses contrast sooner than light text over
  /// a dark one. The paper fibres go in light: a texture that reads as stock
  /// on solid paper reads as noise on glass.
  ///
  /// The blur is what makes the far end usable at all. A wallpaper is turned
  /// into soft colour with no edges for the letters to fight, so a film this
  /// thin still separates them from it. Somebody who wants the note to sit
  /// solid on the desktop turns the mode off; this scale is for people who
  /// want it to disappear into one.
  static CalcPalette glassPalette(CalcPalette base, double amount) {
    final t = amount.clamp(0.0, 1.0);
    final dark = base.brightness == Brightness.dark;
    final paper = dark ? _lerp(0.34, 0.05, t) : _lerp(0.44, 0.1, t);
    // The chrome is a step thinner than the paper: a row of buttons needs
    // less body under it than a paragraph does, and the difference is what
    // reads as layers rather than one flat tint. Proportional rather than a
    // fixed step, so the thin end of the scale cannot drive it through zero.
    final chrome = paper * 0.84;
    return base.copyWith(
      translucency: chrome,
      paperTranslucency: paper,
      paperFiber: dark ? null : const Color(0x00000000),
    );
  }

  /// Where the slider starts: see [LayoutPrefs.defaultTransparencyAmount].
  static const double defaultGlassAmount = 0;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static final CalcPalette translucentDarkPalette = glassPalette(
    darkPalette,
    defaultGlassAmount,
  );

  static final CalcPalette translucentLightPalette = glassPalette(
    lightPalette,
    defaultGlassAmount,
  );

  // The other five themes, by the roles Themes r2 names (p-N-0). Each value
  // is the spec's, except rose, the eighth tag colour, which the spec leaves
  // out: it moves the way plum and rust move in that theme, and stays at
  // least ΔE 15 from every other tag. Tags are in tag order: mustard, rust,
  // olive, teal, sage, slate, plum and rose.

  static const _graphiteDark = _Tones(
    canvas: Color(0xFF151515),
    rail: Color(0xFF111111),
    page: Color(0xFF1B1B1B),
    raised: Color(0xFF252525),
    card: Color(0xFF212121),
    key: Color(0xFF242424),
    keyEdge: Color(0xFF2F2F2F),
    border: Color(0xFF2A2A2A),
    hair: Color(0xFF272727),
    menuEdge: Color(0xFF2E2E2E),
    divider: Color(0xFF505050),
    switchOff: Color(0xFF333333),
    text: Color(0xFFE6E6E6),
    head: Color(0xFFDEDEDE),
    subhead: Color(0xFFD7D7D7),
    cardTitle: Color(0xFFDDDDDD),
    muted: Color(0xFFBEBEBE),
    sec: Color(0xFFA3A3A3),
    icon: Color(0xFF929292),
    faint: Color(0xFF8E8E8E),
    dim: Color(0xFF5A5A5A),
    dim2: Color(0xFF555555),
    dim3: Color(0xFF434343),
    box: Color(0xFF4B4B4B),
    accent: Color(0xFFC2C2C2),
    link: Color(0xFFB3C2D6),
    chipText: Color(0xFFCBD2DC),
    tb: Color(0xFF2D2D2D),
    tf: Color(0xFFE2E2E2),
    tkBg: Color(0xFF4B4B4B),
    tkText: Color(0xFFD0D0D0),
    onAccent: Color(0xFF151515),
    clay: Color(0xFFD58B63),
    codeBg: Color(0xFF292929),
    tSage: Color(0xFF343434),
    tags: [
      Color(0xFF342F23),
      Color(0xFF352924),
      Color(0xFF2C2E24),
      Color(0xFF232E2E),
      Color(0xFF252F28),
      Color(0xFF282C36),
      Color(0xFF2E2A33),
      Color(0xFF34282C),
    ],
    dots: [
      Color(0xFFC2A04E),
      Color(0xFFC77B55),
      Color(0xFF8F9B55),
      Color(0xFF4F9A9B),
      Color(0xFF5FA071),
      Color(0xFF6F8FD0),
      Color(0xFF9C7FB8),
      Color(0xFFC6778B),
    ],
  );

  static const _graphiteLight = _Tones(
    canvas: Color(0xFFF2F2F2),
    rail: Color(0xFFEBEBEB),
    page: Color(0xFFFFFFFF),
    raised: Color(0xFFF0F0F0),
    card: Color(0xFFF7F7F7),
    key: Color(0xFFF6F6F6),
    keyEdge: Color(0xFFE9E9E9),
    border: Color(0xFFEFEFEF),
    hair: Color(0xFFF2F2F2),
    menuEdge: Color(0xFFEAEAEA),
    divider: Color(0xFFC5C5C5),
    switchOff: Color(0xFFE4E4E4),
    text: Color(0xFF1E1E1E),
    head: Color(0xFF262626),
    subhead: Color(0xFF2C2C2C),
    cardTitle: Color(0xFF272727),
    muted: Color(0xFF434343),
    sec: Color(0xFF5C5C5C),
    icon: Color(0xFF676767),
    faint: Color(0xFF6A6A6A),
    dim: Color(0xFFADADAD),
    dim2: Color(0xFFB5B5B5),
    dim3: Color(0xFFCBCBCB),
    box: Color(0xFFC0C0C0),
    accent: Color(0xFF3A3A3A),
    link: Color(0xFF2F5D99),
    chipText: Color(0xFF2B4260),
    tb: Color(0xFFE8E8E8),
    tf: Color(0xFF262626),
    tkBg: Color(0xFFC5C5C5),
    tkText: Color(0xFF313131),
    onAccent: Color(0xFFFFFFFF),
    clay: Color(0xFFB5552E),
    codeBg: Color(0xFFEFEFEF),
    tSage: Color(0xFFE1E1E1),
    tags: [
      Color(0xFFEEEADE),
      Color(0xFFF3E6E0),
      Color(0xFFE9EAE0),
      Color(0xFFDFEBEB),
      Color(0xFFE2ECE5),
      Color(0xFFE4E8F2),
      Color(0xFFEBE6F0),
      Color(0xFFF2E4EA),
    ],
    dots: [
      Color(0xFF8F7420),
      Color(0xFFB0582F),
      Color(0xFF6A7530),
      Color(0xFF2C7778),
      Color(0xFF3E7F50),
      Color(0xFF4A68A6),
      Color(0xFF7A579B),
      Color(0xFFA94E6A),
    ],
  );

  static const _midnightDark = _Tones(
    canvas: Color(0xFF000000),
    rail: Color(0xFF000000),
    page: Color(0xFF000000),
    raised: Color(0xFF151515),
    card: Color(0xFF0F0F0F),
    key: Color(0xFF151515),
    keyEdge: Color(0xFF2E2E2E),
    border: Color(0xFF2A2A2A),
    hair: Color(0xFF1F1F1F),
    menuEdge: Color(0xFF2E2E2E),
    divider: Color(0xFF3C3B39),
    switchOff: Color(0xFF1C1B1A),
    text: Color(0xFFE6E2DA),
    head: Color(0xFFDEDAD2),
    subhead: Color(0xFFD8D4CB),
    cardTitle: Color(0xFFDDD9D1),
    muted: Color(0xFFC1BCB4),
    sec: Color(0xFFA8A39A),
    icon: Color(0xFF959087),
    faint: Color(0xFF908B82),
    dim: Color(0xFF4F4C48),
    dim2: Color(0xFF484641),
    dim3: Color(0xFF32312E),
    box: Color(0xFF3C3A37),
    accent: Color(0xFF8BA374),
    link: Color(0xFFA6BC8E),
    chipText: Color(0xFFB4C99D),
    tb: Color(0xFF1B2416),
    tf: Color(0xFFC2D6AC),
    tkBg: Color(0xFF313D29),
    tkText: Color(0xFFA4BA8D),
    onAccent: Color(0xFF000000),
    clay: Color(0xFFCF7A57),
    codeBg: Color(0xFF10100F),
    tSage: Color(0xFF1C2117),
    tags: [
      Color(0xFF28210E),
      Color(0xFF271710),
      Color(0xFF1D1F11),
      Color(0xFF101F1F),
      Color(0xFF132017),
      Color(0xFF161B26),
      Color(0xFF1F1824),
      Color(0xFF26161B),
    ],
    dots: [
      Color(0xFFC9A447),
      Color(0xFFC4734F),
      Color(0xFF8F9B55),
      Color(0xFF4F9A9B),
      Color(0xFF5FA071),
      Color(0xFF6D88BE),
      Color(0xFF9C77B4),
      Color(0xFFC46F84),
    ],
  );

  static const _duskDark = _Tones(
    canvas: Color(0xFF15151F),
    rail: Color(0xFF111119),
    page: Color(0xFF1A1A26),
    raised: Color(0xFF232330),
    card: Color(0xFF20202C),
    key: Color(0xFF21212D),
    keyEdge: Color(0xFF2B2B37),
    border: Color(0xFF262633),
    hair: Color(0xFF242430),
    menuEdge: Color(0xFF2A2A36),
    divider: Color(0xFF464653),
    switchOff: Color(0xFF2E2E3B),
    text: Color(0xFFC4C2D2),
    head: Color(0xFFBFBDCE),
    subhead: Color(0xFFBBB9CA),
    cardTitle: Color(0xFFBEBCCD),
    muted: Color(0xFFACAABC),
    sec: Color(0xFF9C9AAE),
    icon: Color(0xFF8F8DA2),
    faint: Color(0xFF8C8A9F),
    dim: Color(0xFF595869),
    dim2: Color(0xFF535263),
    dim3: Color(0xFF424150),
    box: Color(0xFF4A4959),
    accent: Color(0xFF9B92C9),
    link: Color(0xFFB2AADA),
    chipText: Color(0xFFBEB7E2),
    tb: Color(0xFF2A2840),
    tf: Color(0xFFC9C3EA),
    tkBg: Color(0xFF413D5B),
    tkText: Color(0xFFB0A8D8),
    onAccent: Color(0xFF15151F),
    clay: Color(0xFFC08A78),
    codeBg: Color(0xFF262632),
    tSage: Color(0xFF2D2C3E),
    tags: [
      Color(0xFF322F30),
      Color(0xFF332A31),
      Color(0xFF2C2D31),
      Color(0xFF262E39),
      Color(0xFF292F35),
      Color(0xFF2A2C3D),
      Color(0xFF2F2B3D),
      Color(0xFF332A36),
    ],
    dots: [
      Color(0xFFBBA468),
      Color(0xFFBE8670),
      Color(0xFF949A6E),
      Color(0xFF6D9FA3),
      Color(0xFF7FA488),
      Color(0xFF8494C2),
      Color(0xFFA88BBE),
      Color(0xFFC58595),
    ],
  );

  static const _duskLight = _Tones(
    canvas: Color(0xFFECEBF2),
    rail: Color(0xFFE5E4EC),
    page: Color(0xFFF4F3F8),
    raised: Color(0xFFE8E7EF),
    card: Color(0xFFEFEEF4),
    key: Color(0xFFECEBF1),
    keyEdge: Color(0xFFE2E1E7),
    border: Color(0xFFE6E5EB),
    hair: Color(0xFFE9E8EE),
    menuEdge: Color(0xFFE3E2E8),
    divider: Color(0xFFC4C3CB),
    switchOff: Color(0xFFDEDDE3),
    text: Color(0xFF3B3A4A),
    head: Color(0xFF3F3E4E),
    subhead: Color(0xFF424051),
    cardTitle: Color(0xFF3F3E4E),
    muted: Color(0xFF4C4B5B),
    sec: Color(0xFF585667),
    icon: Color(0xFF605E70),
    faint: Color(0xFF626072),
    dim: Color(0xFFA4A2AE),
    dim2: Color(0xFFABAAB5),
    dim3: Color(0xFFC1C0C9),
    box: Color(0xFFB7B5C0),
    accent: Color(0xFF5E569A),
    link: Color(0xFF5E569A),
    chipText: Color(0xFF4F4789),
    tb: Color(0xFFE2DFF0),
    tf: Color(0xFF3F3878),
    tkBg: Color(0xFFC8C4DF),
    tkText: Color(0xFF50498B),
    onAccent: Color(0xFFF4F3F8),
    clay: Color(0xFFA65A3A),
    codeBg: Color(0xFFE7E6EC),
    tSage: Color(0xFFDEDBEA),
    tags: [
      Color(0xFFE4DFD8),
      Color(0xFFE8DCDC),
      Color(0xFFDFDFDB),
      Color(0xFFD6DFE4),
      Color(0xFFD9E1DF),
      Color(0xFFD9DDEC),
      Color(0xFFE1DCE9),
      Color(0xFFE7DBE4),
    ],
    dots: [
      Color(0xFF866F25),
      Color(0xFFA55A3A),
      Color(0xFF666F35),
      Color(0xFF2E6F70),
      Color(0xFF3F7A50),
      Color(0xFF3F5FA7),
      Color(0xFF755C93),
      Color(0xFF9E546B),
    ],
  );

  static const _lamplightDark = _Tones(
    canvas: Color(0xFF1A130C),
    rail: Color(0xFF150F09),
    page: Color(0xFF20180F),
    raised: Color(0xFF2A2016),
    card: Color(0xFF261D13),
    key: Color(0xFF292015),
    keyEdge: Color(0xFF342A1D),
    border: Color(0xFF2F2519),
    hair: Color(0xFF2C2217),
    menuEdge: Color(0xFF33291C),
    divider: Color(0xFF554734),
    switchOff: Color(0xFF382D20),
    text: Color(0xFFEBCB9E),
    head: Color(0xFFE6C69A),
    subhead: Color(0xFFE2C296),
    cardTitle: Color(0xFFE6C699),
    muted: Color(0xFFD4B488),
    sec: Color(0xFFC4A47A),
    icon: Color(0xFFAF916A),
    faint: Color(0xFFAA8C66),
    dim: Color(0xFF6C583F),
    dim2: Color(0xFF65523B),
    dim3: Color(0xFF50412D),
    box: Color(0xFF5A4934),
    accent: Color(0xFFC89550),
    link: Color(0xFFDDB173),
    chipText: Color(0xFFE4BD82),
    tb: Color(0xFF3A2A16),
    tf: Color(0xFFEBC891),
    tkBg: Color(0xFF563F22),
    tkText: Color(0xFFD8AC6D),
    onAccent: Color(0xFF1A130C),
    clay: Color(0xFFD9804F),
    codeBg: Color(0xFF2E2519),
    tSage: Color(0xFF392B19),
    tags: [
      Color(0xFF3D3018),
      Color(0xFF3C2618),
      Color(0xFF292717),
      Color(0xFF3A3024),
      Color(0xFF312F1B),
      Color(0xFF32261A),
      Color(0xFF3B2821),
      Color(0xFF3C261C),
    ],
    dots: [
      Color(0xFFE2B94E),
      Color(0xFFD9784A),
      Color(0xFF5F7A45),
      Color(0xFFCDB89A),
      Color(0xFF93AE5C),
      Color(0xFF9A7458),
      Color(0xFFD2808A),
      Color(0xFFDC7D6A),
    ],
  );

  static const _lamplightLight = _Tones(
    canvas: Color(0xFFEFE4CF),
    rail: Color(0xFFE8DCC4),
    page: Color(0xFFF7EEDC),
    raised: Color(0xFFECE0C8),
    card: Color(0xFFF2E7D2),
    key: Color(0xFFEFE6D4),
    keyEdge: Color(0xFFE4DAC9),
    border: Color(0xFFE9E0CE),
    hair: Color(0xFFECE3D1),
    menuEdge: Color(0xFFE5DCCA),
    divider: Color(0xFFC6BBAA),
    switchOff: Color(0xFFE0D6C5),
    text: Color(0xFF3A2A1A),
    head: Color(0xFF3F2E1D),
    subhead: Color(0xFF433220),
    cardTitle: Color(0xFF402F1D),
    muted: Color(0xFF533E28),
    sec: Color(0xFF634B32),
    icon: Color(0xFF6C543D),
    faint: Color(0xFF6E5640),
    dim: Color(0xFFAC9A86),
    dim2: Color(0xFFB3A28E),
    dim3: Color(0xFFC7B9A5),
    box: Color(0xFFBDAE9A),
    accent: Color(0xFF8A5A1E),
    link: Color(0xFF8A5A1E),
    chipText: Color(0xFF744B18),
    tb: Color(0xFFEBD9B6),
    tf: Color(0xFF5E3C12),
    tkBg: Color(0xFFD8C098),
    tkText: Color(0xFF764D19),
    onAccent: Color(0xFFF7EEDC),
    clay: Color(0xFFA84A22),
    codeBg: Color(0xFFEAE0CE),
    tSage: Color(0xFFE7D8C0),
    tags: [
      Color(0xFFE7DABE),
      Color(0xFFEBD5C0),
      Color(0xFFDDD9C2),
      Color(0xFFEBDAC5),
      Color(0xFFE0DDC0),
      Color(0xFFE2D5C2),
      Color(0xFFE9D5C9),
      Color(0xFFEDD3C5),
    ],
    dots: [
      Color(0xFF8A6A12),
      Color(0xFFA84A22),
      Color(0xFF4C6230),
      Color(0xFFA86A40),
      Color(0xFF5C7A24),
      Color(0xFF6B4A30),
      Color(0xFF9A4A5A),
      Color(0xFFA6493D),
    ],
  );

  static const _fjordDark = _Tones(
    canvas: Color(0xFF0F1A1C),
    rail: Color(0xFF0C1517),
    page: Color(0xFF132124),
    raised: Color(0xFF1B2B2E),
    card: Color(0xFF182729),
    key: Color(0xFF1B292C),
    keyEdge: Color(0xFF273537),
    border: Color(0xFF223032),
    hair: Color(0xFF1F2D2F),
    menuEdge: Color(0xFF263436),
    divider: Color(0xFF475556),
    switchOff: Color(0xFF2B393B),
    text: Color(0xFFDCE8E6),
    head: Color(0xFFD4E1DF),
    subhead: Color(0xFFCEDCDA),
    cardTitle: Color(0xFFD3E1DE),
    muted: Color(0xFFB6C8C6),
    sec: Color(0xFF9DB3B0),
    icon: Color(0xFF8BA4A0),
    faint: Color(0xFF86A09C),
    dim: Color(0xFF526766),
    dim2: Color(0xFF4D6160),
    dim3: Color(0xFF3B4D4E),
    box: Color(0xFF435656),
    accent: Color(0xFF5FB3A6),
    link: Color(0xFF7FC9BD),
    chipText: Color(0xFF9BD6CC),
    tb: Color(0xFF1D3A38),
    tf: Color(0xFFB6E3DB),
    tkBg: Color(0xFF2A524E),
    tkText: Color(0xFF86C9BE),
    onAccent: Color(0xFF0F1A1C),
    clay: Color(0xFFE08E6D),
    codeBg: Color(0xFF212F32),
    tSage: Color(0xFF1E3738),
    tags: [
      Color(0xFF30362C),
      Color(0xFF30302D),
      Color(0xFF27352E),
      Color(0xFF1C363A),
      Color(0xFF213632),
      Color(0xFF23333E),
      Color(0xFF2B313D),
      Color(0xFF372E2F),
    ],
    dots: [
      Color(0xFFD3B05A),
      Color(0xFFD7865F),
      Color(0xFF9AA765),
      Color(0xFF4FB0B8),
      Color(0xFF6FB07E),
      Color(0xFF7E9BD3),
      Color(0xFFB08CC9),
      Color(0xFFD98396),
    ],
  );

  static const _fjordLight = _Tones(
    canvas: Color(0xFFEDF4F3),
    rail: Color(0xFFE5EFEE),
    page: Color(0xFFFAFDFC),
    raised: Color(0xFFE8F1F0),
    card: Color(0xFFF2F8F7),
    key: Color(0xFFF1F4F3),
    keyEdge: Color(0xFFE3E9E7),
    border: Color(0xFFEAEEED),
    hair: Color(0xFFEDF1F0),
    menuEdge: Color(0xFFE5EAE9),
    divider: Color(0xFFBFC8C6),
    switchOff: Color(0xFFDFE4E3),
    text: Color(0xFF18302E),
    head: Color(0xFF1D3634),
    subhead: Color(0xFF223B39),
    cardTitle: Color(0xFF1E3734),
    muted: Color(0xFF314D4A),
    sec: Color(0xFF42605C),
    icon: Color(0xFF4D6A66),
    faint: Color(0xFF506C68),
    dim: Color(0xFF9DADAB),
    dim2: Color(0xFFA5B5B2),
    dim3: Color(0xFFBFCAC8),
    box: Color(0xFFB3C0BE),
    accent: Color(0xFF1F7A70),
    link: Color(0xFF1D6C64),
    chipText: Color(0xFF195E57),
    tb: Color(0xFFD7EDE9),
    tf: Color(0xFF145049),
    tkBg: Color(0xFFB2D6D1),
    tkText: Color(0xFF1A675E),
    onAccent: Color(0xFFFFFFFF),
    clay: Color(0xFFB5552E),
    codeBg: Color(0xFFEAEFEE),
    tSage: Color(0xFFD9E9E7),
    tags: [
      Color(0xFFE9E8DA),
      Color(0xFFEFE4DD),
      Color(0xFFE3E8DC),
      Color(0xFFD8E8E9),
      Color(0xFFDCEAE1),
      Color(0xFFDEE6EF),
      Color(0xFFE6E3ED),
      Color(0xFFEEE2E7),
    ],
    dots: [
      Color(0xFF87701C),
      Color(0xFFAF5530),
      Color(0xFF5E6E28),
      Color(0xFF14737A),
      Color(0xFF2F7D45),
      Color(0xFF3F62A6),
      Color(0xFF76509A),
      Color(0xFFA74868),
    ],
  );

  static ThemeData _build(CalcPalette palette) {
    final brightness = palette.brightness;
    final dark = brightness == Brightness.dark;
    final compactControls = AppPlatform.isDesktop;
    final accent = palette.accent;
    final onAccent = palette.onAccent;
    final buttonHeight = AppControlMetrics.buttonHeight;
    final iconButtonExtent = AppControlMetrics.iconButtonExtent;
    final tapTarget = compactControls
        ? MaterialTapTargetSize.shrinkWrap
        : MaterialTapTargetSize.padded;

    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: accent,
          onPrimary: onAccent,
          surface: palette.editorBackground,
          onSurface: palette.textPrimary,
          error: dark ? const Color(0xFFFF716A) : const Color(0xFFB42318),
        );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
      scaffoldBackgroundColor: palette.editorBackground,
      // Desktop wants tighter controls than the phone default.
      visualDensity: AppPlatform.isDesktop
          ? VisualDensity.compact
          : VisualDensity.standard,
      splashFactory: AppPlatform.isDesktop ? NoSplash.splashFactory : null,
    );

    final textTheme = base.textTheme
        .copyWith(
          displayLarge: base.textTheme.displayLarge?.copyWith(
            fontWeight: FontWeight.w300,
            letterSpacing: -0.5,
          ),
          displayMedium: base.textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.w300,
            letterSpacing: -0.4,
          ),
          displaySmall: base.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w300,
            letterSpacing: -0.3,
          ),
          headlineLarge: base.textTheme.headlineLarge?.copyWith(
            fontWeight: FontWeight.w400,
            letterSpacing: -0.3,
          ),
          headlineMedium: base.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w400,
            letterSpacing: -0.2,
          ),
          headlineSmall: base.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w400,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w400,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w400,
          ),
          titleSmall: base.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w400,
          ),
          bodyLarge: base.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w400,
          ),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w400,
          ),
          bodySmall: base.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w400,
            fontSize: AppPlatform.isWindows ? AppTypeScale.caption : null,
            height: AppPlatform.isWindows ? 1.3 : null,
          ),
          labelLarge: base.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w400,
          ),
          labelMedium: base.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w400,
            fontSize: AppPlatform.isWindows ? AppTypeScale.caption : null,
          ),
          labelSmall: base.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w400,
            fontSize: AppPlatform.isWindows ? AppTypeScale.micro : null,
            height: AppPlatform.isWindows ? 1.2 : null,
          ),
        )
        .apply(
          bodyColor: palette.textPrimary,
          displayColor: palette.textPrimary,
        );

    OutlineInputBorder fieldBorder(Color color, {double width = 1}) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
          borderSide: BorderSide(color: color, width: width),
        );

    return base.copyWith(
      extensions: [palette],
      canvasColor: palette.surfaceBackground,
      cardColor: palette.surfaceBackground,
      dividerColor: palette.separator,
      focusColor: accent.withValues(alpha: 0.14),
      hoverColor: palette.hover,
      highlightColor: Colors.transparent,
      splashColor: accent.withValues(alpha: 0.08),
      shadowColor: Colors.transparent,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: palette.selection,
        selectionHandleColor: accent,
      ),
      iconTheme: IconThemeData(
        color: palette.textSecondary,
        size: AppControlMetrics.iconDefault,
      ),
      textTheme: textTheme,
      appBarTheme: AppBarThemeData(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: palette.textPrimary,
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
          color: palette.textPrimary,
          fontSize: AppTypeScale.title,
          fontWeight: FontWeight.w400,
          letterSpacing: 0,
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrimColor: palette.scrim,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surfaceBackground,
        barrierColor: palette.scrim,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
          color: palette.textPrimary,
          fontSize: AppTypeScale.heading,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.dialog),
          side: BorderSide(color: palette.controlBorder),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.surfaceBackground,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        menuPadding: EdgeInsets.all(compactControls ? 6 : 8),
        position: PopupMenuPosition.under,
        textStyle: base.textTheme.bodyMedium?.copyWith(
          fontSize: AppTypeScale.control,
          color: palette.textPrimary,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.surface),
          side: BorderSide(color: palette.controlBorder),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size.square(iconButtonExtent)),
          maximumSize: WidgetStatePropertyAll(Size.square(iconButtonExtent)),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          visualDensity: VisualDensity.standard,
          tapTargetSize: AppControlMetrics.iconButtonTapTargetSize,
          foregroundColor: WidgetStatePropertyAll(palette.textSecondary),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return accent.withValues(alpha: 0.11);
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return palette.hover;
            }
            return Colors.transparent;
          }),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return BorderSide(color: palette.selectedBorder, width: 1);
            }
            return BorderSide.none;
          }),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style:
            FilledButton.styleFrom(
              minimumSize: Size(0, buttonHeight),
              padding: EdgeInsets.symmetric(
                horizontal: compactControls ? 14 : 20,
                vertical: AppControlMetrics.buttonVerticalPadding,
              ),
              visualDensity: VisualDensity.standard,
              tapTargetSize: tapTarget,
              elevation: 0,
              shadowColor: Colors.transparent,
              foregroundColor: onAccent,
              disabledForegroundColor: palette.textTertiary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              textStyle: base.textTheme.labelLarge?.copyWith(
                fontSize: AppTypeScale.control,
                fontWeight: FontWeight.w500,
              ),
            ).copyWith(
              backgroundColor: fillStates(
                accent,
                ink: onAccent,
                disabled: palette.controlBackground,
              ),
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              animationDuration: const Duration(milliseconds: 120),
            ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style:
            OutlinedButton.styleFrom(
              minimumSize: Size(0, buttonHeight),
              padding: EdgeInsets.symmetric(
                horizontal: compactControls ? 14 : 20,
                vertical: AppControlMetrics.buttonVerticalPadding,
              ),
              visualDensity: VisualDensity.standard,
              tapTargetSize: tapTarget,
              elevation: 0,
              shadowColor: Colors.transparent,
              foregroundColor: palette.textPrimary,
              side: BorderSide(color: palette.controlBorder),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              textStyle: base.textTheme.labelLarge?.copyWith(
                fontSize: AppTypeScale.control,
                fontWeight: FontWeight.w500,
              ),
            ).copyWith(
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) {
                  return accent.withValues(alpha: 0.13);
                }
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)) {
                  return palette.hover;
                }
                return Colors.transparent;
              }),
              side: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.disabled)) {
                  return BorderSide(
                    color: palette.controlBorder.withValues(alpha: 0.55),
                  );
                }
                if (states.contains(WidgetState.focused)) {
                  return BorderSide(color: palette.selectedBorder, width: 1.25);
                }
                return BorderSide(color: palette.controlBorder);
              }),
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              animationDuration: const Duration(milliseconds: 120),
            ),
      ),
      textButtonTheme: TextButtonThemeData(
        style:
            TextButton.styleFrom(
              minimumSize: Size(0, buttonHeight),
              padding: EdgeInsets.symmetric(
                horizontal: compactControls ? 11 : 16,
                vertical: AppControlMetrics.buttonVerticalPadding,
              ),
              visualDensity: VisualDensity.standard,
              tapTargetSize: tapTarget,
              foregroundColor: accent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              textStyle: base.textTheme.labelLarge?.copyWith(
                fontSize: AppTypeScale.control,
                fontWeight: FontWeight.w500,
              ),
            ).copyWith(
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) {
                  return accent.withValues(alpha: 0.14);
                }
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)) {
                  return accent.withValues(alpha: 0.08);
                }
                return Colors.transparent;
              }),
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              animationDuration: const Duration(milliseconds: 120),
            ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          foregroundColor: palette.textSecondary,
          backgroundColor: palette.surfaceBackground,
          selectedForegroundColor: onAccent,
          selectedBackgroundColor: accent,
          disabledForegroundColor: palette.textTertiary,
          disabledBackgroundColor: palette.controlBackground,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          iconSize: AppControlMetrics.iconControl,
          minimumSize: Size(0, buttonHeight),
          padding: EdgeInsets.symmetric(
            horizontal: compactControls ? 14 : 18,
            vertical: AppControlMetrics.buttonVerticalPadding,
          ),
          visualDensity: VisualDensity.standard,
          side: BorderSide(color: palette.controlBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          tapTargetSize: tapTarget,
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontSize: AppTypeScale.control,
            fontWeight: FontWeight.w500,
          ),
          overlayColor: Colors.transparent,
          animationDuration: const Duration(milliseconds: 120),
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        isDense: true,
        filled: true,
        fillColor: palette.controlBackground,
        contentPadding: EdgeInsets.symmetric(
          horizontal: compactControls ? 12 : 14,
          vertical: AppControlMetrics.fieldVerticalPadding,
        ),
        hintStyle: base.textTheme.bodyMedium?.copyWith(
          fontSize: AppTypeScale.control,
          color: palette.textTertiary,
        ),
        labelStyle: base.textTheme.bodyMedium?.copyWith(
          fontSize: AppTypeScale.control,
          color: palette.textSecondary,
        ),
        prefixIconColor: palette.textTertiary,
        suffixIconColor: palette.textTertiary,
        border: fieldBorder(palette.controlBorder),
      ),
      switchTheme: SwitchThemeData(
        materialTapTargetSize: tapTarget,
        splashRadius: 16,
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? onAccent
              : palette.textTertiary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent
              : palette.controlBackground,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : palette.controlBorder,
        ),
        trackOutlineWidth: const WidgetStatePropertyAll(0.5),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStatePropertyAll(compactControls ? 4 : 6),
        radius: const Radius.circular(4),
        thumbColor: WidgetStatePropertyAll(
          palette.textTertiary.withValues(alpha: 0.44),
        ),
        trackColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      // The same surface every floating panel uses — see [FloatingSurface],
      // which the ones drawn by hand share. Flat, like the dialogs and menus
      // above: this theme sets a transparent shadow colour, and a tooltip
      // floating on a shadow would be the one thing pretending to have
      // height.
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        textStyle: base.textTheme.bodySmall?.copyWith(
          fontSize: AppTypeScale.caption,
          color: palette.textPrimary,
          decoration: TextDecoration.none,
          // Several of these run to three lines — a result chip names the
          // number, then how it reads, then what a click does — and set solid
          // they read as one word too long.
          height: 1.35,
        ),
        decoration: BoxDecoration(
          color: palette.surfaceBackground,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: palette.controlBorder),
        ),
      ),
    );
  }
}

/// Convenience accessor: `context.palette`.
extension CalcPaletteAccess on BuildContext {
  CalcPalette get palette => Theme.of(this).extension<CalcPalette>()!;
}

/// Applies a local opacity without erasing a transparency choice already
/// carried by the palette. Useful for chrome that is slightly quieter than its
/// base material in both regular and translucent modes.
extension MultipliedColorAlpha on Color {
  Color withMultipliedAlpha(double factor) =>
      withValues(alpha: (a * factor).clamp(0.0, 1.0));
}

/// One theme on one side, by the roles Themes r2 names (p-N-0). The palette
/// the app reads is worked out from these in [_fromTones].
class _Tones {
  const _Tones({
    required this.canvas,
    required this.rail,
    required this.page,
    required this.raised,
    required this.card,
    required this.key,
    required this.keyEdge,
    required this.border,
    required this.hair,
    required this.menuEdge,
    required this.divider,
    required this.switchOff,
    required this.text,
    required this.head,
    required this.subhead,
    required this.cardTitle,
    required this.muted,
    required this.sec,
    required this.icon,
    required this.faint,
    required this.dim,
    required this.dim2,
    required this.dim3,
    required this.box,
    required this.accent,
    required this.link,
    required this.chipText,
    required this.tb,
    required this.tf,
    required this.tkBg,
    required this.tkText,
    required this.onAccent,
    required this.clay,
    required this.codeBg,
    required this.tSage,
    required this.tags,
    required this.dots,
  });

  final Color canvas;
  final Color rail;
  final Color page;
  final Color raised;
  final Color card;
  final Color key;
  final Color keyEdge;
  final Color border;
  final Color hair;
  final Color menuEdge;
  final Color divider;
  final Color switchOff;
  final Color text;
  final Color head;
  final Color subhead;
  final Color cardTitle;
  final Color muted;
  final Color sec;
  final Color icon;
  final Color faint;
  final Color dim;
  final Color dim2;
  final Color dim3;
  final Color box;
  final Color accent;
  final Color link;
  final Color chipText;
  final Color tb;
  final Color tf;
  final Color tkBg;
  final Color tkText;
  final Color onAccent;
  final Color clay;
  final Color codeBg;
  final Color tSage;
  final List<Color> tags;
  final List<Color> dots;
}

/// A theme's palette from its roles, the way Paper's frames swapped
/// Riverbank's colours role by role. The few colours the spec gives no role
/// keep Riverbank's relation to the roles it does: the well and a code
/// block's panel sit halfway between the window and the page in the dark,
/// descriptions halfway between secondary and faint text, and a code
/// block's colours and clay as words are deepened only as far as they need
/// to read at 4.5:1.
CalcPalette _fromTones(_Tones t) {
  final dark = ThemeData.estimateBrightnessForColor(t.page) == Brightness.dark;
  final well = dark ? _mix(t.canvas, t.page, 0.5) : t.raised;
  final panel = dark ? well : t.card;
  Color code(Color ink) => _legible(ink, [panel], toward: t.text);
  return CalcPalette(
    number: t.text,
    keyword: t.text,
    unit: t.faint,
    currency: t.faint,
    function: t.text,
    variable: t.text,
    operator: t.faint,
    comment: t.faint,
    chipNumber: t.chipText,
    chipCurrency: t.chipText,
    chipUnit: t.chipText,
    chipBoolean: t.chipText,
    chipOther: t.chipText,
    textPrimary: t.text,
    textSecondary: t.sec,
    textTertiary: t.faint,
    separator: t.menuEdge,
    sidebarBackground: t.canvas,
    editorBackground: t.page,
    gutterBackground: t.page,
    surfaceBackground: t.page,
    controlBackground: t.raised,
    controlBorder: t.border,
    selectedBackground: t.keyEdge,
    selectedBorder: t.accent,
    selection: t.accent.withAlpha(dark ? 0x4D : 0x33),
    hover: t.hair,
    paperFiber: dark ? const Color(0x00000000) : t.muted.withAlpha(0x08),
    paperRuling: t.hair,
    railBackground: t.rail,
    railBorder: t.text.withAlpha(0x0F),
    tonalBackground: t.tb,
    tonalForeground: t.tf,
    tonalKeyBackground: t.tkBg,
    tonalKeyText: t.tkText,
    keycapBackground: t.key,
    keycapBorder: t.keyEdge,
    keycapText: t.sec,
    scrim: dark
        ? _mix(t.rail, const Color(0xFF000000), 0.5).withAlpha(0xB3)
        : t.text.withAlpha(0x33),
    resultPillBackground: t.tSage,
    resultPillText: t.chipText,
    totalPillBackground: t.accent,
    totalPillText: t.onAccent,
    clay: t.clay,
    clayText: _legible(t.clay, [t.page, t.card], toward: t.text),
    textHeading: t.head,
    textSubheading: t.subhead,
    textMuted: t.muted,
    textDescription: _mix(t.sec, t.faint, 0.5),
    cardBackground: t.card,
    paneEdge: dark ? t.hair : t.border,
    switchTrackOff: t.switchOff,
    checkboxBorder: t.dim2,
    lineCommand: t.dim,
    writingHint: t.dim3,
    cardTitle: t.cardTitle,
    accentText: t.link,
    pageBorder: t.hair,
    textDivider: t.divider,
    switchThumb: dark ? t.text : t.page,
    wellBackground: well,
    segmentSelected: dark ? t.menuEdge : t.page,
    shadow: dark ? const Color(0xFF000000) : t.text.withAlpha(0x66),
    accent: t.accent,
    onAccent: t.onAccent,
    codeKeyword: code(t.clay),
    codeString: code(dark ? t.chipText : t.link),
    codeNumber: code(t.dots[0]),
    codeBuiltIn: code(t.dots[3]),
    codePanel: panel,
    codeChip: t.codeBg,
    railInk: t.icon,
    quoteBar: t.box,
    tagCards: t.tags,
    tagDots: t.dots,
  );
}

/// [a] moved [t] of the way to [b], channel by channel in whole steps.
Color _mix(Color a, Color b, double t) {
  int channel(double from, double to) {
    final start = (from * 255).round();
    return (start + ((to * 255).round() - start) * t).round();
  }

  return Color.fromARGB(
    (a.a * 255).round(),
    channel(a.r, b.r),
    channel(a.g, b.g),
    channel(a.b, b.b),
  );
}

/// [ink] where it already reads at 4.5:1 on every one of [grounds], and
/// otherwise moved toward [toward] only as far as that takes.
Color _legible(Color ink, List<Color> grounds, {required Color toward}) {
  double contrast(Color a, Color b) {
    final x = a.computeLuminance(), y = b.computeLuminance();
    return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
  }

  for (var step = 0; step <= 20; step++) {
    final candidate = _mix(ink, toward, step / 20);
    if (grounds.every((ground) => contrast(candidate, ground) >= 4.5)) {
      return candidate;
    }
  }
  return toward;
}
