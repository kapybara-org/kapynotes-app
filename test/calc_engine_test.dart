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

String? tooltip(String source, {DigitGrouping? grouping}) => CalcEngine(
  ratesPerUsd: _rates,
  grouping: grouping ?? DigitGrouping.international,
).evaluateDocument(source)[0]?.tooltipText;

CalcEngine clockEngine() => CalcEngine(
  ratesPerUsd: _rates,
  timeZoneId: 'Asia/Kolkata',
  now: () => DateTime.utc(2026, 9, 9, 12),
);

void main() {
  setUp(() => engine = CalcEngine(ratesPerUsd: _rates));

  group('number system', () {
    test('understands attached thousand and million suffixes', () {
      expect(line('6k'), '6,000');
      expect(line('6k usd'), '6,000.00 USD');
      expect(line('6m'), '6,000,000');
      expect(line('2.5M USD'), '2,500,000.00 USD');
      expect(line('6K'), '6 K', reason: 'uppercase K remains kelvin');
      expect(line('6 m'), '6 m', reason: 'a spaced m remains metres');
      expect(line('6km'), '6 km', reason: 'unit identifiers stay intact');
    });

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

    test('explains large results in international words and millions', () {
      expect(
        tooltip('12345678'),
        'Twelve million three hundred forty-five thousand six hundred '
        'seventy-eight\n12.345678 million\nClick to copy',
      );
    });

    test('explains large results in Indian words and crores', () {
      expect(
        tooltip('12345678', grouping: DigitGrouping.indian),
        'One crore twenty-three lakh forty-five thousand six hundred '
        'seventy-eight\n1.234568 crore\nClick to copy',
      );
      expect(
        tooltip('7000000', grouping: DigitGrouping.indian),
        'Seventy lakh\n0.7 crore\nClick to copy',
      );
    });

    test('keeps decimals, signs, and units in result explanations', () {
      expect(
        tooltip('-1200.5 km'),
        'Negative one thousand two hundred point five km\nClick to copy',
      );
      expect(
        tooltip('12345678 inr'),
        'Twelve million three hundred forty-five thousand six hundred '
        'seventy-eight INR\n12.345678 million INR\nClick to copy',
      );
    });

    test('reads binary, octal and hexadecimal literals', () {
      expect(line('0b1010 + 0o10 + 0x10'), '34');
      expect(line('0xff + 1'), '256');
      expect(line('-0b101'), '-5');
    });

    test('formats a result in another numeral system', () {
      expect(line('255 in hex'), '0xff');
      expect(line('255 to binary'), '0b11111111');
      expect(line('255 as octal'), '0o377');
      expect(line('0xff in decimal'), '255');
      expect(line('-10 in hex'), '-0xa');
      expect(line('5300 in sci'), '5.3e3');
    });

    test('understands written international and Indian scales', () {
      expect(line('2 thousand'), '2,000');
      expect(line('2.5 million'), '2,500,000');
      expect(line('3 billion'), '3,000,000,000');
      expect(line('1 lakh'), '100,000');
      expect(line('2.5 crore'), '25,000,000');
      expect(line('2 million eur'), '2,000,000.00 EUR');
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

    test('accepts natural-language operators without fragile phrasing', () {
      expect(line('8 plus 9'), '17');
      expect(line('8 and 9'), '17');
      expect(line('20 with 4'), '24');
      expect(line('20 minus 3'), '17');
      expect(line('20 subtract 3'), '17');
      expect(line('20 without 3'), '17');
      expect(line('6 times 7'), '42');
      expect(line('6 multiplied by 7'), '42');
      expect(line('6 multiply by 7'), '42');
      expect(line('6 mul 7'), '42');
      expect(line('20 divided by 4'), '5');
      expect(line('20 divide by 4'), '5');
    });

    test('multiplies adjacent parenthesised expressions', () {
      expect(line('6 (3)'), '18');
      expect(line('(2 + 1)(4 + 2)'), '18');
      expect(line('2(3 + 4)'), '14');
    });

    test('supports integer bitwise operations', () {
      expect(line('6 & 3'), '2');
      expect(line('6 | 3'), '7');
      expect(line('6 xor 3'), '5');
      expect(line('1 << 8'), '256');
      expect(line('256 >> 4'), '16');
    });

    test('composes boolean operators with comparisons', () {
      expect(line('3 > 2 and 5 > 4'), 'true');
      expect(line('3 > 4 or 5 > 4'), 'true');
      expect(line('true or false == true'), 'true');
    });

    test('reads a written equation as a comparison', () {
      expect(line('2 + 2 = 4'), 'true');
      expect(line('1 meter 20 cm = 120 cm'), 'true');
      expect(line('2 + 2 = 5'), 'false');
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

    test('relative percentage increase and reduction', () {
      expect(line(r'$70 as a % on $20'), '250');
      expect(line(r'$20 as a % off $70'), '71.428571');
    });

    test('solves the base behind a percentage result', () {
      expect(line('5% of what is 6 EUR'), '120.00 EUR');
      expect(line('5% on what is 6 EUR'), '5.71 EUR');
      expect(line('5% off what is 6 EUR'), '6.32 EUR');
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

    test('keeps compact data-unit symbols case-sensitive', () {
      expect(line('1 B in b'), '8 b');
      expect(line('1 MB in Mb'), '8 Mb');
      expect(line('1 Mb in kB'), '125 kB');
      expect(line('1 mB in B'), '0.001 B');
      expect(line('1 gb'), '1 GB', reason: 'common lowercase input is allowed');
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

    test('adds adjacent mixed-unit amounts as one measurement', () {
      expect(line('1 meter 20 cm'), '1.2 m');
      expect(line('5 ft 6 in'), '5.5 ft');
      expect(line('1 h 30 min'), '1.5 h');
    });

    test('understands written square and cubic units', () {
      expect(line('20 sq cm'), '20 cm²');
      expect(line('30 cubic inches'), '30 in³');
      expect(line('2 m * 3 m'), '6 m²');
      expect(line('11 cbm'), '11 m³');
    });

    test('supports screen and print units at familiar defaults', () {
      expect(line('12 pt in px'), '16 px');
      expect(line('1 inch in px'), '96 px');
      expect(line('1 em in px'), '16 px');
      expect(line('2 pints to ml'), '946.352946 mL');
    });

    test('lets a note set its pixel density and em size', () {
      expect(doc('ppi = 192\n1 inch in px\nem = 20px\n1.2 em in px'), {
        0: '192',
        1: '192 px',
        2: '20 px',
        3: '24 px',
      });
    });

    test('accepts multi-word and less common everyday units', () {
      expect(line('1 nautical mile in km'), '1.852 km');
      expect(line('1 furlong in meters'), '201.168 m');
      expect(line('1 stone in pounds'), '14 lb');
      expect(line('1 carat in grams'), '0.2 g');
      expect(line('1 acre in square meters'), '4,046.856422 m²');
      expect(line('1 line in pt'), '12 pt');
    });

    test('derives long-form SI prefixes instead of requiring a fixed list', () {
      expect(line('1 picometer in meters'), '1e-12 m');
      expect(line('1 femtosecond in seconds'), '1e-15 s');
      expect(line('2 gigameters in km'), '2,000,000 km');
      expect(line('3 milliwatts in watts'), '0.003 W');
      expect(line('4 micrograms in mg'), '0.004 mg');
      expect(line('1 year in days'), '365 day');
      expect(line('round(1 month in days)'), '30 day');
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

    test('accepts calculator-style functions without mandatory brackets', () {
      expect(line('sqrt 16'), '4');
      expect(line('cbrt 8'), '2');
      expect(line('abs -7'), '7');
      expect(line('fact 5'), '120');
      expect(line('5!'), '120');
      expect(line('sin 90 deg'), '1');
    });

    test('supports N-th roots and logarithms with a written base', () {
      expect(line('root 3 (27)'), '3');
      expect(line('root 2 (81)'), '9');
      expect(line('log 2 (8)'), '3');
    });

    test('accepts long inverse-trigonometry names', () {
      expect(line('arcsin(0)'), '0');
      expect(line('arccos(1)'), '0');
      expect(line('arctan(0)'), '0');
    });

    test('compares compatible units in min, max, and median', () {
      expect(line('min(1 m, 50 cm)'), '50 cm');
      expect(line('max(1 m, 50 cm)'), '1 m');
      expect(line('median(1 m, 50 cm, 2 m)'), '1 m');
      expect(line('median(50 cm, 2 m)'), '125 cm');
    });

    test('random supports an optional range', () {
      final zeroToOne = double.parse(line('random()')!);
      final tenToTwenty = double.parse(line('random(10, 20)')!);
      expect(zeroToOne, inInclusiveRange(0, 1));
      expect(tenToTwenty, inInclusiveRange(10, 20));
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
      final result = doc('10\n20\n30\nprev\nsum\ntotal\navg\naverage');
      expect(result[3], '30');
      expect(result[4], '60');
      expect(result[5], '60');
      expect(result[6], '20');
      expect(result[7], '20');
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
        expect(
          engine.evaluateDocumentWithSummary('notes only').totalText,
          isNull,
        );

        final converted = engine.evaluateDocumentWithSummary(
          '10 usd\n20 usd\ntotal\ntotal to eur',
        );
        expect(converted.results[3]!.text, '15.00 EUR');
        expect(converted.totalText, '30.00 USD');
      },
    );
  });

  group('date and time', () {
    test('does calendar arithmetic with deterministic clock input', () {
      engine = clockEngine();
      expect(line('today'), '9 Sep 2026');
      expect(line('today + 2 weeks'), '23 Sep 2026');
      expect(line('tomorrow - 1 day'), '9 Sep 2026');
      expect(line('now + 90 min'), '9 Sep 2026, 7:00 PM IST');
      expect(line('time + 90 min'), '7:00 PM IST');
    });

    test('turns Unix timestamps into local date-times', () {
      engine = clockEngine();
      expect(line('fromunix(0)'), '1 Jan 1970, 5:30 AM IST');
      expect(line('fromunix 0'), '1 Jan 1970, 5:30 AM IST');
    });

    test('keeps dates in variables and previous-result continuations', () {
      engine = clockEngine();
      expect(doc('deadline = today + 2 weeks\ndeadline - 1 day'), {
        0: '23 Sep 2026',
        1: '22 Sep 2026',
      });
      expect(doc('today\n+ 2 days'), {0: '9 Sep 2026', 1: '11 Sep 2026'});
    });

    test('reads clock times without mistaking prose for a calculation', () {
      engine = clockEngine();
      expect(line('12:30'), '12:30 PM IST');
      expect(line('2:30 pm'), '2:30 PM IST');
      expect(line('Meeting at 12:30'), isNull);
    });

    test('converts current and stated times between named zones', () {
      engine = clockEngine();
      expect(line('PST time'), '5:00 AM PDT');
      expect(line('time in Madrid'), '2:00 PM CEST');
      expect(line('2:30 pm HKT in Berlin'), '8:30 AM CEST');
      expect(line('2:30 pm in New York'), '2:30 PM EDT');
      expect(line('New York time - PST time'), '3 h');
      expect(line('time in Madrid - PST time'), '9 h');
    });
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

    test('treats quoted text as an inline calculator comment', () {
      expect(line(r'$275 "Model 227"'), '275.00 USD');
      expect(line('100 "ignore 999" + 50'), '150');
      expect(line('100 + 50 "unfinished note'), '150');
      expect(line('"Model 227"'), isNull);
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

  // A label followed by an amount that says what it is. The marker is the
  // whole rule: without it `Lunch 12` cannot be told apart from `Room 12`.
  group('labelled amounts', () {
    test('an explicit label always takes its value from the right', () {
      expect(line('7KvA Solar System : 12000rs'), '12,000.00 INR');
      expect(line('7 kVA solar system: 12,000 rs'), '12,000.00 INR');
      expect(line('Phase 2 materials: 12,000'), '12,000');
      expect(line('Quote #7: panels: 12000rs'), '12,000.00 INR');
      expect(line('Estimate: 10000 + 18%'), '11,800');
    });

    test('an explicit label does not turn time-like prose into an amount', () {
      expect(line('Meeting at 12:30'), isNull);
      expect(line('Ratio 1:2'), isNull);
      expect(line('Chapter 4:'), isNull);
    });

    test('reads a label followed by a marked amount', () {
      expect(line(r'Coffee $4.50'), '4.50 USD');
      expect(line('Lunch 12 usd'), '12.00 USD');
      expect(line('Flights 412 eur'), '412.00 EUR');
      expect(line('Run 5 km'), '5 km');
      expect(line('Long descriptive label here 30 usd'), '30.00 USD');
    });

    test(
      'keeps numbers inside an unpunctuated product label out of the value',
      () {
        expect(line('7KvA Solar System 12000rs'), '12,000.00 INR');
        expect(line('Model 7 inverter 850 usd'), '850.00 USD');
        expect(line('iPhone 15 799usd'), '799.00 USD');
        expect(line('Version 2.0.1 storage 5gb'), '5 GB');
      },
    );

    test('refuses a bare trailing number, whatever the label', () {
      expect(line('Room 12'), isNull);
      expect(line('Chapter 4'), isNull);
      expect(line('iPhone 15'), isNull);
      expect(line('Lunch 12'), isNull);
    });

    test('leaves prose alone even when it contains a unit', () {
      expect(line('take a 10 min break'), isNull);
      expect(line('I have 3 apples'), isNull);
      expect(line('Bought 2 shirts and 3 hats'), isNull);
    });

    test('labelled amounts feed the running total', () {
      final evaluation = engine.evaluateDocumentWithSummary(
        'Lisbon trip\nCoffee \$4.50\nLunch \$12\nTaxi \$8.25\ntotal',
      );
      expect(evaluation.results[0], isNull, reason: 'the heading');
      expect(evaluation.results[4]?.text, '24.75 USD');
      expect(evaluation.totalText, '24.75 USD');
    });

    test('a name the note has defined keeps its meaning', () {
      // `budget` resolves, so the line is a comparison and not a label.
      expect(doc('budget = 100 usd\nbudget 40 usd'), {0: '100.00 USD'});
    });

    test('does not rescue a half-typed expression by dropping its start', () {
      expect(line('100 usd +'), isNull);
      expect(line('* 20 usd'), isNull);
    });

    test('whole-line expressions still win over the label reading', () {
      expect(line('100 km / 2 h'), '50 km/h');
      expect(line('20% of 80'), '16');
      expect(line('Coffee: 4.50'), '4.5');
    });
  });

  // The other word order: the amount leads and the words that follow name it.
  group('quantities with a label', () {
    test('reads a number followed by plain words', () {
      expect(line('12 mangoes'), '12');
      expect(line('12 bananas'), '12');
      expect(line('3 shirts'), '3');
      expect(line('12 ripe alphonso mangoes'), '12');
      expect(line('2.5 boxes'), '2.5');
    });

    test('keeps the amount whole, whatever arithmetic it is made of', () {
      expect(line(r'$5 apples'), '5.00 USD');
      expect(line('2 + 3 apples'), '5');
      expect(line('(2 + 3) * 4 boxes'), '20');
      expect(line('-5 apples'), '-5');
      // Exactly what a bare `50%` renders as; the label changes nothing.
      expect(line('50% discount'), '0.5');
    });

    // The words have to be what the number counts. An amount that already
    // says what it is has been read whole; words after it are prose.
    test('an amount that names itself is not looking for a label', () {
      expect(line('5 kg apples'), isNull);
      expect(line('10 min break'), isNull);
      expect(line('2 hours later he left'), isNull);
      expect(line('5 usd apples'), isNull);
    });

    test('the number still has to lead', () {
      // Named, not counted. Unchanged by this reading.
      expect(line('Room 12'), isNull);
      expect(line('Chapter 4'), isNull);
      expect(line('iPhone 15'), isNull);
      // A colon is an explicit label boundary, so its right side wins even
      // when the unpunctuated version would be ordinary prose.
      expect(line('Hotel: 7 nights'), '7');
    });

    test('a word the calculator knows is not a label', () {
      // Each of these is a calculation part way through being typed.
      expect(line('100 usd to'), isNull);
      expect(line('100 usd to xyz'), isNull);
      expect(line('20 mod'), isNull);
      expect(line('7 sqrt'), isNull);
      expect(line('12 pi'), isNull);
      expect(line('5 total'), isNull);
      expect(doc('mangoes = 4\n12 mangoes'), {0: '4'});
    });

    test('prose that opens with a number is still not a calculation', () {
      expect(line('12 + mangoes'), isNull);
      expect(line('12 mangoes 13'), isNull);
      expect(line('• 12 mangoes'), isNull);
      expect(line('☐ 12 mangoes'), isNull);
    });

    // A label names what the number counts; it should not stop the number
    // being counted with. Everything here read as prose before.
    test('a labelled quantity is still a number to work with', () {
      expect(line('20 domains * 2'), '40');
      expect(line('20 domains + 5 domains'), '25');
      expect(line(r'3 users * $10'), '30.00 USD');
      expect(line('12 boxes / 4'), '3');
      expect(line('100 credits - 40 credits'), '60');
    });

    test('a rate reads as the amount it is a rate of', () {
      expect(line(r'$2/mailbox'), '2.00 USD');
      expect(line(r'$50/user'), '50.00 USD');
      expect(line('100/domain'), '100');
      expect(line(r'$2 per mailbox'), '2.00 USD');
      expect(line(r'$2/mailbox * 40 mailboxes'), '80.00 USD');
    });

    // The per-word only disappears when what follows it is meaningless. A
    // real rate is still a rate.
    test('a real rate is left alone', () {
      expect(line('100 km / 2 h'), '50 km/h');
      expect(line(r'$120 / 3 months'), '40 USD/month');
    });

    // `x` between two amounts, which is how most people write a product by
    // hand and how every screen size is written.
    test('an x between two amounts multiplies them', () {
      expect(line('3 x 4'), '12');
      expect(line('1920 x 1080'), '2,073,600');
      expect(line('2 x 3 widgets'), '6');
      expect(line('5 users X 10'), '50');
      expect(line(r'12 seats x $8'), '96.00 USD');
    });

    test('but x is still the name everyone gives a variable', () {
      expect(doc('x = 5\nx * 2'), {0: '5', 1: '10'});
      // Defined by the note, so it stays a name wherever it appears.
      expect(doc('x = 5\n3 x 4'), {0: '5'});
      expect(line('x'), isNull);
    });

    test('a word with a digit in it is not a label', () {
      // `2x3` lexes as `2` and `x3`. Answering 2 was worse than answering
      // nothing, which is what the rest of the engine does when unsure.
      expect(line('2x3'), isNull);
      expect(line('20 domains v2'), isNull);
    });

    test('quantities feed the running total', () {
      final evaluation = engine.evaluateDocumentWithSummary(
        'Shopping\n12 mangoes\n13 bananas\ntotal',
      );
      expect(evaluation.results[0], isNull, reason: 'the heading');
      expect(evaluation.results[3]?.text, '25');
      expect(evaluation.totalText, '25');
    });
  });

  // Sub-lists are written as leading spaces before the list prefix, so the
  // engine has to be blind to indentation or nesting an item would change what
  // the note computes.
  group('indentation', () {
    test('leading whitespace does not change a result', () {
      expect(line('2 + 2'), '4');
      expect(line('  2 + 2'), '4');
      expect(line('\t2 + 2'), '4');
      // Indented continuation lines see the same scope as unindented ones.
      expect(doc('price = 10 usd\n    price * 2'), {
        0: '10.00 USD',
        1: '20.00 USD',
      });
    });

    test('a list marker is not arithmetic, at any depth', () {
      // Pre-existing: the engine never strips these, so a bullet line has
      // never produced a result. Nesting must not change that either way.
      expect(line('• 2 + 2'), isNull);
      expect(line('  • 2 + 2'), isNull);
      expect(line('☐ 2 + 2'), isNull);
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
