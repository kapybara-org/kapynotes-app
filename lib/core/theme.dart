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
  static StrutStyle strut(WritingFont font) => StrutStyle(
    fontFamily: font.fontFamily,
    fontFamilyFallback: font.fontFamilyFallback,
    fontSize: font.editorSize,
    height: lineHeight / font.editorSize,
    forceStrutHeight: true,
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
/// [AppPlatform.hasPointer]. The pointer column is the desktop design as
/// shipped and is deliberately byte-for-byte unchanged — the desktop goldens
/// are the proof. The touch column is the part being fixed, and it is pitched
/// from the iOS HIG and Material 3 rather than scaled down from the desktop.
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
  /// 40 fits a 24pt desktop action with margin. It cannot fit a 44pt one, and
  /// clamping the row to 40 is what silently cut the phone's formatting
  /// buttons back below the minimum target no matter what the button itself
  /// asked for. 56 is 44 plus a 6pt gutter each side.
  static double get footerHeight => _touch ? 56 : 40;

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

  /// Feature icons that head a pane or an empty state.
  static double get iconFeature => _touch ? 26 : 21;

  /// What an `Icon` with no size of its own gets, via the theme.
  static double get iconDefault => _touch ? 22 : 18;

  /// The brand mark in the toolbar and sidebar lockups.
  static double get wordmarkMark => _touch ? 22 : 19;

  /// The same mark at empty-state size.
  static double get wordmarkMarkLarge => _touch ? 56 : 48;

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

  static ThemeData light() => _build(Brightness.light, lightPalette);
  static ThemeData dark() => _build(Brightness.dark, darkPalette);

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
    operator: Color(0xFFA2A6AC),
    comment: Color(0xFF71757C),
    chipNumber: Color(0xFF8DD32D),
    chipCurrency: Color(0xFF8DD32D),
    chipUnit: Color(0xFF8DD32D),
    chipBoolean: Color(0xFF8DD32D),
    chipOther: Color(0xFF8DD32D),
    textPrimary: Color(0xFFE3E7E9),
    textSecondary: Color(0xFFA2A6AC),
    textTertiary: Color(0xFF71757C),
    separator: Color(0x6636383D),
    sidebarBackground: Color(0xFF1F2024),
    editorBackground: Color(0xFF212226),
    gutterBackground: Color(0xFF212226),
    surfaceBackground: Color(0xFF202125),
    controlBackground: Color(0xFF292A2F),
    controlBorder: Color(0xFF36383D),
    selectedBackground: Color(0xFF303137),
    selectedBorder: Color(0xFF6CC4EE),
    selection: Color(0x456CC4EE),
    hover: Color(0xFF292A2F),
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
    operator: Color(0xFF897A69),
    comment: Color(0xFF998874),
    chipNumber: Color(0xFF9B641F),
    chipCurrency: Color(0xFF416D4B),
    chipUnit: Color(0xFF4B688E),
    chipBoolean: Color(0xFF9A5739),
    chipOther: Color(0xFF70675B),
    textPrimary: Color(0xFF26364A),
    textSecondary: Color(0xFF675F53),
    textTertiary: Color(0xFF958776),
    separator: Color(0x24745F48),
    sidebarBackground: Color(0xF2EEE3CC),
    editorBackground: Color(0xFFF7F0DE),
    gutterBackground: Color(0xF2F0E5CE),
    surfaceBackground: Color(0xFAFBF5E8),
    controlBackground: Color(0xB3FFF9EA),
    controlBorder: Color(0x26765F45),
    selectedBackground: Color(0x177A6046),
    selectedBorder: Color(0x6CA94A35),
    selection: Color(0x3DD25C38),
    hover: Color(0x0F614A32),
    paperFiber: Color(0x187D674E),
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
      shadowColor: Colors.black.withValues(alpha: dark ? 0.22 : 0.10),
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
          fontWeight: FontWeight.w600,
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
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.24 : 0.10),
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
          color: palette.textPrimary,
          fontSize: AppTypeScale.heading,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: palette.controlBorder, width: 0.5),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.surfaceBackground,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.24 : 0.10),
        elevation: 2,
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
            fontWeight: FontWeight.w600,
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
            fontWeight: FontWeight.w600,
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
        waitDuration: const Duration(milliseconds: 600),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        textStyle: base.textTheme.bodySmall?.copyWith(
          fontSize: AppTypeScale.caption,
          color: palette.textPrimary,
        ),
        decoration: BoxDecoration(
          color: palette.surfaceBackground,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: palette.controlBorder, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.18 : 0.07),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Convenience accessor: `context.palette`.
extension CalcPaletteAccess on BuildContext {
  CalcPalette get palette => Theme.of(this).extension<CalcPalette>()!;
}
