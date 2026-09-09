import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'editor_font.dart';
import 'platform.dart';

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

  /// How much of the desktop the window's chrome lets through: a multiplier on
  /// the alpha of every [GlassSurface]. 1 is fully opaque.
  ///
  /// The toolbar, the sidebar and the note footer read this. The writing
  /// surfaces have their own knob, [paperTranslucency], because a paragraph
  /// needs more body under it than a row of buttons does.
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

  /// The sidebar's own fill as painted in this mode.
  Color get sidebarColor => sidebarBackground.withMultipliedAlpha(translucency);

  /// The glass rim: a hairline of light along the top edge of a translucent
  /// surface, the way a real pane catches the light. Nothing in an opaque
  /// palette, so the chrome does not grow an edge with transparency off.
  Color get glassHighlight => !isGlass
      ? const Color(0x00000000)
      : brightness == Brightness.dark
      ? const Color(0x1FFFFFFF)
      : const Color(0x8CFFFFFF);

  /// Which appearance the palette is drawn for, judged from its paper.
  Brightness get brightness =>
      ThemeData.estimateBrightnessForColor(editorBackground);

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

  static const double lineHeight = 29;
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
  static TextStyle textStyle(Color color, WritingFont font) => TextStyle(
    fontFamily: font.fontFamily,
    fontFamilyFallback: font.fontFamilyFallback,
    fontSize: font.editorSize,
    height: lineHeight / font.editorSize,
    color: color,
    letterSpacing: 0,
    wordSpacing: 0,
    fontWeight: FontWeight.w400,
    fontStyle: FontStyle.normal,
    fontVariations: font.fontVariations,
    textBaseline: TextBaseline.alphabetic,
    // A calculator column only lines up with tabular figures.
    fontFeatures: const [FontFeature.tabularFigures()],
    leadingDistribution: TextLeadingDistribution.even,
  );

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
  static double cursorHeight(WritingFont font) => font.editorSize * 1.28;

  /// Width `RenderEditable` reserves beside the text for the caret: a fixed
  /// 1px gap plus the cursor itself. Text wraps inside what is left, so
  /// anything measuring the note has to subtract it or it will place wraps
  /// later than the field does.
  static const double caretMargin = 1.0 + cursorWidth;

  /// The width text actually wraps within, given a field of [fieldWidth].
  static double textLayoutWidth(double fieldWidth) =>
      math.max(0, fieldWidth - caretMargin);

  /// Forcing the strut makes every line exactly [lineHeight] tall regardless
  /// of which fallback font supplies a given glyph — the property the gutter
  /// alignment depends on.
  /// The row geometry of a note.
  ///
  /// Forcing the strut pins every row to exactly [lineHeight] whatever it
  /// contains, which is what gives a note its even rhythm and what the results
  /// gutter was built against. It is the default and it stays the default.
  ///
  /// [allowTallRows] lifts that ceiling for the one case that cannot live
  /// under it: an image is a `WidgetSpan`, and a forced strut clamps a
  /// placeholder's line box to the height of the text, so a 400px picture
  /// would paint straight through the writing beneath it.
  ///
  /// It is opt-in per note rather than switched on everywhere, because
  /// relaxing the strut is not quite free. Flutter takes a line's height as
  /// the union of the strut's ascent and descent with the run's, and two fonts
  /// distribute the same 29px differently — so a heading in the mixed writing
  /// font, which swaps in the handwritten face, comes out about 2px taller
  /// once the strut stops overruling it. A note with pictures in it can afford
  /// that. Every other note in the app should not have to pay it, and this way
  /// none of them do.
  static StrutStyle strut(WritingFont font, {bool allowTallRows = false}) =>
      StrutStyle(
        fontFamily: font.fontFamily,
        fontFamilyFallback: font.fontFamilyFallback,
        fontSize: font.editorSize,
        height: lineHeight / font.editorSize,
        forceStrutHeight: !allowTallRows,
        leading: 0,
      );
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

  static double get footerButtonSlotExtent =>
      footerButtonExtent + footerButtonGap;

  static MaterialTapTargetSize get iconButtonTapTargetSize =>
      AppPlatform.hasPointer
      ? MaterialTapTargetSize.shrinkWrap
      : MaterialTapTargetSize.padded;

  /// Height of a text button, filled button or outlined button.
  static double get buttonHeight => _touch ? 48 : 32;

  /// Actions inside a popover, which is tighter than a dialog but still has to
  /// be hittable. Below [iconButtonExtent] on touch only because a popover is
  /// already anchored under the thumb that opened it.
  static double get popoverActionExtent => _touch ? 40 : 26;

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
  static double get iconAdornment => _touch ? 18 : 15;

  /// A secondary icon that is itself the button.
  static double get iconControl => _touch ? 22 : 16;

  /// A primary icon that is itself the button. The workhorse of every bar.
  static double get iconAction => _touch ? 22 : 17;

  /// Primary and secondary glyphs inside the roomier footer controls.
  ///
  /// These sit one or two points above title-bar glyphs so the repeated strip
  /// reads at the same visual weight as the surrounding editor and sidebar.
  static double get footerIconAction => _touch ? 22 : 19;
  static double get footerIconControl => _touch ? 22 : 18;

  /// Feature icons that head a pane or an empty state.
  static double get iconFeature => _touch ? 26 : 21;

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
/// the call site. The pointer column is the desktop scale as shipped, which is
/// roughly macOS's own 10–16px range for UI text. The touch column is pitched
/// to iOS Dynamic Type at its default Large setting, where 17 is body and 13
/// is the smallest size Apple sets anything a user is meant to actually read —
/// a rule the phone build broke everywhere, since its whole ramp sat between
/// 10.5 and 13.
///
/// As with the icons, touch is the shorter ramp on purpose: desktop steps half
/// a pixel apart collapse into one touch size, because they were never telling
/// the reader anything at that distance.
class AppTypeScale {
  const AppTypeScale._();

  static bool get _touch => !AppPlatform.hasPointer;

  /// The smallest legible annotation: an uppercase section label, a keycap
  /// hint. 10.5 is a real size on a Mac and an unreadable one held at arm's
  /// length, so touch jumps most of the ramp in one step to land on 13 — the
  /// floor Apple sets for anything a reader is expected to parse.
  static double get micro => _touch ? 13 : 10.5;

  /// Metadata, list snippets, the helper line under a control.
  static double get caption => _touch ? 13 : 11.5;

  /// Dense secondary copy that is still read as a sentence.
  static double get small => _touch ? 13.5 : 12;

  /// Running paragraph copy inside dialogs and panes.
  static double get body => _touch ? 15 : 12.5;

  /// The result chip in the gutter.
  ///
  /// Its own step rather than [body], because it is monospace figures inside a
  /// fixed column: the width the note gives up to it is a layout decision, so
  /// the type has to be chosen against that column rather than against the
  /// prose elsewhere. Touch gains what the column can actually seat without
  /// pushing the writing area below half the screen.
  static double get result => _touch ? 14 : 12.5;

  /// Control labels: buttons, list rows, fields, menu items.
  static double get control => _touch ? 15 : 13;

  /// Section titles, the app-bar title, an empty state's first line.
  static double get title => _touch ? 17 : 15;

  /// Dialog titles — the largest step in ordinary chrome.
  static double get heading => _touch ? 20 : 16;

  /// The brand lockup, which is set in its own face and carries its own
  /// optical size a half point off [title].
  static double get wordmark => _touch ? 17 : 14.5;

  /// The lockup on the empty state, the one display-sized thing in the app.
  static double get display => _touch ? 34 : 31;
}

class KapyTheme {
  const KapyTheme._();

  static const brand = Color(0xFFD25C38);
  static const _darkAccent = Color(0xFF6CC4EE);
  static const _lightAccent = Color(0xFFA94A35);

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

  /// The dark palette follows Numi's quiet hierarchy: charcoal surfaces,
  /// neutral writing, one cyan calculation accent, and one green result accent.
  /// Categories remain semantic in the model without turning the page into a
  /// collection of unrelated colours.
  static const CalcPalette darkPalette = CalcPalette(
    number: Color(0xFFE3E7E9),
    keyword: Color(0xFF6CC4EE),
    unit: Color(0xFFE3E7E9),
    currency: Color(0xFFE3E7E9),
    function: Color(0xFF6CC4EE),
    variable: Color(0xFF6CC4EE),
    operator: Color(0xFFB1B5BC),
    comment: Color(0xFF8B8F96),
    chipNumber: Color(0xFF8DD32D),
    chipCurrency: Color(0xFF8DD32D),
    chipUnit: Color(0xFF8DD32D),
    chipBoolean: Color(0xFF8DD32D),
    chipOther: Color(0xFF8DD32D),
    textPrimary: Color(0xFFE7E9EC),
    textSecondary: Color(0xFFB1B4BA),
    textTertiary: Color(0xFF8B8F96),
    separator: Color(0x6636383D),
    sidebarBackground: Color(0xFF1B1C1F),
    editorBackground: Color(0xFF202125),
    gutterBackground: Color(0xFF202125),
    surfaceBackground: Color(0xFF191A1D),
    controlBackground: Color(0xFF25262A),
    controlBorder: Color(0xFF393B40),
    selectedBackground: Color(0xFF2D2F34),
    selectedBorder: Color(0xFF6CC4EE),
    selection: Color(0x456CC4EE),
    hover: Color(0xFF27282D),
    paperFiber: Color(0x00000000),
  );

  /// The same restraint as [darkPalette], pitched for paper: hues are held
  /// back rather than lightened, because light backgrounds need the contrast.
  static const CalcPalette lightPalette = CalcPalette(
    number: Color(0xFF315F91),
    keyword: Color(0xFF79547F),
    unit: Color(0xFF477052),
    currency: Color(0xFF477052),
    function: Color(0xFF986332),
    variable: Color(0xFF356C72),
    operator: Color(0xFF776B5E),
    comment: Color(0xFF7D7164),
    chipNumber: Color(0xFF9B641F),
    chipCurrency: Color(0xFF416D4B),
    chipUnit: Color(0xFF4B688E),
    chipBoolean: Color(0xFF9A5739),
    chipOther: Color(0xFF70675B),
    textPrimary: Color(0xFF243245),
    textSecondary: Color(0xFF625B52),
    textTertiary: Color(0xFF786F64),
    separator: Color(0x24745F48),
    sidebarBackground: Color(0xF5F0E8D9),
    editorBackground: Color(0xFFF8F2E5),
    gutterBackground: Color(0xF5F2E9D8),
    surfaceBackground: Color(0xFCFCF8EF),
    controlBackground: Color(0xCFFFFCF5),
    controlBorder: Color(0x32765F45),
    selectedBackground: Color(0x177A6046),
    selectedBorder: Color(0x6CA94A35),
    selection: Color(0x3DD25C38),
    hover: Color(0x0F614A32),
    paperFiber: Color(0x187D674E),
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
  static const double defaultGlassAmount = 0.2;

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
    final accent = dark ? _darkAccent : _lightAccent;
    final onAccent = dark ? const Color(0xFF15171A) : Colors.white;
    final buttonHeight = AppControlMetrics.buttonHeight;
    final iconButtonExtent = AppControlMetrics.iconButtonExtent;
    final tapTarget = compactControls
        ? MaterialTapTargetSize.shrinkWrap
        : MaterialTapTargetSize.padded;

    final scheme =
        ColorScheme.fromSeed(
          seedColor: dark ? _darkAccent : brand,
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
      scaffoldBackgroundColor: palette.editorBackground,
      // Desktop wants tighter controls than the phone default.
      visualDensity: AppPlatform.isDesktop
          ? VisualDensity.compact
          : VisualDensity.standard,
      splashFactory: AppPlatform.isDesktop ? NoSplash.splashFactory : null,
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
      textTheme: base.textTheme.apply(
        bodyColor: palette.textPrimary,
        displayColor: palette.textPrimary,
      ),
      appBarTheme: AppBarThemeData(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: palette.textPrimary,
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
          color: palette.textPrimary,
          fontSize: AppTypeScale.title,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.1,
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrimColor: Colors.black.withValues(alpha: dark ? 0.38 : 0.20),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surfaceBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
          color: palette.textPrimary,
          fontSize: AppTypeScale.heading,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: palette.controlBorder, width: 0.5),
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
          borderRadius: BorderRadius.circular(9),
          side: BorderSide(color: palette.controlBorder, width: 0.5),
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
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: Size(0, buttonHeight),
          padding: EdgeInsets.symmetric(horizontal: compactControls ? 12 : 18),
          tapTargetSize: tapTarget,
          elevation: 0,
          shadowColor: Colors.transparent,
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: palette.controlBackground,
          disabledForegroundColor: palette.textTertiary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontSize: AppTypeScale.control,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: Size(0, buttonHeight),
          padding: EdgeInsets.symmetric(horizontal: compactControls ? 12 : 18),
          tapTargetSize: tapTarget,
          elevation: 0,
          foregroundColor: palette.textPrimary,
          side: BorderSide(color: palette.controlBorder, width: 0.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontSize: AppTypeScale.control,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: Size(0, buttonHeight),
          padding: EdgeInsets.symmetric(horizontal: compactControls ? 10 : 14),
          tapTargetSize: tapTarget,
          foregroundColor: accent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontSize: AppTypeScale.control,
            fontWeight: FontWeight.w500,
          ),
        ),
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
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        textStyle: base.textTheme.bodySmall?.copyWith(
          fontSize: AppTypeScale.caption,
          color: palette.textPrimary,
        ),
        decoration: BoxDecoration(
          color: palette.surfaceBackground,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: palette.controlBorder, width: 0.5),
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
