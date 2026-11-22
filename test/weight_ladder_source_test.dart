import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Lines in lib/ that set a weight off the ladder on purpose, by file and
/// exact line (trimmed), with the reason. Everything else that sets a
/// fontWeight takes the ladder: chromeStyle, ladder(), or AppWeight.font
/// with AppWeight.wght beside it.
const Map<String, String> ladderExceptions = {
  'lib/core/theme.dart|fontWeight: FontWeight.w300,':
      'The display cut, under 400, which AppWeight.axisOf leaves alone.',
  'lib/ui/instant_capture.dart|fontWeight: FontWeight.w300,':
      "Quick capture's light 300 in the system mono face, under 400, which "
      'AppWeight.axisOf leaves alone.',
  'lib/core/theme.dart|fontWeight: FontWeight.w400,':
      "The writing's body (EditorMetrics.textStyle): note text takes its "
      "weight from the Writing font's own axes, not the interface ladder.",
  'lib/ui/editor/editor_formatting.dart|fontWeight: FontWeight.w400,':
      'The writing: a paragraph style keeps the Writing font body weight.',
  'lib/ui/editor/editor_formatting.dart|'
          'fontWeight: strong ? FontWeight.w600 : FontWeight.w400,':
      "The note title in Newsreader's static cut, which has no wght axis.",
  'lib/ui/editor/editor_formatting.dart|'
          'fontWeight: strong ? FontWeight.w600 : EditorMetrics.titleWeight,':
      'The note title in the Writing font the person chose; the writing '
      "keeps its own weights, not the interface ladder's.",
  'lib/ui/editor/editor_formatting.dart|fontWeight: FontWeight.w600,':
      'The writing: a Markdown heading in the Writing font.',
  'lib/ui/editor/highlighting_controller.dart|fontWeight: FontWeight.w600,':
      'The writing: Markdown bold, a table header and a list marker in the '
      'Writing font.',
  'lib/ui/editor/highlighting_controller.dart|fontWeight: FontWeight.w400,':
      'The writing: a link chip inside a note.',
  'lib/ui/editor/highlighting_controller.dart|fontWeight: FontWeight.w500,':
      'The writing: a title token in a code block.',
  'lib/ui/editor/note_editor.dart|'
          'style: TextStyle(fontWeight: FontWeight.w700),':
      "The empty note's placeholder shows the writing's own bold.",
  'lib/ui/editor/note_field.dart|fontWeight: widget.style.fontWeight,':
      "The keyboard's TextInputStyle, which has no font variations to set.",
};

final _fontWeight = RegExp(r'fontWeight:\s*(.*)$');

/// Every line in [sources] (path to Dart source) that breaks the ladder, as
/// "path:line: why".
List<String> ladderViolations(Map<String, String> sources) {
  final found = <String>[];
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
          if (!ladderExceptions.containsKey('$path|$line')) {
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

  test('every documented exception still names a line in lib/', () {
    final lib = _lib();
    for (final key in ladderExceptions.keys) {
      final [path, line] = key.split('|');
      expect(
        lib[path]?.split('\n').map((each) => each.trim()),
        contains(line),
        reason: key,
      );
    }
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
  fontWeight: AppWeight.font(AppWeight.section),
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
  fontWeight: AppWeight.named(AppWeight.section),
  fontVariations: AppWeight.variations(AppWeight.section),
);
''';
    const wrapped = '''
final style = TextStyle(
  fontWeight: AppWeight.named(AppWeight.bold(AppWeight.section)),
  fontVariations: AppWeight.variations(
    AppWeight.bold(AppWeight.section),
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
final style = _figtree(13, 18, FontWeight.w500, palette.textPrimary);
TextStyle _figtree(double size, double line, FontWeight weight, Color color) =>
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
