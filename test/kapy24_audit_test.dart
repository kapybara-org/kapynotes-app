import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'golden_test.dart' show pumpForGolden, tapSettings;
import 'test_fonts.dart';

class _Device {
  const _Device(this.name, this.platform, this.size, this.dpr,
      {this.top = 0, this.bottom = 0});
  final String name;
  final TargetPlatform platform;
  final Size size;
  final double dpr;
  final double top;
  final double bottom;
  bool get phone =>
      platform == TargetPlatform.iOS || platform == TargetPlatform.android;
}

const _desk = Size(1280, 800);
const _devices = [
  _Device('mac-2x', TargetPlatform.macOS, _desk, 2),
  _Device('mac-1x', TargetPlatform.macOS, _desk, 1),
  _Device('win-100', TargetPlatform.windows, _desk, 1),
  _Device('win-125', TargetPlatform.windows, _desk, 1.25),
  _Device('win-150', TargetPlatform.windows, _desk, 1.5),
  _Device('iphone-se', TargetPlatform.iOS, Size(375, 667), 2, top: 20),
  _Device('iphone-promax', TargetPlatform.iOS, Size(440, 956), 3,
      top: 62, bottom: 34),
  _Device('android-pixel', TargetPlatform.android, Size(412, 915), 2.625,
      top: 24, bottom: 24),
];

final _out = Platform.environment['KAPY24_OUT'] ?? '/tmp/kapy24';

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
    await loadTestFonts();
    Directory(_out).createSync(recursive: true);
  });

  for (final d in _devices) {
    for (final b in Brightness.values) {
      final theme = b == Brightness.dark ? 'dark' : 'light';
      Future<void> pump(WidgetTester tester) async {
        await pumpForGolden(tester,
            size: d.size, brightness: b, platform: d.platform);
        tester.view.devicePixelRatio = d.dpr;
        tester.view.physicalSize = d.size * d.dpr;
        final pad = FakeViewPadding(top: d.top * d.dpr, bottom: d.bottom * d.dpr);
        tester.view.padding = pad;
        tester.view.viewPadding = pad;
        await tester.pumpAndSettle();
      }

      testWidgets('${d.name} $theme main', (tester) async {
        await pump(tester);
        await _shoot(tester, '${d.name}-$theme-main');
      });
      testWidgets('${d.name} $theme settings', (tester) async {
        await pump(tester);
        await tapSettings(tester);
        await tester.pumpAndSettle();
        await _shoot(tester, '${d.name}-$theme-settings');
      });
      testWidgets('${d.name} $theme third', (tester) async {
        await pump(tester);
        if (d.phone) {
          await tester.tap(find.byKey(const ValueKey('toolbar-notes-toggle')));
          await tester.pumpAndSettle();
          await _shoot(tester, '${d.name}-$theme-drawer');
        } else {
          await tester.tap(find.byKey(const ValueKey('sidebar-search-field')));
          await tester.pumpAndSettle();
          await _shoot(tester, '${d.name}-$theme-cmdk');
        }
      });
    }
  }
}
