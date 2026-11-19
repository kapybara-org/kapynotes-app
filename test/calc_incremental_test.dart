import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/value.dart';

import '../benchmark/markdown_rendering.dart' show longNote;

/// The rates calc_engine_test.dart uses.
const _rates = <String, double>{
  'EUR': 0.5,
  'GBP': 0.25,
  'JPY': 100.0,
  'INR': 80.0,
};

/// Lines from calc_engine_test.dart, among them the names, totals, labels
/// and clock readings that make one line depend on another.
const _corpus = [
  '6k usd',
  '2.5M USD',
  '40,00,000',
  '0xff + 1',
  '255 in hex',
  '2.5 crore',
  '2 + 2 * 3',
  '3 × 49 usd',
  '1,250 + 750',
  'max(10,20,30)',
  '0.1 + 0.2',
  '= 5 * 5',
  '8 plus 9',
  '6 multiplied by 7',
  '(2 + 1)(4 + 2)',
  '6 xor 3',
  '3 > 2 and 5 > 4',
  '2 + 2 = 4',
  '20% of 80',
  '1,250 + 8%',
  '20% off 50',
  '25 as a % of 200',
  r'$70 as a % on $20',
  '5% of what is 6 EUR',
  '50%',
  '10 km to miles',
  '12 in to cm',
  '100 degC to degF',
  '120 km/h to mph',
  '1 GB / 1 MB',
  '10 in',
  '5 ft 6 in',
  '20 sq cm',
  '12 pt in px',
  '1 em in px',
  'ppi = 192',
  'em = 20px',
  '1.2 em in px',
  '1 year in days',
  '100 usd to eur',
  '10rs + 5inr',
  r'$100 to EUR',
  '€20 to usd',
  '50 EUR + 20 usd',
  '100 usd + 5',
  '100 usd to xyz',
  'sqrt(16)',
  'round(2.567, 2)',
  'sin(90 deg)',
  'sqrt 16',
  '5!',
  'log 2 (8)',
  'median(1 m, 50 cm, 2 m)',
  'subtotal = 42',
  'subtotal * 3',
  'min = 7',
  'min * 2',
  'min(3, 5)',
  'sum = 7',
  'avg = 7',
  'in = 7',
  'to = 7',
  'x = 5',
  'x * 2',
  'x',
  '3 x 4',
  '2 x 3 widgets',
  'h = 5',
  'h * 2',
  'a = 2',
  'a = 5',
  'b = 4',
  'sqrt(a^2 + b^2)',
  'Groceries: 120',
  'Groceries / 4',
  'to: 5 people',
  '5 km to m',
  'min: 18',
  'Walk 20 min',
  '10',
  '20',
  '100',
  '-5',
  '+ 50',
  '* 2',
  'prev',
  'sum',
  'total',
  'avg',
  'average',
  '10 usd',
  'total to eur',
  'today',
  'today + 2 weeks',
  'now + 90 min',
  'time + 90 min',
  'fromunix(0)',
  'deadline = today + 2 weeks',
  'deadline - 1 day',
  '+ 2 days',
  '12:30',
  '2:30 pm',
  'Meeting at 12:30',
  'PST time',
  'time in Madrid',
  '2:30 pm in New York',
  'New York time - PST time',
  'Trip planning notes',
  'I have 3 apples',
  'take a 10 min break',
  'Budget:',
  '# Trip to Lisbon',
  '2020–2024',
  '1 +',
  '(',
  '100 usd to',
  '100 + 50 // total cost',
  r'$275 "Model 227"',
  '// ── 1 Sep 2026 · 9:42 PM ──',
  '',
  '7KvA Solar System : 12000rs',
  'Quote #7: panels: 12000rs',
  'Estimate: 10000 + 18%',
  'looker connector = 29 usd',
  'looker connector * 12',
  'Q1: revenue = 1000',
  'revenue * 4',
  'Ratio 1:2',
  r'Coffee $4.50',
  'Model 7 inverter 850 usd',
  'Room 12',
  'iPhone 15',
  r'Lunch $12',
  'budget = 100 usd',
  'budget 40 usd',
  '12 mangoes',
  '2 + 3 apples',
  '5 kg apples',
  '10 min break',
  'mangoes = 4',
  '12 + mangoes',
  '20 domains * 2',
  r'$2/mailbox',
  r'$2 per mailbox',
  r'$120 / 3 months',
  'domains = 20',
  'mailboxes= domains * 5 mail boxes',
  r'domain_cost = domains * $10/domain',
  r'mailbox_cost: mailboxes * $2/mailbox',
  'total_cost = domain_cost + mailbox_cost',
  'rent = Flat 4B 1200 usd',
  'rent * 2',
  'n = Room 12',
  'Milk: 2 bottles',
  r'Milk powder $8',
  r'fee: $2/mailbox + $1',
  'fee * 2',
  '    price * 2',
  'price = 10 usd',
  '• 2 + 2',
  '☐ 12 mangoes',
  '3 == 4',
  '1 / 0',
  '0 / 0',
  'flights = 412 eur',
  'flights to usd',
  'flights + 20 eur',
  'flights - 10%',
  'hotel = 96 eur * 7',
  'nightly = 128 eur',
  'hotel = nightly * 7',
  '7 * nightly',
  'nights = 7',
  'hotel = nightly * nights',
  'dinner = 80',
  'share = dinner / 2',
  'tip = dinner * 15%',
  'rent = 1200',
  'food = 300',
  'rent + food',
  'x = x + 1',
  'both = price * x',
  '5 kg',
];

CalcEngine _engine(String? timeZoneId, {DateTime Function()? now}) =>
    CalcEngine(
      ratesPerUsd: _rates,
      timeZoneId: timeZoneId,
      now: now ?? () => DateTime.utc(2026, 9, 9, 12),
    );

/// Everything [evaluation] shows: every field of every result, and the
/// total.
List<String> _seen(DocumentEvaluation evaluation) => [
  for (final index in evaluation.results.keys.toList()..sort())
    _result(index, evaluation.results[index]!),
  'total ${evaluation.totalText} ${_value(evaluation.total)} '
      '${evaluation.grouping} ${evaluation.totalDetail}',
];

String _result(int index, LineResult result) =>
    '$index: line ${result.line}, ${result.text} | ${result.copyText} | '
    '${result.grouping} | total ${result.isTotal} | ${result.kind} | '
    '${result.tooltipText} | ${result.count?.mark} | ${_value(result.value)}';

String _value(CalcValue? value) => switch (value) {
  null => 'none',
  NumberValue(:final value) => 'number $value',
  FormattedNumberValue(:final value, :final notation) =>
    'number $value in $notation',
  PercentValue(:final fraction) => 'percent $fraction',
  QuantityValue(:final value, :final unit) =>
    'quantity $value ${[for (final term in unit.terms) '${term.def.symbol}^${term.exponent} '
          '(${term.def.factor}, ${term.def.offset}, ${term.def.category})']}',
  BooleanValue(:final value) => 'boolean $value',
  DateTimeValue(:final instant, :final timeZoneId, :final display) =>
    'date $instant in $timeZoneId as $display',
};

/// Checks that [engine], with whatever it remembers from earlier notes, reads
/// [body] exactly as an engine that has read nothing else.
void _expectFresh(
  CalcEngine engine,
  String body, {
  String? timeZoneId,
  DateTime Function()? now,
  String? reason,
}) => expect(
  _seen(engine.evaluateDocumentWithSummary(body)),
  _seen(_engine(timeZoneId, now: now).evaluateDocumentWithSummary(body)),
  reason: reason,
);

Map<int, String> _texts(CalcEngine engine, String body) => engine
    .evaluateDocument(body)
    .map((index, result) => MapEntry(index, result.text));

/// Makes one of the edits an editor makes to [lines]: a line added, removed
/// or replaced from [pool], a character typed or deleted, or a line split or
/// two joined.
void _edit(Random random, List<String> lines, List<String> pool) {
  final i = random.nextInt(lines.length);
  switch (random.nextInt(7)) {
    case 0:
      lines.insert(
        random.nextInt(lines.length + 1),
        pool[random.nextInt(pool.length)],
      );
    case 1:
      if (lines.length > 1) lines.removeAt(i);
    case 2:
      lines[i] = pool[random.nextInt(pool.length)];
    case 3:
      const typed = r'0123456789+-*/=:. xaebhmnpstu$%()';
      final at = random.nextInt(lines[i].length + 1);
      lines[i] = lines[i].replaceRange(
        at,
        at,
        typed[random.nextInt(typed.length)],
      );
    case 4:
      if (lines[i].isEmpty) return;
      final at = random.nextInt(lines[i].length);
      lines[i] = lines[i].replaceRange(at, at + 1, '');
    case 5:
      final at = random.nextInt(lines[i].length + 1);
      lines.insert(i + 1, lines[i].substring(at));
      lines[i] = lines[i].substring(0, at);
    case 6:
      if (i + 1 < lines.length) lines[i] += lines.removeAt(i + 1);
  }
}

void main() {
  test('reads short notes as a fresh engine does, over random edits', () {
    for (final zone in ['Asia/Kolkata', null]) {
      final random = Random(14);
      final engine = _engine(zone);
      final notes = [
        for (var n = 0; n < 3; n++)
          [
            for (var k = 0; k < 5 + random.nextInt(40); k++)
              _corpus[random.nextInt(_corpus.length)],
          ],
      ];
      for (var round = 0; round < 500; round++) {
        // Mostly the note being edited, now and then another, and sometimes
        // just the top of one, as the notes list reads it.
        final lines =
            notes[random.nextInt(5) == 0 ? random.nextInt(notes.length) : 0];
        for (var edits = random.nextInt(4) == 0 ? 3 : 1; edits > 0; edits--) {
          _edit(random, lines, _corpus);
        }
        final reason = 'zone $zone, round $round';
        _expectFresh(
          engine,
          lines.join('\n'),
          timeZoneId: zone,
          reason: reason,
        );
        if (random.nextInt(4) == 0) {
          _expectFresh(
            engine,
            lines.take(1 + random.nextInt(lines.length)).join('\n'),
            timeZoneId: zone,
            reason: '$reason, top',
          );
        }
      }
    }
  });

  test('reads the long note as a fresh engine does, over random edits', () {
    final random = Random(14);
    final engine = _engine(null);
    final lines = longNote().split('\n');
    final pool = [..._corpus, ...lines.take(200)];
    _expectFresh(engine, lines.join('\n'), reason: 'opening');
    for (var round = 0; round < 20; round++) {
      _edit(random, lines, pool);
      _expectFresh(engine, lines.join('\n'), reason: 'round $round');
    }
  });

  test('reads the clock again on every pass', () {
    var now = DateTime.utc(2026, 9, 9, 12);
    final engine = _engine('Asia/Kolkata', now: () => now);
    const body =
        'today\n'
        'now + 90 min\n'
        'deadline = today + 2 weeks\n'
        'deadline - 1 day\n'
        '2:30 pm in New York\n'
        'time in Madrid';
    expect(_texts(engine, body)[3], '22 Sep 2026');
    now = DateTime.utc(2026, 9, 10, 14);
    expect(_texts(engine, body)[3], '23 Sep 2026');
    _expectFresh(engine, body, timeZoneId: 'Asia/Kolkata', now: () => now);
  });

  test('draws a new random number on every pass', () {
    final engine = _engine(null);
    final draws = <double>{};
    for (var pass = 0; pass < 5; pass++) {
      final results = engine.evaluateDocument(
        'draw = random(10, 20)\ndraw * 2',
      );
      final draw = (results[0]!.value as NumberValue).value;
      expect((results[1]!.value as NumberValue).value, draw * 2);
      draws.add(draw);
    }
    expect(draws, hasLength(5));
  });

  test('reads a line again when a name above changes what it means', () {
    final engine = _engine(null);
    for (final (body, texts) in [
      ('h * 2', {0: '2 h'}),
      ('h = 5\nh * 2', {0: '5', 1: '10'}),
      ('h * 2', {0: '2 h'}),
      ('3 x 4', {0: '12'}),
      ('x = 5\n3 x 4', {0: '5'}),
      ('3 x 4', {0: '12'}),
      ('12 + mangoes', <int, String>{}),
      ('mangoes = 4\n12 + mangoes', {0: '4', 1: '16'}),
      ('mangoes = 5\n12 + mangoes', {0: '5', 1: '17'}),
      ('12 + mangoes', <int, String>{}),
    ]) {
      expect(_texts(engine, body), texts, reason: body);
    }
  });

  test('reads a line again when the lines above add up differently', () {
    final engine = _engine(null);
    for (final (body, texts) in [
      ('100\n+ 50\n* 2', {0: '100', 1: '150', 2: '300'}),
      ('200\n+ 50\n* 2', {0: '200', 1: '250', 2: '500'}),
      ('10\n20\ntotal\navg', {0: '10', 1: '20', 2: '30', 3: '15'}),
      ('10\n40\ntotal\navg', {0: '10', 1: '40', 2: '50', 3: '25'}),
      ('10\n40\n\ntotal\navg', {0: '10', 1: '40', 3: '50', 4: '25'}),
      ('10\nprev * 2\nsum', {0: '10', 1: '20', 2: '10'}),
      ('11\nprev * 2\nsum', {0: '11', 1: '22', 2: '11'}),
      ('10\nprev\n20\nsum', {0: '10', 1: '10', 2: '20', 3: '30'}),
      ('10\nx = 5\nx * 2\nsum', {0: '10', 1: '5', 2: '10', 3: '20'}),
      ('10\nx = 6\nx * 2\nsum', {0: '10', 1: '6', 2: '12', 3: '22'}),
    ]) {
      expect(_texts(engine, body), texts, reason: body);
    }
  });
}
