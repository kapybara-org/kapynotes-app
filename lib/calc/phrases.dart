import '../data/time_zones.dart';
import 'unit.dart';
import 'unit_registry.dart';
import 'value.dart';

/// The whole-line phrases the calculator reads as people say them, the way
/// Raycast's does: money (`20% vat in 120`), shorthand (`USD1K`, `20 cents`),
/// words for maths (`square root of 625`), dates (`days until 31 Mar`),
/// durations (`145 mins to timespan`) and fractions (`1.75 as fraction`).
///
/// A phrase either becomes an ordinary expression that the parser evaluates,
/// so its units and currencies behave as everywhere else, or is worked out
/// here from the injected clock. Every phrase is anchored to the whole line,
/// so prose that merely holds the same words stays prose.
class Phrases {
  final UnitRegistry registry;
  final DateTime Function() now;
  final String? timeZoneId;

  const Phrases({
    required this.registry,
    required this.now,
    required this.timeZoneId,
  });

  /// The words a phrase line adds to the calculator's own, coloured and
  /// explained like its keywords.
  static const Set<String> words = {
    'vat',
    'split',
    'decrease',
    'increase',
    'from',
    'until',
    'since',
    'left',
    'week',
    'timespan',
    'mixed',
    'fraction',
    'improper',
    'power',
    'root',
    'square',
  };

  static const String _number = r'(\d+(?:\.\d+)?)';
  static const String _month =
      r'(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|'
      r'aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)';
  static const String _clock =
      r'(\d{1,2}(?::\d{2})?\s*(?:am|pm)|\d{1,2}:\d{2})';

  static RegExp _re(String source) =>
      RegExp('^(?:$source)\$', caseSensitive: false);

  static final RegExp _vat = _re('$_number\\s*%\\s*vat\\s+in\\s+(.+)');
  static final RegExp _offSplit = _re(
    '$_number\\s*%\\s*off\\s+(.+?)\\s+split\\s+(.+)',
  );
  static final RegExp _change = _re(
    '$_number\\s*%\\s*(decrease|increase)\\s+from\\s+(.+)',
  );
  static final RegExp _asPercent = _re(r'(.+?)\s+(?:as|is\s+what)\s+%');
  static final RegExp _thousands = _re(r'([$€£¥₹])?\s*(\d+(?:\.\d+)?)K');
  static final RegExp _codeShorthand = RegExp(
    r'^(?:([A-Z]{3})\s*(\d+(?:\.\d+)?)\s*([KM])?)$',
  );

  /// The currency each word for a whole unit of money stands for, in English,
  /// Hindi and Hinglish.
  static const Map<String, String> _majors = {
    'dollars': 'usd',
    'dollar': 'usd',
    'bucks': 'usd',
    'buck': 'usd',
    'डॉलर': 'usd',
    'rupees': 'inr',
    'rupee': 'inr',
    'rupaye': 'inr',
    'rupay': 'inr',
    'rs.': 'inr',
    'rs': 'inr',
    'रुपये': 'inr',
    'रुपए': 'inr',
    'रुपया': 'inr',
    'रु.': 'inr',
    'रु': 'inr',
    'euros': 'eur',
    'euro': 'eur',
    'pounds': 'gbp',
    'pound': 'gbp',
  };

  /// The words the registry has no unit for, which are rewritten to a code.
  static const Set<String> _unknownMajors = {
    'bucks',
    'buck',
    'डॉलर',
    'rupaye',
    'rupay',
    'rs.',
    'rs',
    'रुपये',
    'रुपए',
    'रुपया',
    'रु.',
    'रु',
  };

  /// The words for a hundredth of a unit, each with the currencies it is a
  /// hundredth of; the first is the one it stands for on its own.
  static const Map<String, Set<String>> _minors = {
    'cents': {'usd', 'eur'},
    'cent': {'usd', 'eur'},
    'सेंट': {'usd', 'eur'},
    'paise': {'inr'},
    'paisa': {'inr'},
    'पैसे': {'inr'},
    'पैसा': {'inr'},
    'pence': {'gbp'},
    'pennies': {'gbp'},
    'penny': {'gbp'},
  };

  static String _alternatives(Iterable<String> words) =>
      (words.toList()..sort((a, b) => b.length.compareTo(a.length)))
          .map(RegExp.escape)
          .join('|');

  static const String _end = r'(?![\p{L}\p{M}\p{N}])';

  static RegExp _spokenPattern(String source) =>
      RegExp(source, caseSensitive: false, unicode: true);

  static final RegExp _compoundAmount = _spokenPattern(
    '$_number\\s*(${_alternatives(_majors.keys)})$_end'
    '\\s*(?:(?:and|और)\\s+)?$_number\\s*(${_alternatives(_minors.keys)})$_end',
  );

  /// The words that scale the number before them, as in '2.5 lakh'.
  static const Map<String, double> _scales = {
    'lakhs': 1e5,
    'lakh': 1e5,
    'lacs': 1e5,
    'lac': 1e5,
    'लाख': 1e5,
    'crores': 1e7,
    'crore': 1e7,
    'करोड\u093C': 1e7,
    'करोड': 1e7,
    'हज\u093Cार': 1e3,
    'हजार': 1e3,
  };

  static final String _scale = _alternatives(_scales.keys);
  static final String _currency =
      '${_alternatives(_majors.keys)}|usd|inr|eur|gbp|jpy|cad|aud|aed|sgd|chf|cny';

  /// A scale word counts only with a currency attached, a symbol before the
  /// number or a currency word or code after the scale, so '2 lakh people'
  /// stays prose.
  static final RegExp _scaled = _spokenPattern(
    r'(?:(?<=[$€£¥₹]\s*)|(?=\d+(?:\.\d+)?\s*(?:' +
        _scale +
        r')' +
        _end +
        r'\s*(?:' +
        _currency +
        r')' +
        _end +
        '))' +
        _number +
        r'\s*(' +
        _scale +
        r')' +
        _end,
  );

  static final RegExp _minorAlone = _spokenPattern(
    '$_number\\s*(euro\\s+cents?|${_alternatives(_minors.keys)})$_end',
  );
  static final RegExp _majorAlone = _spokenPattern(
    '$_number\\s*(${_alternatives(_unknownMajors)})$_end',
  );

  /// [text] with the Devanagari letters that carry a dot written as the letter
  /// and the dot, so a word reads the same however it was typed.
  static String _decomposed(String text) => text.replaceAllMapped(
    RegExp('[\u0958-\u095F]'),
    (m) => String.fromCharCodes([
      const [
        0x0915,
        0x0916,
        0x0917,
        0x091C,
        0x0921,
        0x0922,
        0x092B,
        0x092F,
      ][m.group(0)!.codeUnitAt(0) - 0x0958],
      0x093C,
    ]),
  );

  /// [text] with its spoken amounts written as ordinary ones, '15 dollars and
  /// 20 cents' as '15.2 usd', or null where it holds none.
  static String? spoken(String source) {
    final text = _decomposed(source);
    var written = text.replaceAllMapped(
      _scaled,
      (m) =>
          '${double.parse(m.group(1)!) * _scales[m.group(2)!.toLowerCase()]!}',
    );
    written = written.replaceAllMapped(_compoundAmount, (m) {
      final code = _majors[m.group(2)!.toLowerCase()]!;
      if (!_minors[m.group(4)!.toLowerCase()]!.contains(code)) {
        return m.group(0)!;
      }
      final whole = double.parse(m.group(1)!);
      return '${whole + double.parse(m.group(3)!) / 100} $code';
    });
    written = written.replaceAllMapped(_minorAlone, (m) {
      final name = m.group(2)!.toLowerCase();
      final code = name.startsWith('euro') ? 'eur' : _minors[name]!.first;
      return '${double.parse(m.group(1)!) / 100} $code';
    });
    written = written.replaceAllMapped(
      _majorAlone,
      (m) => '${m.group(1)} ${_majors[m.group(2)!.toLowerCase()]}',
    );
    return written == _decomposed(source) ? null : written;
  }

  static final RegExp _squareRoot = _re(r'square\s+root\s+of\s+(.+)');
  static final RegExp _power = _re(r'(.+?)\s+power\s+(.+)');
  static final RegExp _fraction = _re(
    r'(.+?)\s+(?:as|to|in)\s+(fraction|improper|mixed)',
  );
  static final RegExp _timespan = _re(r'(.+?)\s+(?:as|to|in)\s+timespan');
  static final RegExp _yearsAndMonths = _re(
    r'(.+?)\s+(?:as|to|in)\s+years\s+and\s+months',
  );
  static final RegExp _daysUntil = _re(r'days\s+(until|since)\s+(.+)');
  static final RegExp _daysLeft = _re(
    r'(work)?days\s+left\s+in\s+(?:this|the)\s+month',
  );
  static final RegExp _week = _re(r'week\s+(\d{1,2})\s+(\d{4})');
  static final RegExp _weekdayIn = _re(
    r'(mon|tue|wed|thu|fri|sat|sun)[a-z]*\s+in\s+(\d+)\s+weeks?',
  );
  static final RegExp _monthDayPlus = _re(
    '$_month\\s+(\\d{1,2})\\s*\\+\\s*(\\d+)',
  );
  static final RegExp _clockSpan = _re('$_clock\\s+to\\s+$_clock');
  static final RegExp _unixSpan = _re(r'from\s+(\d{9,})\s+to\s+(\d{9,})');

  static final List<RegExp> _wholeLine = [
    _vat,
    _offSplit,
    _change,
    _asPercent,
    _thousands,
    _codeShorthand,
    _squareRoot,
    _power,
    _fraction,
    _timespan,
    _yearsAndMonths,
    _daysUntil,
    _daysLeft,
    _week,
    _weekdayIn,
    _monthDayPlus,
    _clockSpan,
    _unixSpan,
  ];

  /// Whether [line] is worded as one of the phrases, which makes it a
  /// calculation even where it holds no digit, as `days left in this month`
  /// does not.
  static bool recognizes(String line) {
    final text = line.trim();
    return _wholeLine.any((pattern) => pattern.hasMatch(text));
  }

  /// What [source] says as a phrase, or null if it is not one. [evaluate]
  /// reads an ordinary expression, giving null for one that has no value.
  ///
  /// [usesClock] is set when the answer depends on today's date.
  CalcValue? read(
    String source,
    CalcValue? Function(String expression) evaluate, {
    required void Function() usesClock,
  }) {
    final text = source.trim().replaceAll(RegExp(r'\s+'), ' ');
    Match? match;

    if ((match = _vat.firstMatch(text)) != null) {
      final price = match!.group(2)!;
      return evaluate('($price) - ($price) / (1 + ${match.group(1)}%)');
    }
    if ((match = _offSplit.firstMatch(text)) != null) {
      return evaluate(
        '((${match!.group(2)}) - ${match.group(1)}%) / (${match.group(3)})',
      );
    }
    if ((match = _change.firstMatch(text)) != null) {
      final sign = match!.group(2)!.toLowerCase() == 'decrease' ? '-' : '+';
      return evaluate('(${match.group(3)}) $sign ${match.group(1)}%');
    }
    if ((match = _asPercent.firstMatch(text)) != null) {
      final value = evaluate(match!.group(1)!);
      if (value is! NumberValue && value is! FormattedNumberValue) return null;
      return PhraseValue('${_trim(Arith.scalar(value!) * 100)}%');
    }
    if ((match = _thousands.firstMatch(text)) != null) {
      final amount = double.parse(match!.group(2)!) * 1000;
      return evaluate('${match.group(1) ?? ''}$amount');
    }
    if ((match = _codeShorthand.firstMatch(text)) != null) {
      final scale = switch (match!.group(3)) {
        'K' => 1e3,
        'M' => 1e6,
        _ => 1.0,
      };
      final value = evaluate(
        '${double.parse(match.group(2)!) * scale} ${match.group(1)}',
      );
      return value is QuantityValue && value.unit.isCurrency ? value : null;
    }
    if ((match = _squareRoot.firstMatch(text)) != null) {
      return evaluate('sqrt(${match!.group(1)})');
    }
    if ((match = _power.firstMatch(text)) != null) {
      return evaluate('(${match!.group(1)}) ^ (${match.group(2)})');
    }
    if ((match = _fraction.firstMatch(text)) != null) {
      final value = evaluate(match!.group(1)!);
      final form = match.group(2)!.toLowerCase();
      if (value is QuantityValue && _isTime(value) && form == 'mixed') {
        return PhraseValue(_timespanText(value.linearBase));
      }
      if (value is! NumberValue && value is! FormattedNumberValue) return null;
      final text = _fractionText(
        Arith.scalar(value!),
        improper: form == 'improper',
      );
      return text == null ? null : PhraseValue(text);
    }
    if ((match = _timespan.firstMatch(text)) != null) {
      final value = evaluate(match!.group(1)!);
      if (value is! QuantityValue || !_isTime(value)) return null;
      return PhraseValue(_timespanText(value.linearBase));
    }
    if ((match = _yearsAndMonths.firstMatch(text)) != null) {
      final value = evaluate(match!.group(1)!);
      final month = registry.lookup('month');
      if (value is! QuantityValue || !_isTime(value) || month == null) {
        return null;
      }
      final months = (Arith.convert(value, Unit.single(month)) as QuantityValue)
          .value
          .round();
      final years = months ~/ 12;
      return PhraseValue(
        [
          if (years != 0) '$years ${years == 1 ? 'year' : 'years'}',
          if (months % 12 != 0 || years == 0)
            '${months % 12} ${months % 12 == 1 ? 'month' : 'months'}',
        ].join(' '),
      );
    }

    final today = _today();
    if ((match = _daysUntil.firstMatch(text)) != null) {
      usesClock();
      return _daysBetween(
        match!.group(1)!.toLowerCase() == 'until',
        match.group(2)!,
        today,
      );
    }
    if ((match = _daysLeft.firstMatch(text)) != null) {
      usesClock();
      final end = DateTime.utc(today.year, today.month + 1, 0);
      var days = 0;
      for (
        var day = today.add(const Duration(days: 1));
        !day.isAfter(end);
        day = day.add(const Duration(days: 1))
      ) {
        if (match!.group(1) == null || day.weekday <= DateTime.friday) days++;
      }
      return match!.group(1) == null
          ? _days(days)
          : PhraseValue('$days ${days == 1 ? 'workday' : 'workdays'}');
    }
    if ((match = _week.firstMatch(text)) != null) {
      final number = int.parse(match!.group(1)!);
      final year = int.parse(match.group(2)!);
      if (number < 1 || number > 53) return null;
      final january = DateTime.utc(year, 1, 4);
      final first = january.subtract(Duration(days: january.weekday - 1));
      final start = first.add(Duration(days: 7 * (number - 1)));
      final end = start.add(const Duration(days: 6));
      if (end.year < year || start.year > year) return null;
      return PhraseValue(_range(start, end));
    }
    if ((match = _weekdayIn.firstMatch(text)) != null) {
      usesClock();
      final weekday =
          const [
            'mon',
            'tue',
            'wed',
            'thu',
            'fri',
            'sat',
            'sun',
          ].indexOf(match!.group(1)!.toLowerCase()) +
          1;
      final monday = today.subtract(Duration(days: today.weekday - 1));
      return _date(
        monday.add(
          Duration(days: weekday - 1 + 7 * int.parse(match.group(2)!)),
        ),
      );
    }
    if ((match = _monthDayPlus.firstMatch(text)) != null) {
      usesClock();
      final month = _monthNumber(match!.group(1)!);
      final day = int.parse(match.group(2)!);
      final start = DateTime.utc(today.year, month, day);
      if (start.month != month) return null;
      return _date(start.add(Duration(days: int.parse(match.group(3)!))));
    }
    if ((match = _clockSpan.firstMatch(text)) != null) {
      final from = _minutesOfDay(match!.group(1)!);
      final to = _minutesOfDay(match.group(2)!);
      if (from == null || to == null) return null;
      return _hours((to < from ? to + 1440 - from : to - from) / 60);
    }
    if ((match = _unixSpan.firstMatch(text)) != null) {
      final seconds = int.parse(match!.group(2)!) - int.parse(match.group(1)!);
      return _hours(seconds / 3600);
    }
    return null;
  }

  static bool _isTime(QuantityValue value) =>
      value.unit.dimension == Dimension.base(Dimension.time);

  DateTime _today() {
    final wall = AppTimeZones.convert(now(), timeZoneId);
    return DateTime.utc(wall.year, wall.month, wall.day);
  }

  static PhraseValue _days(int days) =>
      PhraseValue('$days ${days == 1 ? 'day' : 'days'}');

  QuantityValue? _hours(double hours) {
    final hour = registry.lookup('h');
    return hour == null ? null : QuantityValue(hours, Unit.single(hour));
  }

  DateTimeValue _date(DateTime day) => DateTimeValue(
    AppTimeZones.fromWallClock(
      year: day.year,
      month: day.month,
      day: day.day,
      hour: 0,
      minute: 0,
      second: 0,
      locationId: timeZoneId,
    ),
    timeZoneId: timeZoneId,
    display: TemporalDisplay.date,
  );

  /// `31 Mar`, `Mar 31`, `march` or `31 March 2027`, counted from today.
  CalcValue? _daysBetween(bool until, String raw, DateTime today) {
    final named = RegExp(
      '^(?:(\\d{1,2})\\s+$_month|$_month\\s+(\\d{1,2})|$_month)(?:,?\\s+(\\d{4}))?\$',
      caseSensitive: false,
    ).firstMatch(raw.trim());
    if (named == null) return null;
    final monthWord = named.group(2) ?? named.group(3) ?? named.group(5)!;
    final month = _monthNumber(monthWord);
    final dayText = named.group(1) ?? named.group(4);
    final day = dayText == null ? 1 : int.parse(dayText);
    final explicitYear = int.tryParse(named.group(6) ?? '');
    var target = DateTime.utc(explicitYear ?? today.year, month, day);
    if (target.month != month) return null;
    if (explicitYear == null) {
      if (until && target.isBefore(today)) {
        target = DateTime.utc(today.year + 1, month, day);
      } else if (!until && target.isAfter(today)) {
        target = DateTime.utc(today.year - 1, month, day);
      }
    }
    final days = until
        ? target.difference(today).inDays
        : today.difference(target).inDays;
    return days < 0 ? null : _days(days);
  }

  static int _monthNumber(String word) =>
      const [
        'jan',
        'feb',
        'mar',
        'apr',
        'may',
        'jun',
        'jul',
        'aug',
        'sep',
        'oct',
        'nov',
        'dec',
      ].indexOf(word.toLowerCase().substring(0, 3)) +
      1;

  static const List<String> _shortMonths = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// `Oct 26 – Nov 1, 2026`, with the year where the range crosses it.
  static String _range(DateTime start, DateTime end) {
    String day(DateTime d) => '${_shortMonths[d.month - 1]} ${d.day}';
    if (start.year != end.year) {
      return '${day(start)}, ${start.year} – ${day(end)}, ${end.year}';
    }
    if (start.month == end.month) {
      return '${day(start)} – ${end.day}, ${end.year}';
    }
    return '${day(start)} – ${day(end)}, ${end.year}';
  }

  static int? _minutesOfDay(String raw) {
    final match = RegExp(
      r'^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$',
      caseSensitive: false,
    ).firstMatch(raw.trim());
    if (match == null) return null;
    var hour = int.parse(match.group(1)!);
    final minute = int.tryParse(match.group(2) ?? '') ?? 0;
    final meridiem = match.group(3)?.toLowerCase();
    if (minute > 59) return null;
    if (meridiem != null) {
      if (hour < 1 || hour > 12) return null;
      hour %= 12;
      if (meridiem == 'pm') hour += 12;
    } else if (hour > 23) {
      return null;
    }
    return hour * 60 + minute;
  }

  /// `2 h 25 min`: the whole span in days, hours, minutes and seconds.
  static String _timespanText(double seconds) {
    if (seconds.abs() < 1) return '${_trim(seconds)} s';
    var rest = seconds.abs().round();
    final parts = <String>[];
    for (final (name, length) in const [
      ('d', 86400),
      ('h', 3600),
      ('min', 60),
      ('s', 1),
    ]) {
      if (rest >= length) {
        parts.add('${rest ~/ length} $name');
        rest %= length;
      }
    }
    return '${seconds < 0 ? '-' : ''}${parts.join(' ')}';
  }

  static String _trim(double value) =>
      value.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '');

  static const Map<String, String> _vulgar = {
    '1/2': '½',
    '1/3': '⅓',
    '2/3': '⅔',
    '1/4': '¼',
    '3/4': '¾',
    '1/5': '⅕',
    '2/5': '⅖',
    '3/5': '⅗',
    '4/5': '⅘',
    '1/6': '⅙',
    '5/6': '⅚',
    '1/7': '⅐',
    '1/8': '⅛',
    '3/8': '⅜',
    '5/8': '⅝',
    '7/8': '⅞',
    '1/9': '⅑',
    '1/10': '⅒',
  };

  /// [value] as a fraction with a denominator of at most 1,000, or null where
  /// none is close enough to be the number the writer meant.
  static String? _fractionText(double value, {required bool improper}) {
    if (!value.isFinite) return null;
    final magnitude = value.abs();
    var best = (numerator: magnitude.round(), denominator: 1);
    var error = (best.numerator - magnitude).abs();
    for (
      var denominator = 2;
      denominator <= 1000 && error > 1e-9;
      denominator++
    ) {
      final numerator = (magnitude * denominator).round();
      final off = (numerator / denominator - magnitude).abs();
      if (off < error) {
        best = (numerator: numerator, denominator: denominator);
        error = off;
      }
    }
    if (error > 1e-6 * (magnitude + 1)) return null;
    final sign = value < 0 ? '-' : '';
    final (:numerator, :denominator) = best;
    if (denominator == 1) return '$sign$numerator';
    if (improper) return '$sign$numerator/$denominator';
    final whole = numerator ~/ denominator;
    final part = '${numerator % denominator}/$denominator';
    final small = _vulgar[part] ?? part;
    if (whole == 0) return '$sign$small';
    return '$sign$whole ${_vulgar[part] ?? part}';
  }
}
