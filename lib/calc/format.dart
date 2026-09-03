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

/// Renders results for the gutter chip, its explanatory tooltip, and the
/// clipboard.
class ResultFormatter {
  const ResultFormatter._();

  static const List<String> _smallNumbers = [
    'zero',
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
    'ten',
    'eleven',
    'twelve',
    'thirteen',
    'fourteen',
    'fifteen',
    'sixteen',
    'seventeen',
    'eighteen',
    'nineteen',
  ];

  static const List<String> _tens = [
    '',
    '',
    'twenty',
    'thirty',
    'forty',
    'fifty',
    'sixty',
    'seventy',
    'eighty',
    'ninety',
  ];

  static const List<String> _internationalScales = [
    '',
    'thousand',
    'million',
    'billion',
    'trillion',
  ];

  static const List<String> _digitWords = [
    'zero',
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
  ];

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

  /// A plain-language explanation for a result-chip hover.
  ///
  /// The words use the same number system as the visible result. Large
  /// values also include a quick conversion to millions or crores, which is
  /// often easier to scan than either the grouped digits or the full phrase.
  static String tooltip(
    CalcValue value, {
    DigitGrouping grouping = DigitGrouping.international,
  }) {
    if (value is BooleanValue) return 'Copy result';

    final raw = _rawNumber(value);
    if (raw == null) return 'Copy result';

    final suffix = value is QuantityValue ? value.unit.format() : '';
    final spoken = _capitalize(
      '${_numberInWords(raw, _displayDecimals(value), grouping)}'
      '${suffix.isEmpty ? '' : ' $suffix'}',
    );
    final scaled = _scaledValue(raw, grouping, suffix);

    return [spoken, ?scaled, 'Click to copy'].join('\n');
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

  static double? _rawNumber(CalcValue value) => switch (value) {
    NumberValue() => value.value,
    PercentValue() => value.fraction,
    QuantityValue() => value.value,
    BooleanValue() => null,
  };

  static int _displayDecimals(CalcValue value) =>
      value is QuantityValue && value.unit.isCurrency ? 2 : 6;

  static String _numberInWords(
    double raw,
    int maxDecimals,
    DigitGrouping grouping,
  ) {
    if (raw.isNaN) return 'not a number';
    if (raw.isInfinite) {
      return raw.isNegative ? 'negative infinity' : 'infinity';
    }

    final cleaned = _stripFloatNoise(raw);
    final magnitude = cleaned.abs();
    if (magnitude != 0 && (magnitude >= 1e15 || magnitude < 1e-9)) {
      return _scientificInWords(_trimExponential(cleaned));
    }

    return _decimalInWords(_toFixedTrimmed(cleaned, maxDecimals), grouping);
  }

  static String _decimalInWords(String raw, DigitGrouping grouping) {
    var text = raw;
    final negative = text.startsWith('-');
    if (negative) text = text.substring(1);

    final parts = text.split('.');
    final integer = int.tryParse(parts.first) ?? 0;
    final integerWords = grouping == DigitGrouping.indian
        ? _indianInteger(integer)
        : _internationalInteger(integer);
    final fraction = parts.length == 1
        ? ''
        : ' point ${parts.last.split('').map((digit) => _digitWords[int.parse(digit)]).join(' ')}';
    return '${negative ? 'negative ' : ''}$integerWords$fraction';
  }

  static String _scientificInWords(String raw) {
    final marker = raw.indexOf('e');
    if (marker == -1) return raw;
    final coefficient = _decimalInWords(
      raw.substring(0, marker),
      DigitGrouping.international,
    );
    final exponent = int.parse(raw.substring(marker + 1));
    final exponentWords = exponent < 0
        ? 'negative ${_internationalInteger(exponent.abs())}'
        : _internationalInteger(exponent);
    return '$coefficient times ten to the power of $exponentWords';
  }

  static String _internationalInteger(int value) {
    if (value == 0) return _smallNumbers.first;

    var remaining = value;
    var scale = 0;
    final groups = <String>[];
    while (remaining > 0) {
      final chunk = remaining % 1000;
      if (chunk != 0) {
        final label = _internationalScales[scale];
        groups.add('${_underThousand(chunk)}${label.isEmpty ? '' : ' $label'}');
      }
      remaining ~/= 1000;
      scale++;
    }
    return groups.reversed.join(' ');
  }

  /// Indian English ordinarily keeps using crore for very large financial
  /// values (for example, `one lakh crore`) instead of switching to the less
  /// familiar arab/kharab scale names.
  static String _indianInteger(int value) {
    if (value == 0) return _smallNumbers.first;
    if (value >= 10000000) {
      final crores = value ~/ 10000000;
      final rest = value % 10000000;
      return '${_indianInteger(crores)} crore'
          '${rest == 0 ? '' : ' ${_indianBelowCrore(rest)}'}';
    }
    return _indianBelowCrore(value);
  }

  static String _indianBelowCrore(int value) {
    var remaining = value;
    final parts = <String>[];

    final lakhs = remaining ~/ 100000;
    if (lakhs > 0) {
      parts.add('${_underThousand(lakhs)} lakh');
      remaining %= 100000;
    }

    final thousands = remaining ~/ 1000;
    if (thousands > 0) {
      parts.add('${_underThousand(thousands)} thousand');
      remaining %= 1000;
    }

    if (remaining > 0) parts.add(_underThousand(remaining));
    return parts.join(' ');
  }

  static String _underThousand(int value) {
    if (value < 100) return _underHundred(value);
    final hundreds = value ~/ 100;
    final rest = value % 100;
    return '${_smallNumbers[hundreds]} hundred'
        '${rest == 0 ? '' : ' ${_underHundred(rest)}'}';
  }

  static String _underHundred(int value) {
    if (value < 20) return _smallNumbers[value];
    final tens = value ~/ 10;
    final ones = value % 10;
    return '${_tens[tens]}${ones == 0 ? '' : '-${_smallNumbers[ones]}'}';
  }

  static String? _scaledValue(
    double raw,
    DigitGrouping grouping,
    String suffix,
  ) {
    if (!raw.isFinite) return null;
    final (divisor, label) = grouping == DigitGrouping.indian
        ? (10000000.0, 'crore')
        : (1000000.0, 'million');
    // Once a value reaches seven digits, its selected large-number unit is
    // useful even when that means a fractional crore (for example, 0.7
    // crore). Smaller values read more clearly without the extra line.
    if (raw.abs() < 1000000) return null;

    final scaled = _number(raw / divisor, 6, group: true, grouping: grouping);
    return '$scaled $label${suffix.isEmpty ? '' : ' $suffix'}';
  }

  static String _capitalize(String value) =>
      value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

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
