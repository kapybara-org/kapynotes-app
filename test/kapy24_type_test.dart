import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'golden_test.dart' show pumpForGolden, goldenNotes;

const _note = '''Kitchen renovation
Notes from the call with Marta on Tuesday. She can start the week of 14 December if we confirm the tiles by Friday, and she needs the worktop measured before the cabinets go in.

Budget
cabinets = 3200 eur
worktop = 1450 eur
tiles = 38 * 42 eur
labour = 6 * 280 eur
cabinets + worktop + tiles + labour

Still open
☐ Does the quote include taking the old units away
☐ Ask about a second socket by the window
The extractor stays where it is, so there is no new duct through the wall.
''';

class _D {
  const _D(this.name, this.platform, this.size, this.dpr, {this.top = 0, this.bottom = 0});
  final String name;
  final TargetPlatform platform;
  final Size size;
  final double dpr;
  final double top;
  final double bottom;
}

const _devices = [
  _D('mac-2x', TargetPlatform.macOS, Size(1120, 760), 2),
  _D('win-125', TargetPlatform.windows, Size(1120, 760), 1.25),
  _D('win-150', TargetPlatform.windows, Size(1120, 760), 1.5),
  _D('iphone-promax', TargetPlatform.iOS, Size(440, 956), 3, top: 62, bottom: 34),
  _D('android-pixel', TargetPlatform.android, Size(412, 915), 2.625, top: 24, bottom: 24),
];

final _out = Platform.environment['KAPY24_OUT'] ?? '/tmp/kapy24';
final _tag = Platform.environment['KAPY24_TAG'] ?? 'before';

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

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
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    const sf = '/System/Library/Fonts/SFNS.ttf';
    for (final f in ['.AppleSystemUIFont', '.SF Pro Text']) {
      await _font(f, [sf]);
    }
    await _font('Roboto', [Platform.environment['KAPY24_ROBOTO']!]);
    await _font('Segoe UI', ['/System/Library/Fonts/Supplemental/Arial.ttf']);
    await _font('SF Mono', ['/System/Library/Fonts/SFNSMono.ttf']);
    await _font('Shantell Sans', ['assets/fonts/ShantellSans-Variable.ttf']);
    await _font('Figtree', ['assets/fonts/Figtree-Variable.ttf']);
    await _font('Geist Mono', ['assets/fonts/GeistMono-Variable.ttf']);
    Directory(_out).createSync(recursive: true);
  });

  for (final d in _devices) {
    for (final b in Brightness.values.where((b) => Platform.environment['KAPY24_ONLY'] == null || b.name == Platform.environment['KAPY24_ONLY'])) {
      testWidgets('${d.name} ${b.name}', (tester) async {
        await pumpForGolden(tester, size: d.size, brightness: b, platform: d.platform);
        goldenNotes.updateBody(goldenNotes.notes.first.id, _note);
        tester.view.devicePixelRatio = d.dpr;
        tester.view.physicalSize = d.size * d.dpr;
        final pad = FakeViewPadding(top: d.top * d.dpr, bottom: d.bottom * d.dpr);
        tester.view.padding = pad;
        tester.view.viewPadding = pad;
        await tester.pumpAndSettle();
        await _shoot(tester, 'type-${d.name}-${b.name}-$_tag');
      });
    }
  }
}
