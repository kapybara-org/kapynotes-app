import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('user-facing copy does not use em dashes', () {
    const nonCopyParsers = {
      'lib/calc/engine.dart',
      'lib/calc/lexer.dart',
      'lib/calc/parser.dart',
      'lib/speech/note_summary_text.dart',
    };
    final offenders = <String>[];

    for (final entry in Directory('lib').listSync(recursive: true)) {
      if (entry is! File || !entry.path.endsWith('.dart')) continue;
      final path = entry.path.replaceAll('\\', '/');
      if (nonCopyParsers.contains(path)) continue;

      for (final literal in _stringLiterals(entry.readAsStringSync())) {
        if (literal.text.contains('\u2014')) {
          offenders.add('$path:${literal.line}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Use a full stop, comma, colon, or shorter sentence instead.',
    );
  });
}

Iterable<({String text, int line})> _stringLiterals(String source) sync* {
  var index = 0;
  var line = 1;

  while (index < source.length) {
    if (source.startsWith('//', index)) {
      while (index < source.length && source[index] != '\n') {
        index++;
      }
      continue;
    }
    if (source.startsWith('/*', index)) {
      var depth = 1;
      index += 2;
      while (index < source.length && depth > 0) {
        if (source.startsWith('/*', index)) {
          depth++;
          index += 2;
        } else if (source.startsWith('*/', index)) {
          depth--;
          index += 2;
        } else {
          if (source[index] == '\n') line++;
          index++;
        }
      }
      continue;
    }

    var raw = false;
    if ((source[index] == 'r' || source[index] == 'R') &&
        index + 1 < source.length &&
        (source[index + 1] == "'" || source[index + 1] == '"')) {
      raw = true;
      index++;
    }

    final quote = source[index];
    if (quote != "'" && quote != '"') {
      if (quote == '\n') line++;
      index++;
      continue;
    }

    final startLine = line;
    final delimiter = '$quote$quote$quote';
    final triple = source.startsWith(delimiter, index);
    index += triple ? 3 : 1;
    final value = StringBuffer();

    while (index < source.length) {
      if (triple
          ? source.startsWith(delimiter, index)
          : source[index] == quote) {
        index += triple ? 3 : 1;
        break;
      }
      if (!raw && source[index] == '\\' && index + 1 < source.length) {
        value
          ..write(source[index])
          ..write(source[index + 1]);
        index += 2;
        continue;
      }
      if (source[index] == '\n') line++;
      value.write(source[index]);
      index++;
    }

    yield (text: value.toString(), line: startLine);
  }
}
