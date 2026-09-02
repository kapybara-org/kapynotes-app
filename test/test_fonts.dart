import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads real system fonts into the test binary.
///
/// The default test font draws every glyph as a filled box, which is fine for
/// layout assertions but useless for a golden you actually want to look at.
/// These are macOS system faces, so goldens are only meaningful when
/// regenerated on macOS.
Future<void> loadTestFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final materialIcons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await materialIcons.load();
  await _load('SF Mono', ['/System/Library/Fonts/SFNSMono.ttf']);
  // Flutter's default UI family on macOS. Arial stands in for the real San
  // Francisco face, which ships only inside .ttc collections that
  // [FontLoader] cannot read.
  for (final family in ['Roboto', '.SF Pro Text', '.AppleSystemUIFont']) {
    await _load(family, ['/System/Library/Fonts/Supplemental/Arial.ttf']);
  }
  await _load('OdinRounded', ['assets/fonts/OdinRounded-Bold.otf']);
  await _loadAll('Shantell Sans', [
    'assets/fonts/ShantellSans-Variable.ttf',
    'assets/fonts/ShantellSans-Italic-Variable.ttf',
  ]);
}

Future<void> _load(String family, List<String> candidates) async {
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = await file.readAsBytes();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    return;
  }
}

Future<void> _loadAll(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var found = false;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = await file.readAsBytes();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
    found = true;
  }
  if (found) await loader.load();
}
