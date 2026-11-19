import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';

const _rates = <String, double>{'EUR': 0.5, 'GBP': 0.25, 'JPY': 100.0};

/// Wednesday 9 Sep 2026, the day every date phrase here counts from.
CalcEngine _engine([DateTime Function()? now]) => CalcEngine(
  ratesPerUsd: _rates,
  timeZoneId: 'Asia/Kolkata',
  now: now ?? () => DateTime.utc(2026, 9, 9, 12),
);

String? _line(String source, [CalcEngine? using]) =>
    (using ?? _engine()).evaluateDocument(source)[0]?.text;

void main() {
  group('money phrases', () {
    test('finds the tax inside a price', () {
      expect(_line('20% vat in 120'), '20');
      expect(_line('20% vat in \$120'), '20.00 USD');
    });

    test('splits a discounted price', () {
      expect(_line('25% off \$60 split 3'), '15.00 USD');
      expect(_line('25% off 60 split 3'), '15');
    });

    test('takes a percentage off or adds it to a value', () {
      expect(_line('15% decrease from 813'), '691.05');
      expect(_line('15% increase from 813'), '934.95');
      expect(_line('15% decrease from \$813'), '691.05 USD');
    });

    test('reads shorthand for thousands and millions', () {
      expect(_line('USD1K'), '1,000.00 USD');
      expect(_line('10K'), '10,000');
      expect(_line('\$10K'), '10,000.00 USD');
      expect(_line('10k usd'), '10,000.00 USD');
      expect(_line('EUR2M'), '2,000,000.00 EUR');
    });

    test('keeps a spaced capital K as kelvin', () {
      expect(_line('300 K'), '300 K');
    });

    test('reads cents and pence as parts of a currency', () {
      expect(_line('20 cents'), '0.20 USD');
      expect(_line('12 pence'), '0.12 GBP');
      expect(_line('5 euro cents in eur'), '0.05 EUR');
    });

    test('reads a code before the number only in capitals', () {
      expect(_line('USD 5'), '5.00 USD');
      for (final word in [
        'Top 10',
        'Bob 3',
        'Try 2',
        'Cup 2',
        'All 4',
        'usd1k',
      ]) {
        expect(_line(word) ?? '', isNot(contains('TOP')), reason: word);
        expect(_line(word) ?? '', isNot(contains('BOB')), reason: word);
        expect(_line(word) ?? '', isNot(contains('TRY')), reason: word);
        expect(_line(word) ?? '', isNot(contains('CUP')), reason: word);
        expect(_line(word) ?? '', isNot(contains('ALL')), reason: word);
        expect(_line(word) ?? '', isNot(contains('USD')), reason: word);
      }
      expect(_line('5 usd'), '5.00 USD', reason: 'a code after the number');
    });

    test('leaves a word that is not a currency alone', () {
      expect(_line('Foo12'), isNull);
      expect(_line('Row 3'), isNull);
    });
  });

  group('words for maths', () {
    test('reads square root of and power', () {
      expect(_line('square root of 625'), '25');
      expect(_line('2 power 10'), '1,024');
    });

    test('adds the cotangent, cosecant and secant functions', () {
      expect(_line('cot(1)'), '0.642093');
      expect(_line('csc(1)'), '1.188395');
      expect(_line('sec(0)'), '1');
      expect(_line('asinh(0)'), '0');
    });
  });

  group('percent and fractions', () {
    test('writes a ratio as a percentage', () {
      expect(_line('1/8 as %'), '12.5%');
      expect(_line('1/8 is what %'), '12.5%');
    });

    test('writes a decimal as a fraction', () {
      expect(_line('1.75 as fraction'), '1 ¾');
      expect(_line('1.75 as improper'), '7/4');
      expect(_line('7/4 as mixed'), '1 ¾');
      expect(_line('0.5 as fraction'), '½');
      expect(_line('-0.25 as fraction'), '-¼');
      expect(_line('4 as fraction'), '4');
      expect(_line('3.14159265358979 as fraction'), '3 16/113');
    });

    test('gives nothing for a number that is no fraction', () {
      expect(_line('1/0 as fraction'), isNull);
      expect(_line('5 kg as fraction'), isNull);
    });
  });

  group('durations', () {
    test('writes a duration in its parts', () {
      expect(_line('145 mins to timespan'), '2 h 25 min');
      expect(_line('90 seconds to mixed'), '1 min 30 s');
      expect(_line('100000 s to timespan'), '1 d 3 h 46 min 40 s');
    });

    test('writes months as years and months', () {
      expect(_line('100 months in years and months'), '8 years 4 months');
      expect(_line('12 months in years and months'), '1 year');
      expect(_line('1 month in years and months'), '1 month');
    });

    test('gives nothing for a value that is not a duration', () {
      expect(_line('5 kg to timespan'), isNull);
      expect(_line('5 to timespan'), isNull);
    });
  });

  group('date phrases', () {
    test('counts days until and since a date', () {
      expect(_line('days until 31 Mar'), '203 days');
      expect(_line('days until Mar 31'), '203 days');
      expect(_line('days since march'), '192 days');
      expect(_line('days until december'), '83 days');
      expect(_line('days until 31 Mar 2028'), '569 days');
    });

    test('counts the days left in this month', () {
      expect(_line('days left in this month'), '21 days');
      expect(_line('workdays left in this month'), '15 workdays');
    });

    test('gives the dates of a numbered week', () {
      expect(_line('week 44 2026'), 'Oct 26 – Nov 1, 2026');
      expect(_line('week 1 2026'), 'Dec 29, 2025 – Jan 4, 2026');
      expect(_line('week 37 2026'), 'Sep 7 – 13, 2026');
      expect(_line('week 37'), isNull, reason: 'a heading, not a phrase');
      expect(_line('week 54 2026'), isNull);
    });

    test('finds a weekday some weeks ahead and adds days to a date', () {
      expect(_line('monday in 3 weeks'), '28 Sep 2026');
      expect(_line('August 5 + 5'), '10 Aug 2026');
      expect(_line('Feb 30 + 5'), isNull);
    });

    test('measures a span of clock times or timestamps', () {
      expect(_line('10pm to 2am'), '4 h');
      expect(_line('9:30am to 5pm'), '7.5 h');
      expect(_line('from 1700000000 to 1700003600'), '1 h');
      expect(_line('13pm to 2pm'), isNull);
    });

    test('reads the clock again on every pass', () {
      var today = DateTime.utc(2026, 9, 9, 12);
      final engine = _engine(() => today);
      expect(_line('days until 31 Mar', engine), '203 days');
      today = DateTime.utc(2026, 9, 10, 12);
      expect(_line('days until 31 Mar', engine), '202 days');
    });

    test('rolls an undated month into next year', () {
      expect(_line('days until january'), '114 days');
    });
  });

  group('prose stays prose', () {
    test('a sentence holding the same words is not a calculation', () {
      final engine = _engine();
      for (final prose in [
        'Days until the party',
        'We wait until Friday',
        'Week of the big launch',
        'The fraction was small',
        'Power to the people',
        'Cut costs and split the bill',
      ]) {
        expect(
          engine.evaluateDocument(prose),
          isEmpty,
          reason: 'prose: $prose',
        );
      }
    });

    test('a phrase result is not a number that totals add up', () {
      final results = _engine().evaluateDocument(
        '2 power 3\n1.75 as fraction\ntotal',
      );
      expect(results[0]!.text, '8');
      expect(results[2]!.text, '8');
    });
  });

  group('phrase words', () {
    String keywords(String body) {
      final highlighter = Highlighter(_engine().registry);
      return [
        for (final span in highlighter.spans(body))
          if (span.kind == HighlightKind.keyword)
            body.substring(span.start, span.end),
      ].join(' ');
    }

    test('are coloured as keywords on a phrase line only', () {
      expect(keywords('days until 31 Mar'), contains('until'));
      expect(keywords('25% off 60 split 3'), contains('split'));
      expect(keywords('We wait until Friday'), isNot(contains('until')));
      expect(keywords('split = 3'), isNot(contains('split')));
    });
  });

  group('total in a currency', () {
    test('shows the total of plain numbers in that currency', () {
      expect(
        _engine().evaluateDocument('3\n4\ntotal in eur')[2]!.text,
        '7.00 EUR',
      );
      expect(
        _engine().evaluateDocument('a = 3\nb = 4\nsum in usd')[2]!.text,
        '7.00 USD',
      );
      expect(
        _engine().evaluateDocument('2\n4\navg in gbp')[2]!.text,
        '3.00 GBP',
      );
    });

    test('adds nothing to the total itself', () {
      final results = _engine().evaluateDocument('3\n4\ntotal in eur\ntotal');
      expect(results[3]!.text, '7');
    });

    test('still converts the money total of a note that has money', () {
      expect(
        _engine().evaluateDocument('\$10\n4\ntotal in eur')[2]!.text,
        '5.00 EUR',
      );
    });

    test('shows it with no rates at all', () {
      final results = CalcEngine().evaluateDocument('10\n5\ntotal in eur');
      expect(results[2]!.text, '15.00 EUR');
      expect(
        CalcEngine().evaluateDocument('10\n5\nsum in eur')[2]!.text,
        '15.00 EUR',
      );
      expect(
        CalcEngine().evaluateDocument('10\n5\navg in gbp')[2]!.text,
        '7.50 GBP',
      );
    });

    test('takes only a real currency code, with rates or without', () {
      for (final engine in [CalcEngine(), _engine()]) {
        for (final word in ['may', 'Jan', 'xyz', 'all', 'try']) {
          expect(
            engine.evaluateDocument('10\n5\ntotal in $word')[2],
            isNull,
            reason: word,
          );
        }
        expect(engine.evaluateDocument('Total in May')[0], isNull);
        expect(
          engine.evaluateDocument('10\n5\nsum in zar')[2]!.text,
          '15.00 ZAR',
        );
      }
    });

    test('takes a code that is also a word only in capitals', () {
      for (final engine in [CalcEngine(), _engine()]) {
        for (final word in ['bob', 'Bob', 'mad', 'gel', 'ron', 'Try', 'lak']) {
          expect(
            engine.evaluateDocument('10\n5\ntotal in $word')[2],
            isNull,
            reason: word,
          );
        }
        for (final code in ['TRY', 'MAD', 'BOB', 'ALL', 'ZWG', 'XCG']) {
          expect(
            engine.evaluateDocument('10\n5\ntotal in $code')[2]!.text,
            '15.00 $code',
            reason: code,
          );
        }
        for (final word in ['LAK', 'ANG', 'ZWL']) {
          expect(
            engine.evaluateDocument('10\n5\ntotal in $word')[2],
            isNull,
            reason: word,
          );
        }
      }
    });

    test(
      'takes a code that is also a word only in capitals once it has a rate',
      () {
        final engine = CalcEngine(
          ratesPerUsd: const {
            'EUR': 0.5,
            'ALL': 100.0,
            'TRY': 30.0,
            'BOB': 7.0,
            'MAD': 10.0,
            'GEL': 2.5,
            'RON': 4.0,
            'MOP': 8.0,
            'PEN': 4.0,
            'TOP': 2.0,
            'SOS': 570.0,
          },
        );
        for (final word in [
          'all',
          'All',
          'try',
          'Try',
          'bob',
          'mad',
          'gel',
          'ron',
          'mop',
          'pen',
          'top',
          'sos',
        ]) {
          expect(
            engine.evaluateDocument('10\n5\ntotal in $word')[2],
            isNull,
            reason: word,
          );
        }
        for (final code in [
          'ALL',
          'TRY',
          'BOB',
          'MAD',
          'GEL',
          'RON',
          'MOP',
          'PEN',
          'TOP',
          'SOS',
        ]) {
          expect(
            engine.evaluateDocument('10\n5\ntotal in $code')[2]!.text,
            '15.00 $code',
            reason: code,
          );
        }
        expect(engine.evaluateDocument('30 TRY in usd')[0]!.text, '1.00 USD');
        expect(engine.evaluateDocument('5 try')[0]?.text, isNot('5.00 TRY'));
        expect(engine.evaluateDocument('5 TRY')[0]!.text, '5.00 TRY');
        expect(engine.evaluateDocument('\$5 in eur')[0]!.text, '2.50 EUR');
      },
    );

    test('has no rate to convert money with when there are none', () {
      expect(CalcEngine().evaluateDocument('\$10\n5\ntotal in eur')[2], isNull);
      expect(CalcEngine().evaluateDocument('100 usd in eur')[0], isNull);
      expect(CalcEngine().evaluateDocument('5 in eur')[0], isNull);
      expect(
        CalcEngine().evaluateDocument('total = 5\ntotal in eur')[1],
        isNull,
      );
    });

    test('leaves a plain number and a name the note gave a value alone', () {
      expect(_line('5 in eur'), isNull);
      expect(_engine().evaluateDocument('total = 5\ntotal in eur')[1], isNull);
    });
  });
}
