import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'golden_test.dart' show pumpForGolden, tapSettings;
import 'test_fonts.dart';

final _out = Platform.environment['KAPY24_OUT'] ?? '/tmp/kapy24';
final _log = StringBuffer();

Future<void> _check(WidgetTester tester, String name, List<AccessibilityGuideline> guides) async {
  final handle = tester.ensureSemantics();
  await tester.pumpAndSettle();
  for (final g in guides) {
    final result = await g.evaluate(tester);
    _log.writeln('### $name · ${g.description}: ${result.passed ? 'pass' : 'FAIL'}');
    if (!result.passed) _log.writeln(result.reason);
  }
  handle.dispose();
}

void main() {
  setUpAll(loadTestFonts);
  tearDownAll(() => File('$_out/a11y.md').writeAsStringSync(_log.toString()));

  for (final p in [TargetPlatform.iOS, TargetPlatform.android]) {
    final phone = [p == TargetPlatform.iOS ? iOSTapTargetGuideline : androidTapTargetGuideline, textContrastGuideline];
    for (final b in Brightness.values) {
      final tag = '${p.name} ${b.name}';
      testWidgets('$tag main', (tester) async {
        await pumpForGolden(tester, size: const Size(375, 667), brightness: b, platform: p);
        await _check(tester, '$tag main', phone);
      });
      testWidgets('$tag drawer', (tester) async {
        await pumpForGolden(tester, size: const Size(375, 667), brightness: b, platform: p);
        await tester.tap(find.byKey(const ValueKey('toolbar-notes-toggle')));
        await tester.pumpAndSettle();
        await _check(tester, '$tag drawer', phone);
      });
      testWidgets('$tag settings', (tester) async {
        await pumpForGolden(tester, size: const Size(375, 667), brightness: b, platform: p);
        await tapSettings(tester);
        await tester.pumpAndSettle();
        await _check(tester, '$tag settings', phone);
      });
    }
  }
  for (final b in Brightness.values) {
    testWidgets('macOS ${b.name} main contrast', (tester) async {
      await pumpForGolden(tester, size: const Size(1280, 800), brightness: b, platform: TargetPlatform.macOS);
      await _check(tester, 'macOS ${b.name} main', [textContrastGuideline]);
    });
    testWidgets('macOS ${b.name} settings contrast', (tester) async {
      await pumpForGolden(tester, size: const Size(1280, 800), brightness: b, platform: TargetPlatform.macOS);
      await tapSettings(tester);
      await tester.pumpAndSettle();
      await _check(tester, 'macOS ${b.name} settings', [textContrastGuideline]);
    });
  }
}
