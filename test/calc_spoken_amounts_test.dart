import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';

const _rates = <String, double>{'EUR': 0.5, 'GBP': 0.25, 'INR': 80.0};

String? _line(String source) =>
    CalcEngine(ratesPerUsd: _rates).evaluateDocument(source)[0]?.text;

void main() {
  group('compound amounts', () {
    test('adds the minor part to the major, with or without "and"', () {
      expect(_line('lunch 15 dollars and 20 cents'), '15.20 USD');
      expect(_line('lunch 15 dollars 20 cents'), '15.20 USD');
      expect(_line('tip 5 euros and 30 cents'), '5.30 EUR');
      expect(_line('3 pounds and 50 pence'), '3.50 GBP');
      expect(_line('chai 20 rupees and 50 paise'), '20.50 INR');
      expect(_line('chai 20 rupees 50 paise'), '20.50 INR');
      expect(_line('2 dollars and 5 cents'), '2.05 USD');
    });

    test('reads a minor unit on its own', () {
      expect(_line('20 cents'), '0.20 USD');
      expect(_line('chai 50 paise'), '0.50 INR');
    });

    test('keeps the amounts that already worked', () {
      expect(_line('lunch \$15.20'), '15.20 USD');
      expect(_line('lunch 15 dollars'), '15.00 USD');
      expect(_line('lunch 250 rupees'), '250.00 INR');
      expect(_line('lunch ₹250'), '250.00 INR');
      expect(_line('दोपहर का खाना ₹250'), '250.00 INR');
    });

    test('does not join a major and a minor of different currencies', () {
      expect(_line('15 dollars and 20 paise'), isNot('15.20 USD'));
      expect(_line('15 dollars and 20 pence'), isNot('15.20 USD'));
    });
  });

  group('Hindi and Hinglish currency words', () {
    test('reads rupees in Devanagari', () {
      for (final word in ['रुपये', 'रुपए', 'रुपया', 'रु.', 'रु']) {
        expect(_line('खाना 250 $word'), '250.00 INR', reason: word);
      }
      expect(_line('दोपहर का खाना 250 रुपये'), '250.00 INR');
    });

    test('reads rupees and paise, dollars and cents', () {
      expect(_line('चाय 20 रुपये 50 पैसे'), '20.50 INR');
      expect(_line('चाय 20 रुपये और 50 पैसे'), '20.50 INR');
      expect(_line('चाय 50 पैसे'), '0.50 INR');
      expect(_line('खाना 15 डॉलर 20 सेंट'), '15.20 USD');
      expect(_line('खाना 15 डॉलर'), '15.00 USD');
    });

    test('reads rs and rupay in Latin script', () {
      expect(_line('chai 250 rs'), '250.00 INR');
      expect(_line('chai 250 rupay'), '250.00 INR');
      expect(_line('chai 250 rupaye'), '250.00 INR');
      expect(_line('chai 20 rupay 50 paise'), '20.50 INR');
    });
  });

  group('lakh, crore and thousand words', () {
    test('scale the number before them', () {
      expect(_line('2.5 lakh'), '250,000');
      expect(_line('3 crore'), '30,000,000');
      expect(_line('3 करो\u095C'), '30,000,000');
      expect(_line('3 करोड\u093C'), '30,000,000');
      expect(_line('2.5 lakh rupees'), '250,000.00 INR');
      expect(_line('budget 3 crore rupees'), '30,000,000.00 INR');
      expect(_line('बजट 2.5 लाख रुपये'), '250,000.00 INR');
      expect(_line('5 हज\u093Cार रुपये'), '5,000.00 INR');
      expect(_line('5 ह\u095Bार रुपये'), '5,000.00 INR');
      expect(_line('5 हजार रुपए'), '5,000.00 INR');
    });

    test('leave a labelled number with no currency as the prose it is', () {
      expect(_line('budget 3 crore'), isNull);
      expect(_line('बजट 2.5 लाख'), isNull);
    });
  });

  group('the figures MAI writes', () {
    test('English amounts with and without separators', () {
      expect(_line('8 dollars'), '8.00 USD');
      expect(_line('1037 rupees'), '1,037.00 INR');
      expect(_line('1,111 rupees'), '1,111.00 INR');
      expect(_line('38,500 rupees'), '38,500.00 INR');
      expect(_line('4200 rupees'), '4,200.00 INR');
      expect(_line('6,850 rupees'), '6,850.00 INR');
    });

    test('Hindi amounts', () {
      expect(_line('19,500 रुपए'), '19,500.00 INR');
      expect(_line('3,240 रुपए'), '3,240.00 INR');
      expect(_line('4200 रुपए'), '4,200.00 INR');
    });

    test('Hindi and English in one line', () {
      expect(_line('यार आज lunch 450 rupees'), '450.00 INR');
    });
  });

  group('in a note', () {
    test('a spoken amount joins the total like a written one', () {
      final results = CalcEngine(
        ratesPerUsd: _rates,
      ).evaluateDocument('lunch 15 dollars and 20 cents\ndinner \$10\ntotal');
      expect(results[2]!.text, '25.20 USD');
    });

    test('a named spoken amount is counted once when it is used', () {
      final results = CalcEngine(
        ratesPerUsd: _rates,
      ).evaluateDocument('price = 15 dollars and 20 cents\nprice * 2');
      expect(results[1]!.text, '30.40 USD');
    });
  });
}
