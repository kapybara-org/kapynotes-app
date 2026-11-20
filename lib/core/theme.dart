import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'editor_font.dart';
import 'platform.dart';

export 'iconography.dart';

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

  bool get _dark => brightness == Brightness.dark;

  /// Code in a note, Paper's p-5-0: clay keywords, sage strings, ochre
  /// numbers and teal built-ins, each a shade deeper in light.
  Color get codeKeyword =>
      _dark ? const Color(0xFFCF7A57) : const Color(0xFFB5552F);
  Color get codeString =>
      _dark ? const Color(0xFFB3C79C) : const Color(0xFF56703C);
  Color get codeNumber =>
      _dark ? const Color(0xFFD4B26A) : const Color(0xFF8A6A1E);
  Color get codeBuiltIn =>
      _dark ? const Color(0xFF8FB3B0) : const Color(0xFF3F7470);

  /// The panel under a code block, a step below the page.
  Color get codePanel =>
      _dark ? const Color(0xFF1E1C19) : const Color(0xFFF6F2E8);

  /// The pill under inline code and a formula's TeX.
  Color get codeChip =>
      _dark ? const Color(0xFF2E2A25) : const Color(0xFFEFEADD);

  /// The rail's icons and labels at rest. Paper's dark rail is a step
  /// lighter than the tertiary ink the rest of the app shares.
  Color get railInk => _dark ? const Color(0xFF8F8778) : textTertiary;

  /// A quote's bar, Paper's.
  Color get quoteBar =>
      _dark ? const Color(0xFF4A453D) : const Color(0xFFD0C8B5);

  /// The same palette with every surface solid: what High Contrast, Reduce
  /// Transparency and a desktop with no blur behind the window all ask for.
  CalcPalette get opaque =>
      isGlass ? copyWith(translucency: 1, paperTranslucency: 1) : this;

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

  /// One row of writing: Paper's 28px line on the page, 29 on a phone.
  static double get lineHeight => page ? 28 : 29;

  /// The writing column on the page. A window narrower than this plus
  /// [padding] gives the column what it has.
  static const double columnWidth = 680;

  /// The note's first line, its title: under twice the writing's size and a
  /// step lighter than a heading's weight, so it names the note without
  /// shouting over it. On the page the meta row sits under it, 10 below the
  /// title and 24 above the body.
  static double get titleFontSize => page ? 30 : 28;
  static double get titleRow => page ? 38 : 36;
  static const FontWeight titleWeight = FontWeight.w500;
  static const double metaGap = 10;
  static const double metaRow = 16;
  static const double metaBottom = 24;
  static double get titleReserve => metaGap + metaRow + metaBottom;

  /// A heading against 16px writing: on the page 22, 19 and 17, each in a
  /// 28px line at the bottom of a row of 40 for the first level and 36 below
  /// it, and a step smaller on a phone. Set with proportional leading, nearly
  /// all of what the row adds goes above the words. Deeper levels are the
  /// writing's own size. Every level stays well under the title.
  static double headingFontSize(int level) => switch (level) {
    <= 1 => page ? 22 : 20,
    2 => page ? 19 : 18,
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
  static const EdgeInsets mobilePadding = EdgeInsets.symmetric(
    horizontal: 18,
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
  /// On a phone, forcing the strut pins every row to exactly [lineHeight]
  /// whatever it contains, which is what its results column was built
  /// against. [allowTallRows] lifts that ceiling for what cannot live under
  /// it: an image is a `WidgetSpan`, and a forced strut clamps a
  /// placeholder's line box to the height of the text, so a 400px picture
  /// would paint straight through the writing beneath it.
  ///
  /// The [page] never forces it: its title, headings and pictures are taller
  /// than a row by design, and [lineHeight] is only the floor. Results there
  /// sit on each line's own last row, measured, so nothing needs rows even.
  static StrutStyle strut(
    WritingFont font, {
    bool allowTallRows = false,
    double editorScale = 1,
  }) {
    final fontSize = font.editorSize * editorScale;
    final rowHeight = lineHeight * editorScale;
    return StrutStyle(
      fontFamily: font.fontFamily,
      fontFamilyFallback: font.fontFamilyFallback,
      fontSize: fontSize,
      height: rowHeight / fontSize,
      forceStrutHeight: !page && !allowTallRows,
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

  /// The capitals over a group of an editor menu's rows, such as TURN INTO in
  /// the selection bubble. Smaller than [micro], because spaced capitals
  /// read larger than lower case at the same size.
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
      ? 21
      : 20;

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

/// The weight ladder for interface text. Same steps as main: rows 400,
/// a selected row 460, a button or chip 500, a section label 520, a page
/// title or a key number 600.
class AppWeight {
  const AppWeight._();

  static const double body = 400;
  static const double selected = 460;
  static const double button = 500;

  /// Old name for [button]. Buttons and chips sit here, not rows.
  static const double rowTitle = button;
  static const double section = 520;
  static const double page = 600;

  static double axisOf(FontWeight weight) {
    final value = weight.value;
    if (value < 400) return value.toDouble();
    if (value <= 400) return body;
    if (value <= 500) return button;
    if (value <= 600) return section;
    return page;
  }

  static FontWeight named(double axis) {
    if (axis < 350) return FontWeight.w300;
    if (axis < 450) return FontWeight.w400;
    if (axis < 510) return FontWeight.w500;
    if (axis < 560) return FontWeight.w600;
    return FontWeight.w700;
  }

  /// [axis] as the platform's Bold Text setting wants it.
  ///
  /// `Text` honours Bold Text by merging `fontWeight: bold`, and an explicit
  /// `wght` axis outranks that merge. A style built here therefore carries
  /// its own bold step, or the whole interface would ignore the setting.
  /// It rebuilds with the rest of the app on
  /// `didChangeAccessibilityFeatures`.
  ///
  /// A consequence, taken deliberately: with Bold Text on, every step from
  /// 500 up reaches 700, so a section label and a page title read alike.
  /// Weight stops carrying their difference there; size and colour still do.
  static double bold(double axis) {
    final features = WidgetsBinding.instance.platformDispatcher
        .accessibilityFeatures;
    if (!features.boldText) return axis;
    return math.min(axis + 200, 700);
  }

  static List<FontVariation> variations(
    double axis, {
    List<FontVariation> extra = const [],
  }) => [
    for (final variation in extra)
      if (variation.axis != 'wght') variation,
    FontVariation('wght', axis),
  ];
}

TextStyle chromeStyle({
  required double size,
  required double line,
  required double weight,
  required Color color,
  String? family,
  List<String>? fallback,
  List<FontVariation> extra = const [],
  bool tabular = false,
}) => TextStyle(
  fontFamily: family ?? AppFonts.ui,
  fontFamilyFallback: fallback ?? AppFonts.uiFallback,
  fontSize: size,
  height: line / size,
  leadingDistribution: TextLeadingDistribution.even,
  fontWeight: AppWeight.named(AppWeight.bold(weight)),
  fontVariations: AppWeight.variations(AppWeight.bold(weight), extra: extra),
  color: color,
  letterSpacing: 0,
  fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
);

class KapyTheme {
  const KapyTheme._();

  /// Riverbank's sage, which marks what is on, done or open: checkboxes,
  /// switches, progress and the open note. Deeper in light, where it carries
  /// light ink.
  static const _darkAccent = Color(0xFF7D9468);
  static const _lightAccent = Color(0xFF56703C);

  /// The accent the theme for [brightness] marks focus, the caret and what is
  /// on with.
  static Color accentFor(Brightness brightness) =>
      brightness == Brightness.dark ? _darkAccent : _lightAccent;

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
    bool transparency = false,
    double amount = defaultGlassAmount,
  }) => _build(
    Brightness.light,
    transparency ? glassPalette(Brightness.light, amount) : lightPalette,
  );
  static ThemeData dark({
    bool transparency = false,
    double amount = defaultGlassAmount,
  }) => _build(
    Brightness.dark,
    transparency ? glassPalette(Brightness.dark, amount) : darkPalette,
  );

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
  static CalcPalette glassPalette(Brightness brightness, double amount) {
    final t = amount.clamp(0.0, 1.0);
    final dark = brightness == Brightness.dark;
    final paper = dark ? _lerp(0.34, 0.05, t) : _lerp(0.44, 0.1, t);
    // The chrome is a step thinner than the paper: a row of buttons needs
    // less body under it than a paragraph does, and the difference is what
    // reads as layers rather than one flat tint. Proportional rather than a
    // fixed step, so the thin end of the scale cannot drive it through zero.
    final chrome = paper * 0.84;
    return (dark ? darkPalette : lightPalette).copyWith(
      translucency: chrome,
      paperTranslucency: paper,
      paperFiber: dark ? null : const Color(0x00000000),
    );
  }

  /// Where the slider starts: see [LayoutPrefs.defaultTransparencyAmount].
  static const double defaultGlassAmount = 0;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static final CalcPalette translucentDarkPalette = glassPalette(
    Brightness.dark,
    defaultGlassAmount,
  );

  static final CalcPalette translucentLightPalette = glassPalette(
    Brightness.light,
    defaultGlassAmount,
  );

  static ThemeData _build(Brightness brightness, CalcPalette palette) {
    final dark = brightness == Brightness.dark;
    final compactControls = AppPlatform.isDesktop;
    final accent = accentFor(brightness);
    final onAccent = dark ? const Color(0xFF1C1A17) : const Color(0xFFFCFAF4);
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
