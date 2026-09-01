import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

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
    );
  }
}

/// Editor metrics shared by the text field, its measurer and the gutter.
/// Any mismatch between these three shows up as misaligned results, so they
/// are defined exactly once.
class EditorMetrics {
  const EditorMetrics._();

  static const double fontSize = 14.5;
  static const double lineHeight = 28;
  static const double heightFactor = lineHeight / fontSize;
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
  static TextStyle textStyle(Color color) => TextStyle(
    fontFamily: AppPlatform.monoFontFallback.first,
    fontFamilyFallback: AppPlatform.monoFontFallback,
    fontSize: fontSize,
    height: heightFactor,
    color: color,
    letterSpacing: 0,
    wordSpacing: 0,
    fontWeight: FontWeight.w400,
    fontStyle: FontStyle.normal,
    textBaseline: TextBaseline.alphabetic,
    // A calculator column only lines up with tabular figures.
    fontFeatures: const [FontFeature.tabularFigures()],
    leadingDistribution: TextLeadingDistribution.even,
  );

  static const double cursorWidth = 1.7;

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
  static const StrutStyle strut = StrutStyle(
    fontFamily: 'SF Mono',
    fontFamilyFallback: AppPlatform.monoFontFallback,
    fontSize: fontSize,
    height: heightFactor,
    forceStrutHeight: true,
    leading: 0,
  );
}

class KapyTheme {
  const KapyTheme._();

  static const brand = Color(0xFFD25C38);
  static const _darkAccent = Color(0xFFF07856);
  static const _lightAccent = Color(0xFFB9472E);

  static ThemeData light() => _build(Brightness.light, lightPalette);
  static ThemeData dark() => _build(Brightness.dark, darkPalette);

  static const CalcPalette darkPalette = CalcPalette(
    number: Color(0xFF79B9FF),
    keyword: Color(0xFFD39AF2),
    unit: Color(0xFF7AD99B),
    currency: Color(0xFF65D889),
    function: Color(0xFFF0A45E),
    variable: Color(0xFF70CBDD),
    operator: Color(0xFF8E8984),
    comment: Color(0xFF716D69),
    chipNumber: Color(0xFF69AFFF),
    chipCurrency: Color(0xFF5FD987),
    chipUnit: Color(0xFFC990EE),
    chipBoolean: Color(0xFFEFA15A),
    chipOther: Color(0xFFAAA59F),
    textPrimary: Color(0xFFF2F1EE),
    textSecondary: Color(0xFFAAA7A2),
    textTertiary: Color(0xFF7A7671),
    separator: Color(0x16FFFFFF),
    sidebarBackground: Color(0xEC20201F),
    editorBackground: Color(0xFF181817),
    gutterBackground: Color(0xE61A1A19),
    surfaceBackground: Color(0xF0242423),
    controlBackground: Color(0x0FFFFFFF),
    controlBorder: Color(0x16FFFFFF),
    selectedBackground: Color(0x16FFFFFF),
    selectedBorder: Color(0x66F07856),
    selection: Color(0x52D25C38),
    hover: Color(0x12FFFFFF),
  );

  static const CalcPalette lightPalette = CalcPalette(
    number: Color(0xFF1766B5),
    keyword: Color(0xFF8438AE),
    unit: Color(0xFF247B49),
    currency: Color(0xFF1F7844),
    function: Color(0xFFA65720),
    variable: Color(0xFF176F7D),
    operator: Color(0xFF817B76),
    comment: Color(0xFF98918B),
    chipNumber: Color(0xFF1769BF),
    chipCurrency: Color(0xFF237D49),
    chipUnit: Color(0xFF8539AD),
    chipBoolean: Color(0xFFA75C25),
    chipOther: Color(0xFF77716C),
    textPrimary: Color(0xFF24211F),
    textSecondary: Color(0xFF706B66),
    textTertiary: Color(0xFF9B958F),
    separator: Color(0x1617120F),
    sidebarBackground: Color(0xEEF2F1EE),
    editorBackground: Color(0xFFFAF9F7),
    gutterBackground: Color(0xEAF7F6F3),
    surfaceBackground: Color(0xF7FFFFFF),
    controlBackground: Color(0x99FFFFFF),
    controlBorder: Color(0x1417120F),
    selectedBackground: Color(0x0F17120F),
    selectedBorder: Color(0x59B9472E),
    selection: Color(0x3DD25C38),
    hover: Color(0x0B17120F),
  );

  static ThemeData _build(Brightness brightness, CalcPalette palette) {
    final dark = brightness == Brightness.dark;
    final accent = dark ? _darkAccent : _lightAccent;
    final onAccent = dark ? const Color(0xFF2D130C) : Colors.white;

    final scheme =
        ColorScheme.fromSeed(seedColor: brand, brightness: brightness).copyWith(
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
      iconTheme: IconThemeData(color: palette.textSecondary, size: 18),
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
          fontSize: 15,
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
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.24 : 0.10),
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
          color: palette.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: palette.controlBorder, width: 0.5),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.surfaceBackground,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.24 : 0.10),
        elevation: 4,
        menuPadding: const EdgeInsets.all(6),
        position: PopupMenuPosition.under,
        textStyle: base.textTheme.bodyMedium?.copyWith(
          fontSize: 13,
          color: palette.textPrimary,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: palette.controlBorder, width: 0.5),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
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
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          shadowColor: Colors.transparent,
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: palette.controlBackground,
          disabledForegroundColor: palette.textTertiary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          elevation: 0,
          foregroundColor: palette.textPrimary,
          side: BorderSide(color: palette.controlBorder, width: 0.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
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
        thickness: const WidgetStatePropertyAll(4),
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
          fontSize: 11.5,
          color: palette.textPrimary,
        ),
        decoration: BoxDecoration(
          color: palette.surfaceBackground,
          borderRadius: BorderRadius.circular(10),
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
