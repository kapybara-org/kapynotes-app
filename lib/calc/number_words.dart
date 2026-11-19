/// Numbers written as words, in English and Hindi, read as the figure they
/// say: 'two hundred fifty' and 'दो सौ पचास' as 250.
///
/// Only a run of words is read here; whether it counts is up to the caller,
/// which takes one only where a currency word follows it, so a sentence that
/// holds 'one' or 'दो' stays prose.
class NumberWords {
  const NumberWords._();

  static const String _end = r'(?![\p{L}\p{M}\p{N}])';

  static const List<String> _tens = [
    'twenty',
    'thirty',
    'forty',
    'fifty',
    'sixty',
    'seventy',
    'eighty',
    'ninety',
  ];

  static final Map<String, int> _small = {
    for (final (i, word)
        in ('one two three four five six seven eight nine ten eleven twelve '
                'thirteen fourteen fifteen sixteen seventeen eighteen nineteen')
            .split(' ')
            .indexed)
      word: i + 1,
    for (final (i, word) in _tens.indexed) word: (i + 2) * 10,
    for (final (i, word)
        in ('एक दो तीन चार पाँच छह सात आठ नौ दस '
                'ग्यारह बारह तेरह चौदह पंद्रह सोलह सत्रह अठारह उन्नीस बीस '
                'इक्कीस बाईस तेईस चौबीस पच्चीस छब्बीस सत्ताईस अट्ठाईस उनतीस तीस '
                'इकतीस बत्तीस तैंतीस चौंतीस पैंतीस छत्तीस सैंतीस अड\u093Cतीस उनतालीस चालीस '
                'इकतालीस बयालीस तैंतालीस चौवालीस पैंतालीस छियालीस सैंतालीस अड\u093Cतालीस उनचास पचास '
                'इक्यावन बावन तिरपन चौवन पचपन छप्पन सत्तावन अट्ठावन उनसठ साठ '
                'इकसठ बासठ तिरसठ चौंसठ पैंसठ छियासठ सड\u093Cसठ अड\u093Cसठ उनहत्तर सत्तर '
                'इकहत्तर बहत्तर तिहत्तर चौहत्तर पचहत्तर छिहत्तर सतहत्तर अठहत्तर उन्यासी अस्सी '
                'इक्यासी बयासी तिरासी चौरासी पचासी छियासी सत्तासी अट्ठासी नवासी नब्बे '
                'इक्यानवे बानवे तिरानवे चौरानवे पचानवे छियानवे सत्तानवे अट्ठानवे निन्यानवे')
            .split(' ')
            .indexed)
      word: i + 1,
    'पांच': 5,
    'छः': 6,
    'पन्द्रह': 15,
    'अठाईस': 28,
  };

  static const Set<String> _hundreds = {'hundred', 'सौ'};

  static const Map<String, int> _scales = {
    'thousand': 1000,
    'हज\u093Cार': 1000,
    'हजार': 1000,
    'lakhs': 100000,
    'lakh': 100000,
    'lacs': 100000,
    'lac': 100000,
    'लाख': 100000,
    'crores': 10000000,
    'crore': 10000000,
    'करोड\u093C': 10000000,
    'करोड': 10000000,
    'million': 1000000,
    'billion': 1000000000,
  };

  /// A run of number words as a regular expression, with no group of its own
  /// and nothing captured. It starts at a word, not inside one and not just
  /// after a digit, so the 'lakh' of '2 lakh' is left to that figure.
  static final String pattern = () {
    final words = [..._small.keys, ..._hundreds, ..._scales.keys]
      ..sort((a, b) => b.length.compareTo(a.length));
    final alternatives = words.map(RegExp.escape).join('|');
    final word = '(?:$alternatives)$_end';
    return r'(?<![\p{L}\p{M}\p{N}])(?<!\p{N}[\s-]*)'
        '$word'
        r'(?:[\s-]+(?:(?:and|और)\s+)?'
        '$word'
        r')*';
  }();

  /// The number a run matched by [pattern] says, or null where its words do
  /// not make one, as in 'one two' or 'twenty and fifty'.
  static int? value(String run) {
    var total = 0;
    var current = 0;
    var lastScale = 1 << 62;
    String? previous;
    for (final token in run.toLowerCase().split(RegExp(r'[\s-]+'))) {
      if (token == 'and' || token == 'और') {
        if (previous != 'hundred' && previous != 'scale') return null;
        continue;
      }
      final small = _small[token];
      if (small != null) {
        final afterTens = previous == 'tens' && small < 10;
        if (current % 100 != 0 && !afterTens) return null;
        current += small;
        previous = _tens.contains(token) ? 'tens' : 'small';
        continue;
      }
      if (current == 0 && previous != null) return null;
      if (_hundreds.contains(token)) {
        if (current >= 100) return null;
        current = (current == 0 ? 1 : current) * 100;
        previous = 'hundred';
        continue;
      }
      final scale = _scales[token]!;
      if (scale >= lastScale) return null;
      total += (current == 0 ? 1 : current) * scale;
      current = 0;
      lastScale = scale;
      previous = 'scale';
    }
    return total + current;
  }
}
