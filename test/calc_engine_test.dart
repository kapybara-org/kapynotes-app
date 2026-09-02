import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/format.dart';
import 'package:kapy_notes/calc/value.dart';

/// A small, fixed rate table so currency tests are deterministic.
const _rates = <String, double>{
  'EUR': 0.5,
  'GBP': 0.25,
  'JPY': 100.0,
  'INR': 80.0,
};

late CalcEngine engine;

/// Evaluates a one-line note and returns the displayed chip text.
String? line(String source) => engine.evaluateDocument(source)[0]?.text;

/// Evaluates a multi-line note and returns display text per line index.
Map<int, String> doc(String body) => engine
    .evaluateDocument(body)
    .map((key, value) => MapEntry(key, value.text));

/// Evaluates a one-line note through an engine using Indian grouping.
String? indianLine(String source) => CalcEngine(
  ratesPerUsd: _rates,
  grouping: DigitGrouping.indian,
).evaluateDocument(source)[0]?.text;

void main() {
  setUp(() => engine = CalcEngine(ratesPerUsd: _rates));

  group('number system', () {
    test('groups in threes by default', () {
      expect(line('7000000'), '7,000,000');
      expect(line('1234.5678'), '1,234.5678');
      expect(line('40249440 inr'), '40,249,440.00 INR');
    });

    test('groups in lakh and crore when asked', () {
      expect(indianLine('7000000'), '70,00,000');
      expect(indianLine('1000'), '1,000');
      expect(indianLine('100000'), '1,00,000');
      expect(indianLine('1234.5678'), '1,234.5678');
      expect(indianLine('-40249440'), '-4,02,49,440');
      expect(indianLine('40249440 inr'), '4,02,49,440.00 INR');
    });

    test('leaves the clipboard value ungrouped either way', () {
      final results = CalcEngine(
        grouping: DigitGrouping.indian,
      ).evaluateDocument('7000000');
      expect(results[0]!.copyText, '7000000');
    });

    test('carries the grouping into the running total', () {
      final evaluation = CalcEngine(
        grouping: DigitGrouping.indian,
      ).evaluateDocumentWithSummary('40,00,000\n30,00,000');
      expect(evaluation.totalText, '70,00,000');
    });
  });

  group('arithmetic', () {
    test('evaluates basic expressions', () {
      expect(line('2 + 2 * 3'), '8');
      expect(line('(2 + 2) * 3'), '12');
      expect(line('10 / 4'), '2.5');
      expect(line('2 ^ 10'), '1,024');
      expect(line('-5 + 3'), '-2');
      expect(line('7 mod 3'), '1');
    });

    test('strips thousands separators', () {
      expect(line('1,250 + 750'), '2,000');
      expect(line('1_000_000 / 4'), '250,000');
    });

    test('keeps commas as argument separators', () {
      expect(line('max(1, 250)'), '250');
      expect(line('min(4, 9, 2)'), '2');
      // Unspaced pairs never close on a group of three, so they stay a list.
      expect(line('max(10,20,30)'), '30');
    });

    test('reads numbers grouped in lakh and crore', () {
      expect(line('70,00,000 / 2'), '3,500,000');
      expect(line('4,02,49,440 - 40,249,440'), '0');
    });

    test('cleans binary float noise', () {
      expect(line('0.1 + 0.2'), '0.3');
      expect(line('1.1 * 3'), '3.3');
    });

    test('groups large results and honours 6 decimal places', () {
      expect(line('1234567 + 0'), '1,234,567');
      expect(line('2 / 3'), '0.666667');
    });

    test('handles a leading or trailing equals sign', () {
      expect(line('= 5 * 5'), '25');
      expect(line('5 * 5 ='), '25');
    });
  });

  group('percentages', () {
    test('X% of Y', () {
      expect(line('20% of 80'), '16');
      expect(line('15% of 250'), '37.5');
    });

    test('value + X% and value - X%', () {
      expect(line('1,250 + 8%'), '1,350');
      expect(line('200 - 10%'), '180');
    });

    test('X% off and X% on', () {
      expect(line('20% off 50'), '40');
      expect(line('20% on 50'), '60');
    });

    test('X as a % of Y', () {
      expect(line('25 as a % of 200'), '12.5');
      expect(line('25 as % of 200'), '12.5');
    });

    test('accepts the word "percent" wherever "%" works', () {
      expect(line('20 percent of 80'), '16');
      expect(line('1250 + 8 percent'), '1,350');
      expect(line('25 as a percent of 200'), '12.5');
      expect(line('50 pct of 40'), '20');
      expect(line('20 percent off 50'), '40');
    });

    test('bare percentage is a fraction', () {
      expect(line('50%'), '0.5');
    });

    test('percentages bind tighter than addition', () {
      expect(line('20% of 80 + 5'), '21');
      expect(line('10% of 50 * 2'), '10');
    });
  });

  group('units', () {
    test('converts length', () {
      expect(line('10 km to miles'), '6.213712 mi');
      expect(line('12 in to cm'), '30.48 cm');
      expect(line('2 ft + 6 in'), '2.5 ft');
    });

    test('converts mass and volume', () {
      expect(line('5 kg to lb'), '11.023113 lb');
      expect(line('2 l to ml'), '2,000 mL');
    });

    test('converts temperature with offsets', () {
      expect(line('100 degC to degF'), '212 °F');
      expect(line('32 degF to degC'), '0 °C');
    });

    test('treats a same-unit sum as a difference, not a re-basing', () {
      expect(line('20 degC + 5 degC'), '25 °C');
    });

    test('builds compound units', () {
      expect(line('100 km / 2 h'), '50 km/h');
      expect(line('120 km/h to mph'), '74.564543 mph');
    });

    test('cancels units that divide out', () {
      expect(line('10 km / 2 m'), '5,000');
      expect(line('1 GB / 1 MB'), '1,000');
    });

    test('resolves "in" as inches only when no unit follows', () {
      expect(line('10 in'), '10 in');
      expect(line('10 in + 2 in'), '12 in');
      expect(line('10 in to cm'), '25.4 cm');
      expect(line('1 ft in inches'), '12 in');
    });

    test('accepts plural and long unit names', () {
      expect(line('3 hours to minutes'), '180 min');
      expect(line('2 kilometers to meters'), '2,000 m');
    });
  });

  group('currency', () {
    test('converts between codes', () {
      expect(line('100 usd to eur'), '50.00 EUR');
      expect(line('100 USD to GBP'), '25.00 GBP');
      expect(line('50 eur to usd'), '100.00 USD');
    });

    test('accepts every loaded currency code without a space', () {
      for (final code in _rates.keys) {
        expect(line('10${code.toLowerCase()}'), '10.00 $code', reason: code);
      }
    });

    test('treats rs as an INR shorthand', () {
      expect(line('10rs'), line('10inr'));
      expect(line('10RS'), '10.00 INR');
      expect(line('10rs + 5inr'), '15.00 INR');
    });

    test('accepts "in" for currency conversion', () {
      expect(line('100 usd in eur'), '50.00 EUR');
    });

    test('reads currency symbols before and after the amount', () {
      expect(line(r'$100 to EUR'), '50.00 EUR');
      expect(line('100 \$ to EUR'), '50.00 EUR');
      expect(line('€20 to usd'), '40.00 USD');
    });

    test('mixes codes in one expression', () {
      expect(line('50 EUR + 20 usd'), '60.00 EUR');
    });

    test('always shows two decimals for money', () {
      expect(line('10 usd / 3'), '3.33 USD');
      expect(line(r'$1234.5 + 0'), '1,234.50 USD');
    });

    test('adds a bare number to a money amount', () {
      expect(line('100 usd + 5'), '105.00 USD');
    });

    test('produces nothing when the rate is unknown', () {
      expect(line('100 usd to xyz'), isNull);
    });

    test('produces nothing at all when no rates are loaded', () {
      engine = CalcEngine();
      expect(line('100 usd to eur'), isNull);
      // Non-currency math must still work offline.
      expect(line('2 + 2'), '4');
    });
  });

  group('functions and constants', () {
    test('evaluates functions', () {
      expect(line('sqrt(16)'), '4');
      expect(line('round(2.567, 2)'), '2.57');
      expect(line('abs(-7)'), '7');
      expect(line('hypot(3, 4)'), '5');
    });

    test('evaluates trigonometry in radians and degrees', () {
      expect(line('sin(pi/2)'), '1');
      expect(line('sin(90 deg)'), '1');
    });

    test('keeps units through unit-safe functions', () {
      expect(line('round(2.6 km)'), '3 km');
    });
  });

  group('running scope', () {
    test('carries variables down the document', () {
      expect(doc('subtotal = 42\nsubtotal * 3'), {0: '42', 1: '126'});
    });

    test('supports colon assignment', () {
      expect(doc('Groceries: 120\nGroceries / 4'), {0: '120', 1: '30'});
    });

    test('exposes prev, sum, total and avg', () {
      final result = doc('10\n20\n30\nprev\nsum\ntotal\navg');
      expect(result[3], '30');
      expect(result[4], '60');
      expect(result[5], '60');
      expect(result[6], '20');
    });

    test('treats a leading operator as a continuation of the line above', () {
      expect(doc('100\n+ 50\n* 2'), {0: '100', 1: '150', 2: '300'});
    });

    test('does not treat a leading minus as a continuation', () {
      expect(doc('100\n-5'), {0: '100', 1: '-5'});
    });

    test('lets a user variable shadow a unit name', () {
      expect(doc('h = 5\nh * 2'), {0: '5', 1: '10'});
    });

    test('keeps a running total across currencies of one kind', () {
      final result = doc('10 usd\n20 usd\nsum');
      expect(result[2], '30.00 USD');
    });

    test(
      'exposes the final running total without double-counting readouts',
      () {
        final result = engine.evaluateDocumentWithSummary('10\n20\ntotal');

        expect(result.results[2]!.text, '30');
        expect(result.totalText, '30');
        expect(engine.evaluateDocumentWithSummary('notes only').totalText, '0');

        final converted = engine.evaluateDocumentWithSummary(
          '10 usd\n20 usd\ntotal\ntotal to eur',
        );
        expect(converted.results[3]!.text, '15.00 EUR');
        expect(converted.totalText, '30.00 USD');
      },
    );
  });

  group('prose coexistence', () {
    test('ignores lines with no arithmetic signal', () {
      expect(line('Trip planning notes'), isNull);
      expect(line('Remember to call the hotel'), isNull);
    });

    test('ignores prose that merely contains a number', () {
      expect(line('I have 3 apples'), isNull);
      expect(line('Meeting at 3 with the team'), isNull);
      expect(line('take a 10 min break'), isNull);
    });

    test('ignores headings that end in a colon', () {
      expect(line('Budget:'), isNull);
      expect(line('# Trip to Lisbon'), isNull);
    });

    test('never throws on partially typed input', () {
      for (final partial in ['1 +', '(', '20% of', '100 usd to', '=', '3 *']) {
        expect(() => engine.evaluateDocument(partial), returnsNormally);
        expect(line(partial), isNull, reason: partial);
      }
    });

    test('strips trailing comments', () {
      expect(line('100 + 50 // total cost'), '150');
      expect(line('100 + 50 # total cost'), '150');
    });

    test('never evaluates an automatic date separator', () {
      expect(doc('Second note\n6 * 7\n// ── 1 Sep 2026 · 9:42 PM ──\n'), {
        1: '42',
      });
    });

    test('does not treat a mid-word hash as a comment', () {
      expect(line('2 + 2'), '4');
    });
  });

  group('result kinds and copy text', () {
    test('classifies results for gutter colouring', () {
      final results = engine.evaluateDocument(
        '2 + 2\n100 usd to eur\n10 km to mi\n3 > 2',
      );
      expect(results[0]!.kind, ResultKind.number);
      expect(results[1]!.kind, ResultKind.currency);
      expect(results[2]!.kind, ResultKind.unit);
      expect(results[3]!.kind, ResultKind.boolean);
    });

    test('copy text is full precision and ungrouped', () {
      final result = engine.evaluateDocument('2 / 3\n1234567 + 0');
      expect(result[0]!.text, '0.666667');
      expect(result[0]!.copyText, '0.666666666667');
      expect(result[1]!.text, '1,234,567');
      expect(result[1]!.copyText, '1234567');
    });

    test('renders infinity and NaN readably', () {
      expect(line('1 / 0'), '∞');
      expect(line('-1 / 0'), '-∞');
      expect(line('0 / 0'), 'NaN');
    });

    test('renders booleans', () {
      expect(line('3 > 2'), 'true');
      expect(line('3 == 4'), 'false');
    });
  });
}
