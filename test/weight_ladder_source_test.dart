import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Lines in lib/ that set a weight off the ladder on purpose, by file and
/// exact line (trimmed), with how many such lines the file holds and why.
/// Everything else that sets a fontWeight takes the ladder: chromeStyle,
/// ladder(), or AppWeight.font with AppWeight.wght beside it.
const Map<String, (int, String)> ladderExceptions = {
  'lib/ui/instant_capture.dart|fontWeight: FontWeight.w300,': (
    1,
    "Quick capture's light 300 in the system mono face, under 400, which "
        'AppWeight.axisOf leaves alone.',
  ),
  'lib/core/theme.dart|fontWeight: FontWeight.w400,': (
    1,
    "The writing's body (EditorMetrics.textStyle): note text takes its "
        "weight from the Writing font's own axes, not the interface ladder.",
  ),
  'lib/ui/editor/editor_formatting.dart|fontWeight: FontWeight.w400,': (
    1,
    'The writing: a paragraph style keeps the Writing font body weight.',
  ),
  'lib/ui/editor/editor_formatting.dart|fontWeight: EditorMetrics.titleWeight,':
      (1, 'The note title, 26 semibold, in the writing face.'),
  'lib/ui/editor/editor_formatting.dart|fontWeight: FontWeight.w600,': (
    1,
    'The writing: a Markdown heading in the Writing font.',
  ),
  'lib/ui/editor/highlighting_controller.dart|fontWeight: FontWeight.w600,': (
    3,
    'The writing: Markdown bold, a table header and a list marker in the '
        'Writing font.',
  ),
  'lib/ui/editor/highlighting_controller.dart|fontWeight: FontWeight.w400,': (
    1,
    'The writing: a link chip inside a note.',
  ),
  'lib/ui/editor/highlighting_controller.dart|fontWeight: FontWeight.w500,': (
    1,
    'The writing: a title token in a code block.',
  ),
  'lib/ui/editor/note_editor.dart|'
      'style: TextStyle(fontWeight: FontWeight.w700),': (
    1,
    "The empty note's placeholder shows the writing's own bold.",
  ),
  'lib/ui/editor/note_field.dart|fontWeight: widget.style.fontWeight,': (
    1,
    "The keyboard's TextInputStyle, which has no font variations to set.",
  ),
};

final _fontWeight = RegExp(r'fontWeight:\s*(.*)$');

/// Every line in [sources] (path to Dart source) that breaks the ladder, as
/// "path:line: why". An exception covers only as many lines as it counts.
List<String> ladderViolations(Map<String, String> sources) {
  final found = <String>[];
  final excused = <String, int>{};
  for (final MapEntry(key: path, value: source) in sources.entries) {
    final lines = source.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (line.startsWith('//')) continue;
      final where = '$path:${index + 1}';

      if (_fontWeight.firstMatch(line) case final match?) {
        var value = match[1]!.trim();
        if (value.isEmpty && index + 1 < lines.length) {
          value = lines[index + 1].trim();
        }
        final onLadder =
            (value.contains('AppWeight.font(') ||
                value.contains('AppWeight.named(')) &&
            !value.contains('FontWeight.');
        if (!onLadder) {
          final key = '$path|$line';
          final seen = excused[key] = (excused[key] ?? 0) + 1;
          if (seen > (ladderExceptions[key]?.$1 ?? 0)) {
            found.add('$where: a plain weight without the ladder: $line');
          }
        } else {
          final near = lines
              .sublist(
                (index - 3).clamp(0, lines.length),
                (index + 4).clamp(0, lines.length),
              )
              .join('\n');
          if (!near.contains('fontVariations:')) {
            found.add('$where: a ladder weight without its wght: $line');
          }
        }
      }

      if ((line.contains("FontVariation('wght'") ||
              line.contains('FontVariation.weight(')) &&
          path != 'lib/core/theme.dart') {
        found.add(
          '$where: a raw wght, which skips the ladder and Bold Text: $line',
        );
      }

      final variations = line.indexOf('AppWeight.variations(');
      if (variations != -1 && path != 'lib/core/theme.dart') {
        final call =
            line.substring(variations) +
            (index + 1 < lines.length ? lines[index + 1] : '');
        if (!call.contains('AppWeight.bold(')) {
          found.add(
            '$where: wght without AppWeight.bold, so Bold Text is skipped: '
            '$line',
          );
        }
      }
    }
  }
  return found;
}

Map<String, String> _lib() => {
  for (final file in Directory('lib').listSync(recursive: true))
    if (file is File && file.path.endsWith('.dart'))
      file.path.replaceAll(r'\', '/'): file.readAsStringSync(),
};

void main() {
  test('every text style in lib/ is on the weight ladder', () {
    expect(ladderViolations(_lib()), isEmpty);
  });

  test(
    'every documented exception names exactly as many lines as it counts',
    () {
      final lib = _lib();
      for (final MapEntry(key: key, value: (count, _))
          in ladderExceptions.entries) {
        final [path, line] = key.split('|');
        expect(
          lib[path]?.split('\n').where((each) => each.trim() == line),
          hasLength(count),
          reason: key,
        );
      }
    },
  );

  test('an exception covers only the lines it counts', () {
    const line = 'fontWeight: FontWeight.w400,';
    expect(
      ladderViolations({
        'lib/ui/instant_capture.dart': '  fontWeight: FontWeight.w300,\n',
      }),
      isEmpty,
    );
    expect(
      ladderViolations({
        'lib/ui/instant_capture.dart':
            '  fontWeight: FontWeight.w300,\n  fontWeight: FontWeight.w300,\n',
      }),
      hasLength(1),
    );
    expect(
      ladderViolations({'lib/ui/editor/note_field.dart': '  $line\n'}),
      hasLength(1),
    );
  });

  test('a raw wght outside theme.dart is caught', () {
    const raw = '''
final style = kapyText(13, 18, quiet).copyWith(
  fontVariations: const [FontVariation('wght', 520)],
);
''';
    const named = '''
final style = kapyText(13, 18, quiet).copyWith(
  fontVariations: const [FontVariation.weight(520)],
);
''';
    expect(ladderViolations({'lib/ui/planted.dart': raw}), hasLength(1));
    expect(ladderViolations({'lib/ui/planted.dart': named}), hasLength(1));
    expect(ladderViolations({'lib/core/theme.dart': raw}), isEmpty);
    expect(ladderViolations({'lib/core/theme.dart': named}), isEmpty);
  });

  test('a plain FontWeight in a text style is caught', () {
    expect(
      ladderViolations({
        'lib/ui/planted.dart': '''
final style = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w600,
);
final other = base.copyWith(fontWeight: FontWeight.bold);
final lit = TextStyle(
  fontWeight: lit
      ? FontWeight.w500
      : FontWeight.w400,
);
''',
      }),
      hasLength(3),
    );
  });

  test('a ladder weight with no wght beside it is caught', () {
    expect(
      ladderViolations({
        'lib/ui/planted.dart': '''
final style = TextStyle(
  fontSize: 13,
  height: 18 / 13,
  fontWeight: AppWeight.font(AppWeight.regular),
  color: ink,
);
''',
      }),
      hasLength(1),
    );
  });

  test('wght set without AppWeight.bold outside theme.dart is caught', () {
    const skipped = '''
final style = TextStyle(
  fontWeight: AppWeight.named(AppWeight.regular),
  fontVariations: AppWeight.variations(AppWeight.regular),
);
''';
    const wrapped = '''
final style = TextStyle(
  fontWeight: AppWeight.named(AppWeight.bold(AppWeight.regular)),
  fontVariations: AppWeight.variations(
    AppWeight.bold(AppWeight.regular),
  ),
);
''';
    expect(ladderViolations({'lib/ui/planted.dart': skipped}), hasLength(1));
    expect(ladderViolations({'lib/ui/planted.dart': wrapped}), isEmpty);
    expect(ladderViolations({'lib/core/theme.dart': skipped}), isEmpty);
  });

  test('a FontWeight handed to a helper that ladders it passes', () {
    expect(
      ladderViolations({
        'lib/ui/planted.dart': '''
final style = _chrome(13, 18, FontWeight.w500, palette.textPrimary);
TextStyle _chrome(double size, double line, FontWeight weight, Color color) =>
    chromeStyle(
      size: size,
      line: line,
      weight: AppWeight.axisOf(weight),
      color: color,
    );
''',
      }),
      isEmpty,
    );
  });
}
