import 'dart:ui' show Locale, TextRange;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/platform_spell_check.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('kapynotes/spell_check');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'turns the desktop system result into Flutter suggestion spans',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'check');
        expect(call.arguments, {'language': 'en-US', 'text': 'A smple note'});
        return [
          {
            'startIndex': 2,
            'endIndex': 7,
            'suggestions': ['simple', 'sample'],
          },
        ];
      });
      final service = PlatformSpellCheckService(quietPeriod: Duration.zero);
      addTearDown(service.dispose);

      final spans = await service.fetchSpellCheckSuggestions(
        const Locale('en', 'US'),
        'A smple note',
      );

      expect(spans, hasLength(1));
      expect(spans!.single.range, const TextRange(start: 2, end: 7));
      expect(spans.single.suggestions, ['simple', 'sample']);
    },
  );

  test(
    'ignores malformed native ranges instead of disturbing typing',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => [
          {
            'startIndex': -1,
            'endIndex': 4,
            'suggestions': ['bad'],
          },
          {
            'startIndex': 2,
            'endIndex': 99,
            'suggestions': ['also bad'],
          },
          {'startIndex': 0, 'endIndex': 4, 'suggestions': 'not a list'},
        ],
      );
      final service = PlatformSpellCheckService(quietPeriod: Duration.zero);
      addTearDown(service.dispose);

      expect(
        await service.fetchSpellCheckSuggestions(
          const Locale('en', 'US'),
          'note',
        ),
        isEmpty,
      );
    },
  );

  test('only checks the latest edit after the quiet period', () async {
    final checked = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      checked.add((call.arguments as Map<Object?, Object?>)['text']! as String);
      return const [];
    });
    final service = PlatformSpellCheckService(
      quietPeriod: const Duration(milliseconds: 10),
    );
    addTearDown(service.dispose);

    final first = service.fetchSpellCheckSuggestions(
      const Locale('en', 'US'),
      'fir',
    );
    final second = service.fetchSpellCheckSuggestions(
      const Locale('en', 'US'),
      'first',
    );

    expect(await first, isNull);
    expect(await second, isEmpty);
    expect(checked, ['first']);
  });
}
