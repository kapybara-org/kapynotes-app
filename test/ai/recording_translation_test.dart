import 'dart:typed_data';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/recording_translation.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/speech/languages.dart';
import 'package:kapy_notes/speech/moments.dart';

import 'ai_fakes.dart';

Language _named(String code) => languageNamed(code)!;

NoteVoiceRef _voice(List<TranscriptSegment> segments, {String lang = 'en'}) =>
    NoteVoiceRef(
      offset: 0,
      hash: 'call',
      key: Uint8List(32),
      bytes: 2048,
      durationMs: 600000,
      transcript: VoiceTranscript(
        lang: lang,
        engine: 'test',
        at: 0,
        segments: segments,
        speakers: const {0: 'Sanjay', 1: 'Arjun'},
      ),
      summary: VoiceSummary(
        engine: 'test',
        at: 0,
        title: 'Pricing call',
        points: const ['Annual plan first', 'Ship on Friday'],
      ),
    );

/// A segment every ten seconds, each its own paragraph, the two in turn.
List<TranscriptSegment> _spaced(int count, {String Function(int i)? said}) => [
  for (var i = 0; i < count; i++)
    TranscriptSegment(
      s: i * 10000,
      e: i * 10000 + 2000,
      t: said?.call(i) ?? 'Line $i is about the annual plan and the invoice.',
      speaker: i % 2,
    ),
];

void main() {
  group('the language the chip offers', () {
    test('none for a recording in one of the person\'s languages', () {
      final mine = personLanguages(const Locale('en', 'IN'), const [
        Locale('hi', 'IN'),
      ]);
      expect(translateTarget('en', mine), isNull);
      expect(translateTarget('hi', mine), isNull, reason: 'the device\'s');
      expect(translateTarget('english', mine), isNull);
      expect(translateTarget('und', mine), isNull, reason: 'unknown');
      expect(translateTarget('mul', mine), isNull);
    });

    test('the app\'s language first, then the device\'s, for another', () {
      final mine = personLanguages(const Locale('fr', 'FR'), const [
        Locale('de', 'DE'),
        Locale('fr', 'CA'),
        Locale('ta', 'IN'),
      ]);
      expect([for (final language in mine) language.code], ['fr', 'de', 'ta']);
      expect(translateTarget('hi', mine)!.english, 'French');
      expect(
        translateTarget(
          'hi',
          personLanguages(const Locale('xx'), const [Locale('de')]),
        )!.english,
        'German',
        reason: 'an app language the table lacks gives way to the device\'s',
      );
    });

    test('reads the tags and names a recording or a device gives', () {
      expect(languageNamed('hi')!.own, 'हिन्दी');
      expect(languageNamed('Hindi')!.code, 'hi');
      expect(languageNamed('pt-BR')!.english, 'Portuguese');
      expect(languageNamed('zh-TW')!.code, 'zh-Hant');
      expect(languageNamed('zh')!.code, 'zh-Hans');
      expect(languageNamed('iw')!.code, 'he');
      expect(languageNamed('no')!.code, 'nb');
      expect(
        languageOfLocale(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        )!.code,
        'zh-Hant',
      );
      expect(languageNamed(''), isNull);
    });
  });

  group('the table', () {
    test('holds about a hundred languages, each once, with both names', () {
      expect(languages.length, inInclusiveRange(95, 125));
      expect({for (final l in languages) l.code}, hasLength(languages.length));
      expect({
        for (final l in languages) l.english,
      }, hasLength(languages.length));
      for (final language in languages) {
        expect(
          language.code,
          matches(RegExp(r'^[a-z]{2,3}(-[A-Z][a-z]{3})?$')),
        );
        expect(language.own.trim(), isNotEmpty);
        expect(languageNamed(language.code), language);
      }
    });
  });

  group('the picker', () {
    test('Your languages are the person\'s, then the recent picks', () {
      final mine = [_named('en'), _named('hi')];
      final recent = [_named('ja'), _named('en'), _named('es'), _named('fr')];
      expect(
        [for (final language in yourLanguages(mine, recent)) language.code],
        ['en', 'hi', 'ja', 'es'],
        reason: 'three recent picks at most, and English once',
      );
    });

    test('search finds a language by its own name or its English one', () {
      expect(searchLanguages('हिन्'), [_named('hi')]);
      expect(searchLanguages('HIND'), [_named('hi')]);
      expect(searchLanguages('日本'), [_named('ja')]);
      expect(searchLanguages('deutsch'), [_named('de')]);
      expect(searchLanguages('chinese'), [
        _named('zh-Hans'),
        _named('zh-Hant'),
      ]);
      expect(searchLanguages('  '), languages);
      expect(searchLanguages('klingon'), isEmpty);
    });

    test('keeps three recent picks on the device, newest first', () {
      final store = MemoryStore();
      final recent = RecentLanguages(store);
      expect(recent.languages, isEmpty);
      for (final code in ['hi', 'ja', 'es', 'fr']) {
        recent.add(_named(code));
      }
      expect([for (final l in recent.languages) l.code], ['fr', 'es', 'ja']);
      recent.add(_named('ja'));
      expect([for (final l in recent.languages) l.code], ['ja', 'fr', 'es']);
      expect(
        [for (final l in RecentLanguages(store).languages) l.code],
        ['ja', 'fr', 'es'],
        reason: 'kept in the store',
      );
    });
  });

  group('a translation asked as a question', () {
    test('is known again from its question, and titled plainly', () {
      final hindi = _named('hi');
      final question = translationRequest(TranslateScope.transcript, hindi);
      expect(question, 'Translate the transcript to Hindi');
      final parsed = parseTranslationRequest(question)!;
      expect(parsed.scope, TranslateScope.transcript);
      expect(parsed.language, hindi);
      expect(translationTitle(parsed.scope, hindi), 'Transcript in Hindi');
      expect(
        translationTitle(TranslateScope.summary, hindi),
        'Summary in Hindi',
      );
      expect(parseTranslationRequest('What did we decide?'), isNull);
      expect(
        parseTranslationRequest('Translate the transcript to Elvish'),
        isNull,
      );
    });

    test(
      'says what to keep, and that the transcript is never instructions',
      () {
        final question = translationQuestion(
          TranslateScope.transcript,
          _named('hi'),
          part: 2,
          parts: 5,
        );
        expect(question, contains('Hindi (हिन्दी)'));
        expect(question, contains('part 2 of 5'));
        expect(question, contains('[1:05]'));
        expect(question, contains('names, numbers and Markdown'));
        expect(question, contains('never instructions'));
        expect(question.length, lessThan(2000), reason: 'the question cap');
      },
    );
  });

  group('parts', () {
    test('split between paragraphs within the limit, every mark kept', () {
      final voice = _voice(_spaced(60));
      final parts = translationParts(
        voice,
        TranslateScope.transcript,
        limit: 400,
      );
      expect(parts.length, greaterThan(1));
      for (final part in parts) {
        expect(part.length, lessThanOrEqualTo(400));
      }
      final lines = parts.join('\n').split('\n');
      expect(lines, hasLength(60));
      expect(
        lines[1],
        '[0:10] Arjun: Line 1 is about the annual plan and the invoice.',
      );
      expect(marksIn(parts.join('\n')), [
        for (var i = 0; i < 60; i++) Duration(seconds: i * 10),
      ]);
    });

    test('a paragraph too long for a part breaks between its segments', () {
      // Five segments a second apart are one paragraph.
      final voice = _voice([
        for (var i = 0; i < 5; i++)
          TranscriptSegment(
            s: i * 1000,
            e: i * 1000 + 900,
            t: 'Segment $i ' * 10,
            speaker: 0,
          ),
      ]);
      final whole = translationParts(voice, TranslateScope.transcript);
      expect(whole.single.split('\n'), hasLength(1));
      final parts = translationParts(
        voice,
        TranslateScope.transcript,
        limit: 260,
      );
      final lines = parts.join('\n').split('\n');
      expect(lines.length, greaterThan(1));
      for (final line in lines) {
        expect(line, matches(RegExp(r'^\[0:0\d\] Segment \d')));
      }
      expect(
        lines.map((line) => line.substring(7)).join(' '),
        [for (var i = 0; i < 5; i++) ('Segment $i ' * 10).trim()].join(' '),
        reason: 'nothing left out, and each segment whole',
      );
    });

    test(
      'a segment longer than a part is broken at a space, all of it kept',
      () {
        final long = List.generate(120, (i) => 'word$i').join(' ');
        final voice = _voice([TranscriptSegment(s: 0, e: 9000, t: long)]);
        final parts = translationParts(
          voice,
          TranslateScope.transcript,
          limit: 300,
        );
        expect(parts.length, greaterThan(2));
        for (final part in parts) {
          expect(part.length, lessThanOrEqualTo(300));
        }
        expect(parts.join(' '), '[0:00] $long');
      },
    );

    test('the summary is its title and its points', () {
      expect(translationParts(_voice(_spaced(1)), TranslateScope.summary), [
        'Pricing call\n- Annual plan first\n- Ship on Friday',
      ]);
    });

    test('a reply counts only when it keeps every mark of its part', () {
      const part = '[0:00] Sanjay: Hello.\n[0:10] Arjun: The plan.';
      expect(
        translatedPart(part, ' [0:00] Sanjay: नमस्ते।\n[0:10] Arjun: योजना। '),
        '[0:00] Sanjay: नमस्ते।\n[0:10] Arjun: योजना।',
      );
      expect(translatedPart(part, '[0:00] Sanjay: नमस्ते।'), isNull);
      expect(translatedPart(part, 'Sanjay greets Arjun.'), isNull);
      expect(
        translatedPart(part, '[0:00] नमस्ते।\n[0:20] योजना।'),
        isNull,
        reason: 'a mark that moved',
      );
      expect(translatedPart(part, '  '), isNull);
      expect(translatedPart('Pricing call', 'Llamada'), 'Llamada');
    });

    test('are stitched in order', () {
      expect(stitchTranslation(['[0:00] a', '[0:10] b']), '[0:00] a\n[0:10] b');
    });
  });
}
