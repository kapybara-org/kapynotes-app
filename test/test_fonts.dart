import 'dart:convert';
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
  // The system faces, which set the clean writing style and draw what Figtree
  // lacks. Arial stands in for the real San Francisco face, which ships only
  // inside .ttc collections that [FontLoader] cannot read.
  for (final family in [
    'Roboto',
    '.SF Pro Text',
    '.AppleSystemUIFont',
    'Segoe UI',
  ]) {
    await _load(family, ['/System/Library/Fonts/Supplemental/Arial.ttf']);
  }
  await _loadAll('Shantell Sans', [
    'assets/fonts/ShantellSans-Variable.ttf',
    'assets/fonts/ShantellSans-Italic-Variable.ttf',
  ]);
  await _loadAll('Inter', [
    'assets/fonts/Inter-Variable.ttf',
    'assets/fonts/Inter-Italic-Variable.ttf',
  ]);
  await _loadAll('Geist Mono', ['assets/fonts/GeistMono-Variable.ttf']);

  // KaTeX's faces, which flutter_math_fork draws formulas in. They are in the
  // test's asset bundle like every package font, and like every one of them
  // are only drawn once they are loaded.
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest.cast<Map<String, Object?>>()) {
    final family = entry['family']! as String;
    if (!family.startsWith('packages/flutter_math_fork/')) continue;
    final loader = FontLoader(family);
    for (final font in (entry['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
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
