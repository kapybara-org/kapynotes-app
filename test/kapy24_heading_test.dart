import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'golden_test.dart' show pumpForGolden, goldenNotes, goldenTags;
import 'package:flutter/services.dart';

final _out = Platform.environment['KAPY24_OUT'] ?? '/tmp/kapy24';
final _tag = Platform.environment['KAPY24_TAG'] ?? 'x';

const _lisbon = '# Lisbon trip\n'
    'Four days in May with Ana.\n'
    '☑ Book flights\n'
    '☑ Hotel in Alfama\n'
    '☐ Sintra train tickets\n'
    '☐ Pack adapters\n'
    '\n'
    '## Budget\n'
    '| Item | Cost |\n'
    '| --- | --- |\n'
    '| Flights | 412 |\n'
    '| Hotel | 896 |\n'
    '| Food tour | 38 |\n'
    '\n'
    'Total spend = 412 + 896 + 38';

Future<void> _shoot(WidgetTester tester, String name) async {
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  await tester.runAsync(() async {
    final image = await layer.toImage(view.paintBounds);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_out/$name.png').writeAsBytes(data!.buffer.asUint8List());
  });
}

void main() {
  Future<void> font(String family, String path) async {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
    await loader.load();
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    const sf = '/System/Library/Fonts/SFNS.ttf';
    for (final f in ['.AppleSystemUIFont', '.SF Pro Text']) {
      await font(f, sf);
    }
    await font('Noto Sans', '/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
    await font('SF Mono', '/System/Library/Fonts/SFNSMono.ttf');
    await font('Shantell Sans', 'assets/fonts/ShantellSans-Variable.ttf');
    await font('Figtree', 'assets/fonts/Figtree-Variable.ttf');
    await font('Geist Mono', 'assets/fonts/GeistMono-Variable.ttf');
    for (final extra in (Platform.environment['KAPY24_FONTS'] ?? '').split(';')) {
      if (extra.isEmpty) continue;
      final [family, path] = extra.split('=');
      await font(family, path);
    }
    Directory(_out).createSync(recursive: true);
  });

  for (final (name, platform, size, dpr, top, bottom) in [
    ('mac', TargetPlatform.macOS, const Size(1280, 800), 2.0, 0.0, 0.0),
    ('iphone', TargetPlatform.iOS, const Size(440, 956), 3.0, 62.0, 34.0),
  ]) {
    testWidgets('$name light lisbon', (tester) async {
      await pumpForGolden(tester,
          size: size, brightness: Brightness.light, platform: platform,
          withNote: false);
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = size * dpr;
      final pad = FakeViewPadding(top: top * dpr, bottom: bottom * dpr);
      tester.view.padding = pad;
      tester.view.viewPadding = pad;
      final trip = goldenTags.create('Trip')!;
      final money = goldenTags.create('Money')!;
      for (final body in [
        'Trip budget\nGo to Sintra on a weekday.',
        'Groceries\n☐ Oats\n☑ Milk',
        _lisbon,
      ]) {
        goldenNotes.create(body: body);
      }
      final note = goldenNotes.notes.firstWhere((n) => n.body == _lisbon);
      goldenTags.setTags(note.id, [trip.id, money.id]);
      await tester.pumpAndSettle();
      if (platform == TargetPlatform.iOS) {
        await tester.tap(find.byKey(const ValueKey('toolbar-notes-toggle')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Lisbon trip').first);
      await tester.pumpAndSettle();
      await _shoot(tester, '$name-light-$_tag');
    });
  }
}
