import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/speech/moments.dart';

List<TranscriptSegment> paragraph(int at, String text) => [
  TranscriptSegment(s: at, e: at + 2000, t: text),
];

void main() {
  final paragraphs = [
    paragraph(0, 'Thanks for jumping on. Let us go through the pricing page.'),
    paragraph(
      8000,
      'The main thing is the annual plan. People should see it first, '
      'with the monthly price underneath.',
    ),
    paragraph(
      38000,
      'Can we split the first invoice across two months? Finance said it '
      'is too big.',
    ),
  ];

  group('when a summary point was said', () {
    test('is the start of the paragraph that shares its words', () {
      expect(
        momentFor(
          'Show the annual plan first, with the monthly price under it.',
          paragraphs,
        ),
        const Duration(seconds: 8),
      );
      expect(
        momentFor(
          'Ask billing whether the first invoice can be split across two '
          'months.',
          paragraphs,
        ),
        const Duration(seconds: 38),
      );
    });

    test('is never made up when nothing matches well', () {
      // One shared word ("page") out of five is a coincidence, not a source.
      expect(
        momentFor('Send Arjun the deck; the page is due Friday.', paragraphs),
        isNull,
      );
      expect(momentFor('Book the dentist for Tuesday.', paragraphs), isNull);
    });

    test('is not guessed from a point with almost no words', () {
      expect(momentFor('Yes.', paragraphs), isNull);
      expect(momentFor('The plan.', paragraphs), isNull);
    });

    test('goes to the earlier paragraph on a tie', () {
      final twice = [
        paragraph(0, 'Ship the export fix.'),
        paragraph(5000, 'Ship the export fix, again.'),
      ];
      expect(momentFor('Ship the export fix.', twice), Duration.zero);
    });

    test('is nothing without a transcript', () {
      expect(momentFor('Ship the export fix today.', const []), isNull);
    });
  });

  group('the moments an answer draws on', () {
    test('are where its sentences were said, in order, none twice', () {
      expect(
        momentsIn(
          'Finance said the first invoice is too big, so split it across two '
          'months. The annual plan goes first, with the monthly price '
          'underneath.\nSplitting the first invoice across two months is the '
          'ask.',
          paragraphs,
        ),
        const [Duration(seconds: 8), Duration(seconds: 38)],
      );
    });

    test('come from each clause of a sentence that lists them', () {
      expect(
        momentsIn(
          'Two things: the annual plan first with the monthly price '
          'underneath, and the first invoice split across two months.',
          paragraphs,
        ),
        const [Duration(seconds: 8), Duration(seconds: 38)],
      );
    });

    test('are none when nothing matches well', () {
      expect(momentsIn('Sounds good. Talk soon.', paragraphs), isEmpty);
    });

    test('are the first three it names', () {
      final fruit = [
        paragraph(0, 'apples bananas cherries'),
        paragraph(10000, 'dates elderberries figs'),
        paragraph(20000, 'grapes honeydew kiwis'),
        paragraph(30000, 'lemons mangoes nectarines'),
      ];
      expect(
        momentsIn(
          'Lemons, mangoes and nectarines. Apples, bananas and cherries. '
          'Grapes, honeydew and kiwis. Dates, elderberries and figs.',
          fruit,
        ),
        const [Duration.zero, Duration(seconds: 20), Duration(seconds: 30)],
      );
    });
  });

  group('the pauses Skip pauses jumps', () {
    test('are the gaps over a second and a half, trimmed at both ends', () {
      final pauses = pausesIn(const [
        TranscriptSegment(s: 0, e: 1000, t: 'One.'),
        TranscriptSegment(s: 2000, e: 3000, t: 'A short breath.'),
        TranscriptSegment(s: 9000, e: 10000, t: 'After a long one.'),
      ]);
      expect(pauses, [
        (
          from: const Duration(milliseconds: 3300),
          to: const Duration(milliseconds: 8700),
        ),
      ]);
    });

    test('are none in speech without a long gap', () {
      expect(pausesIn(const []), isEmpty);
      expect(
        pausesIn(const [
          TranscriptSegment(s: 0, e: 1000, t: 'One.'),
          TranscriptSegment(s: 2500, e: 3000, t: 'Two.'),
        ]),
        isEmpty,
      );
    });
  });
}
