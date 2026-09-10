import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/system_region.dart';

/// Answers the region channel with [answer], or refuses to answer at all when
/// [handled] is false — which is what a platform with no handler behind the
/// channel looks like from Dart.
void answerWith(Object? answer, {bool handled = true}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    SystemRegion.channel,
    handled ? (call) async => answer : null,
  );
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemRegion.channel, null),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a country code comes back upper-cased and trimmed', () async {
    answerWith(' in ');
    expect(await SystemRegion.read(), 'IN');
  });

  test('a platform with nothing to say answers nothing', () async {
    answerWith(null);
    expect(await SystemRegion.read(), isNull);

    answerWith(null, handled: false);
    expect(await SystemRegion.read(), isNull);
  });

  test('anything that is not one country is no answer', () async {
    // "419" is Latin America — a group of countries rather than one, so there
    // is nothing to look it up as. The rest are a platform declining to say,
    // in the various ways platforms do.
    for (final answer in ['419', '', '  ', 'india', 'I1']) {
      answerWith(answer);
      expect(await SystemRegion.read(), isNull, reason: 'answered "$answer"');
    }
  });

  test('a platform error is an unanswered question, not a crash', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemRegion.channel,
      (call) async => throw PlatformException(code: 'nope'),
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemRegion.channel, null),
    );

    expect(await SystemRegion.read(), isNull);
  });
}
