import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/number_words.dart';
import 'package:kapy_notes/calc/phrases.dart';

const _rates = <String, double>{'EUR': 0.5, 'GBP': 0.25, 'INR': 80.0};

String? _line(String source) =>
    CalcEngine(ratesPerUsd: _rates).evaluateDocument(source)[0]?.text;

int? _value(String words) => NumberWords.value(words);

void main() {
  group('number words with a currency', () {
    test('reads the amounts MAI writes in Hindi words', () {
      expect(_line('दोपहर का खाना दो सौ पचास रुपए'), '250.00 INR');
      expect(_line('टैक्सी एक सौ बीस रुपए'), '120.00 INR');
      expect(_line('खाना दो सौ पचास रुपये'), '250.00 INR');
      expect(_line('खाना सौ रुपये'), '100.00 INR');
      expect(_line('चाय पचास पैसे'), '0.50 INR');
    });

    test('reads rupees, paise, dollars and cents in English words', () {
      expect(_line('chai twenty rupees and fifty paise'), '20.50 INR');
      expect(_line('chai twenty rupees fifty paise'), '20.50 INR');
      expect(_line('lunch fifteen dollars and twenty cents'), '15.20 USD');
      expect(_line('tip twenty five cents'), '0.25 USD');
      expect(_line('lunch two hundred and fifty rupees'), '250.00 INR');
      expect(
        _line('rent thirty-eight thousand five hundred rupees'),
        '38,500.00 INR',
      );
      expect(_line('trip fifteen hundred rupees'), '1,500.00 INR');
    });

    test('reads Hindi words for dollars and cents', () {
      expect(_line('किताब पंद्रह डॉलर बीस सेंट'), '15.20 USD');
      expect(_line('किताब पंद्रह डॉलर'), '15.00 USD');
    });

    test('scales with lakh, crore and hazaar in words', () {
      expect(_line('budget one lakh twenty thousand rupees'), '120,000.00 INR');
      expect(_line('बजट दो लाख पचास हज़ार रुपये'), '250,000.00 INR');
      expect(_line('बजट दो लाख पचास हजार रुपये'), '250,000.00 INR');
      expect(_line('बजट एक करोड़ रुपये'), '10,000,000.00 INR');
      expect(_line('बजट एक करोड\u093C रुपये'), '10,000,000.00 INR');
      expect(_line('कमरा हज़ार रुपये'), '1,000.00 INR');
      expect(_line('पाँच हज़ार दो सौ रुपये'), '5,200.00 INR');
    });

    test('leaves a figure with a scale word to that figure', () {
      expect(_line('budget 2 lakh rupees'), '200,000.00 INR');
      expect(_line('बजट 5 सौ रुपये'), isNot('100.00 INR'));
    });

    test('says what each Hindi word is worth', () {
      const words = {
        'एक': 1,
        'पाँच': 5,
        'पांच': 5,
        'छह': 6,
        'दस': 10,
        'उन्नीस': 19,
        'इक्कीस': 21,
        'पच्चीस': 25,
        'उनतीस': 29,
        'अड\u093Cतीस': 38,
        'पैंतीस': 35,
        'उनचास': 49,
        'अड\u093Cतालीस': 48,
        'पचास': 50,
        'छप्पन': 56,
        'सड\u093Cसठ': 67,
        'अड\u093Cसठ': 68,
        'उनहत्तर': 69,
        'पचहत्तर': 75,
        'उन्यासी': 79,
        'अस्सी': 80,
        'नवासी': 89,
        'नब्बे': 90,
        'निन्यानवे': 99,
      };
      words.forEach((word, number) {
        expect(_value(word), number, reason: word);
      });
    });

    test('reads a nukta written as one letter or as two', () {
      expect(_line('खाना अ\u095Cतीस रुपये'), '38.00 INR');
      expect(_line('खाना अड\u093Cतीस रुपये'), '38.00 INR');
    });

    test('counts the words the way they are said', () {
      expect(_value('two hundred fifty'), 250);
      expect(_value('one hundred and five thousand'), 105000);
      expect(_value('twenty-five'), 25);
      expect(_value('दो सौ पचास'), 250);
      expect(_value('एक सौ और पाँच'), 105);
      expect(_value('two lakh fifty thousand'), 250000);
    });

    test('refuses words that do not make a number', () {
      expect(_value('one two'), isNull);
      expect(_value('twenty fifty'), isNull);
      expect(_value('twenty and fifty'), isNull);
      expect(_value('बीस पाँच'), isNull);
      expect(_value('two hundred hundred'), isNull);
      expect(_value('thousand lakh'), isNull);
      expect(_value('fifty thousand two lakh'), isNull);
      expect(_line('chai ten and five rupees'), isNull);
      expect(_line('chai one two rupees'), isNull);
    });
  });

  group('number words stay prose without a currency', () {
    test('plain sentences and bare number words are not calculations', () {
      expect(_line('I have two apples'), isNull);
      expect(_line('one two three'), isNull);
      expect(_line('twenty five'), isNull);
      expect(_line('दो सौ पचास'), isNull);
      expect(_line('मेरे पास दो भाई हैं'), isNull);
      expect(_line('meeting at five'), isNull);
    });

    test('a weight in pounds is not money', () {
      expect(_line('I weigh seventy pounds'), isNull);
      expect(Phrases.spoken('I weigh seventy pounds'), isNull);
    });

    test('a word that only holds a number word is left alone', () {
      expect(Phrases.spoken('someone paid money'), isNull);
      expect(Phrases.spoken('stone rupees'), isNull);
    });

    test('rewrites only the words before the currency', () {
      expect(Phrases.spoken('chai fifty paise'), 'chai 0.5 inr');
      expect(Phrases.spoken('lunch two hundred rupees'), 'lunch 200 rupees');
    });
  });
}
