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

  /// The keyboard focus ring: the accent, deepened where it would fall under
  /// 3:1 on a surface a ring can sit on.
  final Color focusRing;
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

  /// That hairline, also along the bottom of the list's bar and the page's
  /// band, so one line runs under both at 52.
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

  /// The quietest words, still at 4.5:1: a sidebar's group labels, a
  /// count beside a heading, the version line.
  final Color textQuiet;

  /// A card of rows inside a dialog, a step off the pane it sits on, and the
  /// edge between a dialog's navigation and its pane.
  final Color cardBackground;
  final Color paneEdge;

  /// D01's raised fill and its line, for the Notes · Folders track and the
  /// rail's account circle, in a theme that keeps them off its controls and
  /// cards. Null where those draw on the card and control colours.
  final Color? raisedBackground;
  final Color? raisedBorder;

  /// A switch that is off: the track reads as a slot, not as a control.
  final Color switchTrackOff;

  /// The edge of a checkbox that is not ticked, on the page.
  final Color checkboxBorder;

  /// The "+" beside an empty line that opens Commands, at rest.
  final Color lineCommand;

  /// The title on a note's sticky card or list row, and the sage that marks
  /// a link inside the list, such as View all.
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

  /// Ink set on an orange fill, text and icons alike: white, the check in a
  /// ticked box, a filled button's label, a total's figures.
  final Color onAccent;

  /// The fill under words in [onAccent]: a filled button, a total's pill. A
  /// deeper shade of [accent], so white reads at 4.5:1; fills that carry only
  /// an icon keep [accent].
  final Color accentFill;

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

  /// A quote's bar, Paper's.
  final Color quoteBar;

  /// Each tag colour's dot, in tag order: mustard, rust, olive, teal, sage,
  /// slate, plum and rose. A tag keeps its name in every theme; only these
  /// change.
  final List<Color> tagDots;

  /// Whether this is Increase contrast's version of the palette, which also
  /// draws the keyboard focus ring wider.
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
    final deeperFill = _mix(accentFill, const Color(0xFF000000), 0.18);
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
      textQuiet: _mix(textQuiet, ink, 0.45),
      textMuted: _mix(textMuted, ink, 0.45),
      textTertiary: faint,
      controlBorder: border,
      raisedBorder: raisedBorder == null ? null : border,
      paneEdge: border,
      pageBorder: hairline,
      paperRuling: hairline,
      textDivider: _mix(editorBackground, ink, 0.45),
      checkboxBorder: outline,
      quoteBar: outline,
      accent: strongAccent,
      selectedBorder: strongAccent,
      focusRing: _mix(focusRing, extreme, 0.18),
      accentFill: deeperFill,
      totalPillBackground: deeperFill,
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
    required this.focusRing,
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
    required this.textQuiet,
    required this.cardBackground,
    required this.paneEdge,
    this.raisedBackground,
    this.raisedBorder,
    required this.switchTrackOff,
    required this.checkboxBorder,
    required this.lineCommand,
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
    required this.accentFill,
    required this.codeKeyword,
    required this.codeString,
    required this.codeNumber,
    required this.codeBuiltIn,
    required this.codePanel,
    required this.codeChip,
    required this.quoteBar,
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
    Color? focusRing,
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
    Color? textQuiet,
    Color? cardBackground,
    Color? paneEdge,
    Color? raisedBackground,
    Color? raisedBorder,
    Color? switchTrackOff,
    Color? checkboxBorder,
    Color? lineCommand,
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
    Color? accentFill,
    Color? codeKeyword,
    Color? codeString,
    Color? codeNumber,
    Color? codeBuiltIn,
    Color? codePanel,
    Color? codeChip,
    Color? quoteBar,
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
    focusRing: focusRing ?? this.focusRing,
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
    textQuiet: textQuiet ?? this.textQuiet,
    cardBackground: cardBackground ?? this.cardBackground,
    paneEdge: paneEdge ?? this.paneEdge,
    raisedBackground: raisedBackground ?? this.raisedBackground,
    raisedBorder: raisedBorder ?? this.raisedBorder,
    switchTrackOff: switchTrackOff ?? this.switchTrackOff,
    checkboxBorder: checkboxBorder ?? this.checkboxBorder,
    lineCommand: lineCommand ?? this.lineCommand,
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
    accentFill: accentFill ?? this.accentFill,
    codeKeyword: codeKeyword ?? this.codeKeyword,
    codeString: codeString ?? this.codeString,
    codeNumber: codeNumber ?? this.codeNumber,
    codeBuiltIn: codeBuiltIn ?? this.codeBuiltIn,
    codePanel: codePanel ?? this.codePanel,
    codeChip: codeChip ?? this.codeChip,
    quoteBar: quoteBar ?? this.quoteBar,
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
      focusRing: mix(focusRing, other.focusRing),
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
      textQuiet: mix(textQuiet, other.textQuiet),
      cardBackground: mix(cardBackground, other.cardBackground),
      paneEdge: mix(paneEdge, other.paneEdge),
      raisedBackground: t < 0.5 ? raisedBackground : other.raisedBackground,
      raisedBorder: t < 0.5 ? raisedBorder : other.raisedBorder,
      switchTrackOff: mix(switchTrackOff, other.switchTrackOff),
      checkboxBorder: mix(checkboxBorder, other.checkboxBorder),
      lineCommand: mix(lineCommand, other.lineCommand),
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
      accentFill: mix(accentFill, other.accentFill),
      codeKeyword: mix(codeKeyword, other.codeKeyword),
      codeString: mix(codeString, other.codeString),
      codeNumber: mix(codeNumber, other.codeNumber),
      codeBuiltIn: mix(codeBuiltIn, other.codeBuiltIn),
      codePanel: mix(codePanel, other.codePanel),
      codeChip: mix(codeChip, other.codeChip),
      quoteBar: mix(quoteBar, other.quoteBar),
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

/// The crisp system's fills, worked out from the palette instead of listed
/// in it: each is the text colour at an alpha, laid over whatever is beneath
/// it, so a fill on a fill comes out a step lighter on its own.
extension CrispFills on CalcPalette {
  /// A field, a card, First on the list, the phone bar.
  Color get fillRest => textPrimary.withValues(alpha: 0.04);

  /// A control sitting on a field, a secondary button, a hover.
  Color get fillControl => textPrimary.withValues(alpha: 0.06);

  /// A selected row or tab.
  Color get fillSelected => textPrimary.withValues(alpha: 0.07);

  /// The one sage-tinted control in a page.
  Color get fillSageTint => accentText.withValues(alpha: 0.16);

  /// The 1 px edge round something that floats, as the phone's bar does.
  Color get edge => textPrimary.withValues(alpha: 0.08);

  /// The outline of a filled card, field or track: none, as the crisp boards
  /// draw them, until Increase contrast asks for borders.
  Color get fillEdge =>
      increasedContrast ? controlBorder : const Color(0x00000000);
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

  /// The note's first line, its title: 28 semibold, the one title on the
  /// page, so it names the note without shouting over it. The meta row sits under it, 10 below the title and 24
  /// above the body. On a tablet it keeps a second line's room for the tags;
  /// a phone's facts and tags share one line, as M07 draws them.
  static const double titleFontSize = 28;
  static const double titleRow = 32;
  static const FontWeight titleWeight = FontWeight.w600;
  static const double metaGap = 10;
  static double get metaRow => AppPlatform.isMobile ? 16 + 8 + 22 : 16;
  static const double metaBottom = 24;
  static double get titleReserve => metaGap + metaRow + metaBottom;
  static const double phoneMetaRow = 22;

  /// While the page's days have the bar's top left, a filed note's folders
  /// sit in a line of their own [pathGap] above its title.
  static const double pathRow = 16;
  static const double pathGap = 8;

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

/// The radii of the design system (handoffs/design-system/tokens.md).
///
/// Controls and selected rows share [control]. A card of settings rows is
/// [group], a note's card is [card], a phone list's card of rows is
/// [phoneList], and a dialog, menu or floating panel is [surface]. Chips are
/// full pills. Fills one or two steps apart separate one layer from another:
/// no borders, no shadows.
class AppRadii {
  const AppRadii._();

  static const double small = 4;
  static const double control = 7;
  static const double group = 8;
  static const double surface = 12;
  static const double card = 14;
  static const double phoneList = 18;
  static const double pill = 999;
}

/// A count in a small circle, such as the one beside Notes on a phone's
/// Home: [desktop] or [phone] across, widening into a pill past one digit
/// with [padding] each side, in the selected fill with secondary text.
class AppCountBadge {
  const AppCountBadge._();

  static const double desktop = 16;
  static const double phone = 18;
  static const double padding = 4;
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
  static double get iconControl => _touch ? 20 : 16;

  /// A primary icon that is itself the button. The workhorse of every bar.
  static double get iconAction => _touch ? 20 : 16;

  /// Primary and secondary glyphs inside the roomier footer controls.
  ///
  /// These sit one or two points above title-bar glyphs so the repeated strip
  /// reads at the same visual weight as the surrounding editor and sidebar.
  static double get footerIconAction => _touch ? 20 : 18;
  static double get footerIconControl => _touch ? 20 : 18;

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

  /// The smallest legible annotation: the key chip in a tonal button. 10.5 is a real size on a Mac but too fine on a
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

  /// A window's, a pane's or a dialog's own title, set semibold.
  static double get title => _touch
      ? 17
      : _windows
      ? 15.5
      : 14.5;

  /// A dialog's title: the same step as [title] on a desktop, where the
  /// references set "Preferences" at 14.5, and larger on a phone.
  static double get heading => _touch
      ? 20
      : _windows
      ? 15.5
      : 14.5;

  /// The name of the space the notes list is showing, over the list. On a
  /// phone it is the screen's large title, the same 26 as an open note's.
  static double get spaceTitle => _touch
      ? 26
      : _windows
      ? 15.5
      : 14.5;

  /// A row's title in a list card or a settings card.
  static double get row => _touch
      ? 16
      : _windows
      ? 14
      : 14;

  /// A chip's words: a date, a tag, a count.
  static double get chip => _touch
      ? 12
      : _windows
      ? 11
      : 10.5;

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

/// Geist's tracking by size: tighter as text grows, a little open at 13 and
/// below so small text keeps its air. Text past 17, the screen titles,
/// keeps its own.
class AppTracking {
  const AppTracking._();

  static double of(double size) => switch (size.round()) {
    > 17 => 0,
    17 => -0.2,
    16 => -0.1,
    15 => -0.05,
    14 => 0,
    13 => 0.1,
    _ => 0.15,
  };
}

/// The faces the interface is set in. The writing surface has its own: see
/// [WritingFont].
class AppFonts {
  const AppFonts._();

  /// Every control, label and result, and the Clean writing style: Geist,
  /// bundled, so the app reads the same on every device.
  static const String ui = 'Geist';

  /// The handwritten face: the screen titles ([handTitle]), the empty
  /// moments ([handAccent]) and the Handwritten and Mixed writing styles.
  static const String hand = 'Shantell Sans';

  /// Fixed-width letters, where they are the point: code and the Monospace
  /// writing style.
  static const String mono = 'Geist Mono';

  /// The Pixel writing style's face, Geist Pixel's Square cut.
  static const String pixel = 'Geist Pixel';

  /// What draws the scripts and symbols Geist does not have (⌘, ⌥, ⌃, ⎋,
  /// some currency signs, Devanagari and other scripts): the device's own.
  static List<String> get uiFallback => [
    AppPlatform.uiFontFamily,
    ...AppPlatform.uiFontFallback,
  ];

  /// The same for Geist Mono, which has no ⌘ or ⌥ of its own.
  static const List<String> monoFallback = AppPlatform.monoFontFallback;
}

/// The waiting marker: Shared's count on the rail, the phone's Folders dot
/// and the invitations dot in Settings. One red in every theme and mode, with
/// white on it at 5 : 1 (tokens.md, Refine D).
const Color waitingMarker = Color(0xFFC93B36);

/// The interface's three weights: [regular] for everything people read,
/// [medium] for a row's title, and [semibold] for a section heading and a
/// window's, a dialog's or a note's title.
class AppWeight {
  const AppWeight._();

  static const double regular = 400;
  static const double medium = 500;
  static const double semibold = 600;

  /// A Flutter weight on this ladder: w600 and up is a title, w500 a row's
  /// title, 400 to 499 reads, and anything under 400 (a display cut) is left
  /// alone.
  static double axisOf(FontWeight weight) {
    final value = weight.value;
    if (value < 400) return value.toDouble();
    if (value >= 600) return semibold;
    return value >= 500 ? medium : regular;
  }

  /// Nearest named weight, for a face with no `wght` axis.
  static FontWeight named(double axis) {
    if (axis < 450) return FontWeight.w400;
    if (axis < 550) return FontWeight.w500;
    if (axis < 650) return FontWeight.w600;
    return FontWeight.w700;
  }

  /// [axis] as the platform's Bold Text setting wants it.
  ///
  /// `Text` honours Bold Text by merging `fontWeight: bold`, and an explicit
  /// `wght` axis outranks that merge, so a style built here carries its own
  /// bold step: regular becomes semibold, and a title becomes bold. It
  /// rebuilds with the rest of the app on `didChangeAccessibilityFeatures`.
  static double bold(double axis) {
    final features =
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures;
    if (!features.boldText) return axis;
    return math.min(axis + 200, 700);
  }

  /// A style's `fontWeight` for [step], Bold Text included.
  static FontWeight font(double step) => named(bold(step));

  /// A style's `fontVariations` for [step], Bold Text included, keeping any
  /// [extra] axes. Pair it with [font], so the same step reaches every face.
  static List<FontVariation> wght(
    double step, {
    List<FontVariation> extra = const [],
  }) => variations(bold(step), extra: extra);

  /// `wght` at [axis], keeping any other axes already set.
  static List<FontVariation> variations(
    double axis, {
    List<FontVariation> extra = const [],
  }) => [
    for (final variation in extra)
      if (variation.axis != 'wght') variation,
    FontVariation('wght', axis),
  ];
}

/// Interface text on the ladder.
///
/// Geist takes [AppTracking] for its size unless [letterSpacing] is given;
/// other faces take none. Times, dates, counts and amounts pass [tabular]
/// for tabular lining figures, so they line up and don't shuffle as they
/// change.
TextStyle chromeStyle({
  required double size,

  /// The line box, or null to take the face's own.
  required double? line,
  required double weight,
  required Color color,
  String? family,
  List<String>? fallback,
  List<FontVariation> extra = const [],
  bool tabular = false,
  double? letterSpacing,
  FontStyle? fontStyle,
}) {
  final axis = AppWeight.bold(weight);
  final geist = family == null || family == AppFonts.ui;
  return TextStyle(
    fontFamily: family ?? AppFonts.ui,
    fontFamilyFallback: fallback ?? AppFonts.uiFallback,
    fontSize: size,
    height: line == null ? null : line / size,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: AppWeight.named(axis),
    fontVariations: AppWeight.variations(axis, extra: extra),
    color: color,
    letterSpacing: letterSpacing ?? (geist ? AppTracking.of(size) : 0),
    fontStyle: fontStyle,
    fontFeatures: tabular
        ? const [FontFeature.tabularFigures(), FontFeature.liningFigures()]
        : null,
  );
}

/// The handwritten accent: one line in Shantell Sans at 17/24, regular, in
/// the secondary grey, the same on a desktop and a phone. Only for the three
/// friendly moments the design names (handoffs/design-system/tokens.md): an
/// empty list's line, an empty Kapy AI chat and a cleared Tasks list. Never a
/// list, button, Settings or a note's title; the screen titles take
/// [handTitle].
TextStyle handAccent(CalcPalette palette) => chromeStyle(
  size: 17,
  line: 24,
  weight: AppWeight.regular,
  color: palette.textSecondary,
  family: AppFonts.hand,
  extra: WritingFont.handwritten.faceVariations,
);

/// A screen's name in handwriting: Shantell Sans at 500, the only handwritten
/// word on its screen. Only for the titles tokens.md names: the notes list's
/// name and the Kapy AI panel's on a desktop, and a phone's Notes, Tasks and
/// Kapy AI.
TextStyle handTitle({
  required double size,
  required double line,
  required Color color,
}) => chromeStyle(
  size: size,
  line: line,
  weight: 500,
  color: color,
  family: AppFonts.hand,
  extra: WritingFont.handwritten.faceVariations,
);

/// The same ladder, applied to a style the theme already built.
TextStyle? ladder(TextStyle? style, double weight) {
  if (style == null) return null;
  final axis = AppWeight.bold(weight);
  return style.copyWith(
    fontWeight: AppWeight.named(axis),
    fontVariations: AppWeight.variations(
      axis,
      extra: style.fontVariations ?? const [],
    ),
  );
}

class KapyTheme {
  const KapyTheme._();

  /// A filled control's background in each state: [fill] at rest, with a
  /// little of its [ink] laid over it when hovered and a little more while
  /// pressed, and [disabled] when it has nothing to do. The accent
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
    if (states.contains(WidgetState.hovered)) {
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

  /// Riverbank, the default: the neutral near-blacks and greys of Sanjay's
  /// references (handoffs/design-system/tokens.md) with the brand orange as
  /// the one accent. Surfaces sit a step or two apart, so layers part by
  /// fill rather than by a border or a shadow, and text steps down by grey
  /// level alone.
  static final CalcPalette darkPalette = _fromTones(_riverbankDark);
  static final CalcPalette lightPalette = _fromTones(_riverbankLight);

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

  // The other five themes are the same ladder moved a little: Graphite a
  // step lighter, Midnight down to true black, and Dusk, Lamplight and Fjord
  // with a trace of violet, amber and teal in their surfaces. Text, the
  // accent and the contrast floors are shared. Each keeps its own tag
  // colours, in tag order: mustard, rust, olive, teal, sage, slate, plum and
  // rose.

  static const _riverbankDark = _Tones(
    window: Color(0xFF0D0D0D),
    pane: Color(0xFF1A1A1A),
    card: Color(0xFF1A1A1A),
    raised: Color(0xFF262626),
    selected: Color(0xFF262626),
    hairline: Color(0xFF262626),
    divider: Color(0xFF2E2E2E),
    chip: Color(0xFF262626),
    switchOff: Color(0xFF333333),
    ring: Color(0xFF5C5C5C),
    text: Color(0xFFEDEDED),
    title: Color(0xFFEDEDED),
    secondary: Color(0xFFA3A3A3),
    tertiary: Color(0xFF8F8F8F),
    quiet: Color(0xFF8F8F8F),
    mark: Color(0xFF4A4A4A),
    accent: Color(0xFFE8772E),
    onAccent: Color(0xFFFFFFFF),
    accentFill: Color(0xFFC05815),
    accentText: Color(0xFFE8772E),
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

  /// The dark ladder turned over, each text tier at the contrast its dark
  /// twin has: about 13.4, 6.2, 5.3 and 4.6 to 1.
  static const _riverbankLight = _Tones(
    window: Color(0xFFF4F4F4),
    pane: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    raised: Color(0xFFEDEDED),
    selected: Color(0xFFEDEDED),
    hairline: Color(0xFFF0F0F0),
    divider: Color(0xFFE5E5E5),
    chip: Color(0xFFF1F1F1),
    switchOff: Color(0xFFDCDCDC),
    ring: Color(0xFFA3A3A3),
    text: Color(0xFF171717),
    title: Color(0xFF171717),
    secondary: Color(0xFF525252),
    tertiary: Color(0xFF6B6B6B),
    quiet: Color(0xFF6B6B6B),
    mark: Color(0xFFB5B5B5),
    accent: Color(0xFFD9692A),
    onAccent: Color(0xFFFFFFFF),
    accentFill: Color(0xFFBD5A22),
    accentText: Color(0xFFB9551A),
    dots: [
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

  static final _graphiteDark = _riverbankDark.moved(
    (c) => _mix(c, const Color(0xFFFFFFFF), 0.04),
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
  static final _graphiteLight = _riverbankLight.moved(
    (c) => _mix(c, const Color(0xFF000000), 0.03),
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
  static final _midnightDark = _riverbankDark.moved(
    (c) => _darker(c, 13),
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
  static final _duskDark = _riverbankDark.moved(
    (c) => _mix(c, const Color(0xFF6B5CA5), 0.07),
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
  static final _duskLight = _riverbankLight.moved(
    (c) => _mix(c, const Color(0xFF6B5CA5), 0.06),
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
  static final _lamplightDark = _riverbankDark.moved(
    (c) => _mix(c, const Color(0xFFC8893A), 0.06),
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
  static final _lamplightLight = _riverbankLight.moved(
    (c) => _mix(c, const Color(0xFFC8893A), 0.07),
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
  static final _fjordDark = _riverbankDark.moved(
    (c) => _mix(c, const Color(0xFF3F8A8C), 0.07),
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
  static final _fjordLight = _riverbankLight.moved(
    (c) => _mix(c, const Color(0xFF3F8A8C), 0.06),
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
          primaryContainer: dark
              ? const Color(0xFF2B1C12)
              : const Color(0xFFFBEADF),
          onPrimaryContainer: palette.accentText,
          error: dark ? const Color(0xFFEB534E) : const Color(0xFFC0332E),
          errorContainer: dark
              ? const Color(0xFF291919)
              : const Color(0xFFFBE9E8),
          onErrorContainer: dark
              ? const Color(0xFFEB534E)
              : const Color(0xFFB02D28),
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
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
          ),
          displayMedium: base.textTheme.displayMedium?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
          ),
          displaySmall: base.textTheme.displaySmall?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
          ),
          headlineLarge: base.textTheme.headlineLarge?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
          ),
          headlineMedium: base.textTheme.headlineMedium?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
          ),
          headlineSmall: base.textTheme.headlineSmall?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
          ),
          titleSmall: base.textTheme.titleSmall?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
          ),
          bodyLarge: base.textTheme.bodyLarge?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
          ),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
          ),
          bodySmall: base.textTheme.bodySmall?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
            fontSize: AppPlatform.isWindows ? AppTypeScale.caption : null,
            height: AppPlatform.isWindows ? 1.3 : null,
          ),
          labelLarge: base.textTheme.labelLarge?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
          ),
          labelMedium: base.textTheme.labelMedium?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
            fontSize: AppPlatform.isWindows ? AppTypeScale.caption : null,
          ),
          labelSmall: base.textTheme.labelSmall?.copyWith(
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
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
      focusColor: Colors.transparent,
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
        titleTextStyle: ladder(
          base.textTheme.titleMedium!.copyWith(
            color: palette.textPrimary,
            fontSize: AppTypeScale.title,
            letterSpacing: 0,
          ),
          AppWeight.semibold,
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
        titleTextStyle: ladder(
          base.textTheme.titleMedium!.copyWith(
            color: palette.textPrimary,
            fontSize: AppTypeScale.heading,
          ),
          AppWeight.semibold,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.surface),
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
            if (states.contains(WidgetState.hovered)) {
              return palette.hover;
            }
            return Colors.transparent;
          }),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
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
              textStyle: ladder(
                base.textTheme.labelLarge?.copyWith(
                  fontSize: AppTypeScale.control,
                ),
                AppWeight.regular,
              ),
            ).copyWith(
              backgroundColor: fillStates(
                palette.accentFill,
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              textStyle: ladder(
                base.textTheme.labelLarge?.copyWith(
                  fontSize: AppTypeScale.control,
                ),
                AppWeight.regular,
              ),
            ).copyWith(
              // A quiet fill, no border. Keyboard focus is the shared ring,
              // not a border here, so focus does not also change the fill.
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.disabled)) {
                  return palette.controlBackground.withValues(alpha: 0.55);
                }
                if (states.contains(WidgetState.pressed)) {
                  return Color.alphaBlend(
                    palette.textPrimary.withValues(alpha: 0.13),
                    palette.controlBackground,
                  );
                }
                if (states.contains(WidgetState.hovered)) {
                  return Color.alphaBlend(
                    palette.textPrimary.withValues(alpha: 0.07),
                    palette.controlBackground,
                  );
                }
                return palette.controlBackground;
              }),
              side: const WidgetStatePropertyAll(BorderSide.none),
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
              foregroundColor: palette.accentText,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              textStyle: ladder(
                base.textTheme.labelLarge?.copyWith(
                  fontSize: AppTypeScale.control,
                ),
                AppWeight.regular,
              ),
            ).copyWith(
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) {
                  return accent.withValues(alpha: 0.14);
                }
                if (states.contains(WidgetState.hovered)) {
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
          selectedForegroundColor: palette.textPrimary,
          selectedBackgroundColor: palette.segmentSelected,
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
          side: BorderSide.none,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          tapTargetSize: tapTarget,
          textStyle: ladder(
            base.textTheme.labelLarge?.copyWith(fontSize: AppTypeScale.control),
            AppWeight.regular,
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
        border: fieldBorder(Colors.transparent),
        enabledBorder: fieldBorder(Colors.transparent),
        focusedBorder: fieldBorder(accent, width: 1.25),
        errorBorder: fieldBorder(scheme.error),
        focusedErrorBorder: fieldBorder(scheme.error, width: 1.25),
      ),
      switchTheme: SwitchThemeData(
        materialTapTargetSize: tapTarget,
        splashRadius: 16,
        thumbColor: WidgetStatePropertyAll(palette.switchThumb),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accentFill
              : palette.switchTrackOff,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        materialTapTargetSize: tapTarget,
        shape: const CircleBorder(),
        side: WidgetStateBorderSide.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? BorderSide.none
              : BorderSide(color: palette.checkboxBorder, width: 1.5),
        ),
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accentFill
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(onAccent),
      ),
      radioTheme: RadioThemeData(
        materialTapTargetSize: tapTarget,
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent
              : palette.checkboxBorder,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: palette.resultPillBackground,
        selectedColor: scheme.primaryContainer,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        labelStyle: base.textTheme.labelSmall?.copyWith(
          fontSize: AppTypeScale.chip,
          color: palette.textTertiary,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: palette.pageBorder,
        thickness: 0.5,
        space: 0.5,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: palette.switchTrackOff,
        circularTrackColor: palette.switchTrackOff,
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

/// One theme on one side, by the roles of the design system's ladder
/// (handoffs/design-system/tokens.md). The palette the app reads is worked
/// out from these in [_fromTones].
class _Tones {
  const _Tones({
    required this.window,
    required this.pane,
    required this.card,
    required this.raised,
    required this.selected,
    required this.hairline,
    required this.divider,
    required this.chip,
    required this.switchOff,
    required this.ring,
    required this.text,
    required this.title,
    required this.secondary,
    required this.tertiary,
    required this.quiet,
    required this.mark,
    required this.accent,
    required this.onAccent,
    required this.accentFill,
    required this.accentText,
    required this.dots,
  });

  /// The sidebar, the rail and the list behind the cards.
  final Color window;

  /// The open note and a dialog's content side.
  final Color pane;

  /// A card of notes or of settings rows.
  final Color card;

  /// A quiet button's fill, a field, a keycap.
  final Color raised;

  /// A selected or hovered row.
  final Color selected;

  /// The line between rows inside a card, inset to the text.
  final Color hairline;

  /// The line between panes, and a floating surface's edge.
  final Color divider;
  final Color chip;
  final Color switchOff;

  /// An empty checkbox's ring.
  final Color ring;

  final Color text;
  final Color title;
  final Color secondary;
  final Color tertiary;

  /// The quietest words: group labels, counts, the version line.
  final Color quiet;

  /// Dots and chevrons between words, never words themselves.
  final Color mark;

  final Color accent;
  final Color onAccent;
  final Color accentFill;
  final Color accentText;
  final List<Color> dots;

  /// This ladder with every surface, line and ring passed through [move]:
  /// how the other themes shift Riverbank's. Text and the accent stay.
  _Tones moved(Color Function(Color) move, {required List<Color> dots}) =>
      _Tones(
        window: move(window),
        pane: move(pane),
        card: move(card),
        raised: move(raised),
        selected: move(selected),
        hairline: move(hairline),
        divider: move(divider),
        chip: move(chip),
        switchOff: move(switchOff),
        ring: move(ring),
        text: text,
        title: title,
        secondary: secondary,
        tertiary: tertiary,
        quiet: quiet,
        mark: mark,
        accent: accent,
        onAccent: onAccent,
        accentFill: accentFill,
        accentText: accentText,
        dots: dots,
      );
}

/// A theme's palette from its ladder. Every word reads at 4.5:1 or better
/// on every surface it can sit on, and the accent at 3:1 against the
/// surfaces it fills on: a tier that falls short in a shifted theme is moved
/// toward the text only as far as that takes.
CalcPalette _fromTones(_Tones t) {
  final dark = ThemeData.estimateBrightnessForColor(t.pane) == Brightness.dark;
  final grounds = [t.window, t.pane, t.card, t.selected, t.raised];
  Color read(Color ink) => _legible(ink, grounds, toward: t.text);
  final secondary = _legible(t.secondary, [
    ...grounds,
    t.divider,
  ], toward: t.text);
  final tertiary = read(t.tertiary);
  final quiet = _legible(t.quiet, [t.window, t.pane, t.card], toward: t.text);
  final accentText = read(t.accentText);
  final accent = _legible(
    t.accent,
    [t.window, t.pane, t.card],
    toward: t.text,
    ratio: 3,
  );
  Color code(Color ink) => _legible(ink, [t.card], toward: t.text);
  return CalcPalette(
    number: t.text,
    keyword: t.text,
    unit: tertiary,
    currency: tertiary,
    function: t.text,
    variable: t.text,
    operator: tertiary,
    comment: tertiary,
    chipNumber: t.text,
    chipCurrency: t.text,
    chipUnit: t.text,
    chipBoolean: t.text,
    chipOther: t.text,
    textPrimary: t.text,
    textSecondary: secondary,
    textTertiary: tertiary,
    separator: t.divider,
    sidebarBackground: t.window,
    editorBackground: t.pane,
    gutterBackground: t.pane,
    surfaceBackground: t.pane,
    controlBackground: t.raised,
    controlBorder: t.divider,
    selectedBackground: t.selected,
    selectedBorder: accent,
    focusRing: _legible(accent, grounds, toward: t.text, ratio: 3),
    selection: accent.withAlpha(dark ? 0x4D : 0x40),
    hover: t.selected,
    paperFiber: dark ? const Color(0x00000000) : t.tertiary.withAlpha(0x08),
    paperRuling: t.hairline,
    railBackground: t.window,
    railBorder: t.divider,
    tonalBackground: t.raised,
    tonalForeground: t.text,
    tonalKeyBackground: t.divider,
    tonalKeyText: secondary,
    keycapBackground: t.raised,
    keycapBorder: t.raised,
    keycapText: secondary,
    scrim: dark ? const Color(0xB3000000) : t.text.withAlpha(0x33),
    resultPillBackground: t.chip,
    resultPillText: t.text,
    totalPillBackground: t.accentFill,
    totalPillText: t.onAccent,
    clay: accent,
    clayText: accentText,
    textHeading: t.title,
    textSubheading: t.text,
    textMuted: secondary,
    textDescription: secondary,
    textQuiet: quiet,
    cardBackground: t.card,
    paneEdge: t.divider,
    switchTrackOff: t.switchOff,
    checkboxBorder: t.ring,
    lineCommand: quiet,
    cardTitle: t.text,
    accentText: accentText,
    pageBorder: t.hairline,
    textDivider: t.mark,
    switchThumb: const Color(0xFFFFFFFF),
    wellBackground: t.raised,
    segmentSelected: t.raised,
    shadow: dark ? const Color(0xFF000000) : t.text.withAlpha(0x66),
    accent: accent,
    onAccent: t.onAccent,
    accentFill: t.accentFill,
    codeKeyword: accentText,
    codeString: code(t.dots[4]),
    codeNumber: code(t.dots[0]),
    codeBuiltIn: code(t.dots[3]),
    codePanel: t.card,
    codeChip: t.chip,
    quoteBar: t.ring,
    tagDots: t.dots,
  );
}

/// [c] with every channel [by] steps darker, as far as black.
Color _darker(Color c, int by) => Color.fromARGB(
  (c.a * 255).round(),
  math.max(0, (c.r * 255).round() - by),
  math.max(0, (c.g * 255).round() - by),
  math.max(0, (c.b * 255).round() - by),
);

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

/// [ink] where it already reads at [ratio] on every one of [grounds], and
/// otherwise moved toward [toward] only as far as that takes.
Color _legible(
  Color ink,
  List<Color> grounds, {
  required Color toward,
  double ratio = 4.5,
}) {
  double contrast(Color a, Color b) {
    final x = a.computeLuminance(), y = b.computeLuminance();
    return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
  }

  for (var step = 0; step <= 20; step++) {
    final candidate = _mix(ink, toward, step / 20);
    if (grounds.every((ground) => contrast(candidate, ground) >= ratio)) {
      return candidate;
    }
  }
  return toward;
}
