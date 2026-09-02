import 'value.dart';

/// Where the separators fall inside a grouped integer.
///
/// Only the integer part differs between the two; the decimal point and the
/// separator character are the same either way.
enum DigitGrouping {
  /// Uniform groups of three: `1,234,567`.
  international,

  /// Thousands, then pairs: `12,34,567` — one lakh is `1,00,000` and one
  /// crore is `1,00,00,000`.
  indian,
}

/// Renders results twice: a compact string for the gutter chip, and a
/// full-precision string for the clipboard.
class ResultFormatter {
  const ResultFormatter._();

  /// Grouped, at most 6 decimal places — what the user sees.
  static String display(
    CalcValue value, {
    DigitGrouping grouping = DigitGrouping.international,
  }) {
    if (value is BooleanValue) return value.value ? 'true' : 'false';
    if (value is PercentValue) {
      return _number(value.fraction, 6, group: true, grouping: grouping);
    }
    if (value is NumberValue) {
      return _number(value.value, 6, group: true, grouping: grouping);
    }
    if (value is QuantityValue) {
      // Money reads wrong without exactly two decimals.
      final decimals = value.unit.isCurrency ? 2 : 6;
      final text = _number(
        value.value,
        decimals,
        group: true,
        grouping: grouping,
        fixed: value.unit.isCurrency,
      );
      final unit = value.unit.format();
      return unit.isEmpty ? text : '$text $unit';
    }
    return '';
  }

  /// This formatter's own output for a number big enough to show where the
  /// separators fall, so a settings preview cannot drift from the real thing.
  static String sample(DigitGrouping grouping) =>
      _number(12345678, 0, group: true, grouping: grouping);

  /// Ungrouped and full precision — what lands on the clipboard.
  static String copy(CalcValue value) {
    if (value is BooleanValue) return value.value ? 'true' : 'false';
    if (value is PercentValue) return _number(value.fraction, 12);
    if (value is NumberValue) return _number(value.value, 12);
    if (value is QuantityValue) {
      final text = _number(
        value.value,
        value.unit.isCurrency ? 2 : 12,
        fixed: value.unit.isCurrency,
      );
      final unit = value.unit.format();
      return unit.isEmpty ? text : '$text $unit';
    }
    return '';
  }

  static String _number(
    double raw,
    int maxDecimals, {
    bool group = false,
    DigitGrouping grouping = DigitGrouping.international,
    bool fixed = false,
  }) {
    if (raw.isNaN) return 'NaN';
    if (raw.isInfinite) return raw.isNegative ? '-∞' : '∞';

    final cleaned = _stripFloatNoise(raw);

    // Very large or very small magnitudes are unreadable in positional form.
    final magnitude = cleaned.abs();
    if (magnitude != 0 && (magnitude >= 1e15 || magnitude < 1e-9)) {
      return _trimExponential(cleaned);
    }

    var text = fixed
        ? cleaned.toStringAsFixed(maxDecimals)
        : _toFixedTrimmed(cleaned, maxDecimals);

    if (!group) return text;

    final negative = text.startsWith('-');
    if (negative) text = text.substring(1);
    final dot = text.indexOf('.');
    final intPart = dot == -1 ? text : text.substring(0, dot);
    final fracPart = dot == -1 ? '' : text.substring(dot);
    return '${negative ? '-' : ''}${_group(intPart, grouping)}$fracPart';
  }

  /// 0.1 + 0.2 should read as 0.3, not 0.30000000000000004. Rounding to 12
  /// significant digits removes binary-float artefacts without touching
  /// values the user actually typed.
  static double _stripFloatNoise(double raw) {
    if (raw == 0 || !raw.isFinite) return raw;
    final parsed = double.tryParse(raw.toStringAsPrecision(12));
    return parsed ?? raw;
  }

  static String _toFixedTrimmed(double value, int decimals) {
    var text = value.toStringAsFixed(decimals);
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '');
      text = text.replaceFirst(RegExp(r'\.$'), '');
    }
    // toStringAsFixed can produce "-0"; normalise it away.
    if (text == '-0') return '0';
    return text;
  }

  static String _trimExponential(double value) {
    var text = value.toStringAsExponential(6);
    text = text.replaceFirstMapped(
      RegExp(r'^(-?\d)\.(\d*?)0*e'),
      (m) => m.group(2)!.isEmpty
          ? '${m.group(1)}e'
          : '${m.group(1)}.${m.group(2)}e',
    );
    return text.replaceFirst('e+', 'e');
  }

  /// Splits [digits] from the right. The last three always travel together;
  /// everything above them is cut into groups of three, or of two under
  /// [DigitGrouping.indian].
  static String _group(String digits, DigitGrouping grouping) {
    if (digits.length <= 3) return digits;
    final step = grouping == DigitGrouping.indian ? 2 : 3;
    final groups = <String>[digits.substring(digits.length - 3)];
    var cut = digits.length - 3;
    while (cut > step) {
      groups.add(digits.substring(cut - step, cut));
      cut -= step;
    }
    groups.add(digits.substring(0, cut));
    return groups.reversed.join(',');
  }
}
