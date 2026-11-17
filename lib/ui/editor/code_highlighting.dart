import 'package:flutter/foundation.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/latex.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/objectivec.dart';
import 'package:re_highlight/languages/perl.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/plaintext.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/r.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scala.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

import 'markdown_syntax.dart';

/// What a stretch of code is, as far as colouring it goes.
enum CodeTokenKind {
  keyword,

  /// A function or value the language provides: Python's \`len\`.
  builtIn,
  string,
  number,
  comment,
  title,
  type,
  attribute,
  variable,
  punctuation,
}

/// [start, end) of the note, coloured as [kind].
typedef CodeToken = ({int start, int end, CodeTokenKind kind});

/// Fenced code coloured the way the language its info string names reads,
/// by highlight.js's grammars.
///
/// The languages a note is likely to hold, under the names and aliases
/// highlight.js gives them. A block in any other language, or in none, stays
/// plain code. Each block is coloured once for as long as its language and
/// its code stay the same, so typing in one block leaves the rest alone.
class CodeHighlighter {
  static final Highlight _grammars = Highlight()
    ..registerLanguage('bash', langBash)
    ..registerLanguage('c', langC)
    ..registerLanguage('cpp', langCpp)
    ..registerLanguage('csharp', langCsharp)
    ..registerLanguage('css', langCss)
    ..registerLanguage('dart', langDart)
    ..registerLanguage('diff', langDiff)
    ..registerLanguage('dockerfile', langDockerfile)
    ..registerLanguage('go', langGo)
    ..registerLanguage('graphql', langGraphql)
    ..registerLanguage('ini', langIni)
    ..registerLanguage('java', langJava)
    ..registerLanguage('javascript', langJavascript)
    ..registerLanguage('json', langJson)
    ..registerLanguage('kotlin', langKotlin)
    ..registerLanguage('latex', langLatex)
    ..registerLanguage('lua', langLua)
    ..registerLanguage('makefile', langMakefile)
    ..registerLanguage('markdown', langMarkdown)
    ..registerLanguage('objectivec', langObjectivec)
    ..registerLanguage('perl', langPerl)
    ..registerLanguage('php', langPhp)
    ..registerLanguage('plaintext', langPlaintext)
    ..registerLanguage('powershell', langPowershell)
    ..registerLanguage('python', langPython)
    ..registerLanguage('r', langR)
    ..registerLanguage('ruby', langRuby)
    ..registerLanguage('rust', langRust)
    ..registerLanguage('scala', langScala)
    ..registerLanguage('scss', langScss)
    ..registerLanguage('sql', langSql)
    ..registerLanguage('swift', langSwift)
    ..registerLanguage('typescript', langTypescript)
    ..registerLanguage('xml', langXml)
    ..registerLanguage('yaml', langYaml)
    ..registerAliases(['zsh', 'shell'], 'bash');

  Map<(String, String), List<CodeToken>> _coloured = const {};

  /// Every token of every block in [blocks], in order, in [text]'s offsets.
  List<CodeToken> tokensIn(String text, List<MarkdownCodeBlock> blocks) {
    final coloured = <(String, String), List<CodeToken>>{};
    final tokens = <CodeToken>[];
    for (final block in blocks) {
      final language = block.language.toLowerCase();
      if (_grammars.getLanguage(language) == null) continue;
      final code = block.code
          .map((range) => text.substring(range.start, range.end))
          .join();
      final key = (language, code);
      final relative = coloured[key] ??=
          _coloured[key] ?? _highlight(language, code);
      // The code of a quoted or indented block is in pieces, and a token can
      // run from one into the next.
      var piece = 0;
      var pieceStart = 0;
      for (final token in relative) {
        var from = token.start;
        while (from < token.end && piece < block.code.length) {
          final range = block.code[piece];
          final pieceEnd = pieceStart + range.end - range.start;
          if (from >= pieceEnd) {
            piece++;
            pieceStart = pieceEnd;
            continue;
          }
          final to = token.end < pieceEnd ? token.end : pieceEnd;
          tokens.add((
            start: range.start + from - pieceStart,
            end: range.start + to - pieceStart,
            kind: token.kind,
          ));
          from = to;
        }
      }
    }
    _coloured = coloured;
    return tokens;
  }

  static List<CodeToken> _highlight(String language, String code) {
    final tokens = _Tokens();
    try {
      _grammars.highlight(code: code, language: language).render(tokens);
    } catch (error, stack) {
      // A grammar that trips over some code costs that block its colours,
      // never the note its text.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kapy Notes editor',
          context: ErrorDescription('while colouring $language code'),
        ),
      );
      return const [];
    }
    return tokens.length == code.length ? tokens.tokens : const [];
  }
}

/// Reads highlight.js's tree of scopes into flat tokens, each coloured by the
/// innermost scope around it that has a colour.
class _Tokens implements HighlightRenderer {
  final tokens = <CodeToken>[];
  final _open = <CodeTokenKind?>[];
  var length = 0;

  @override
  void addText(String text) {
    final kind = _open.lastWhere((kind) => kind != null, orElse: () => null);
    if (kind != null && text.isNotEmpty) {
      final last = tokens.lastOrNull;
      if (last != null && last.end == length && last.kind == kind) {
        tokens.last = (
          start: last.start,
          end: length + text.length,
          kind: kind,
        );
      } else {
        tokens.add((start: length, end: length + text.length, kind: kind));
      }
    }
    length += text.length;
  }

  @override
  void openNode(DataNode node) => _open.add(_kindOf(node.scope));

  @override
  void closeNode(DataNode node) => _open.removeLast();

  static CodeTokenKind? _kindOf(String? scope) {
    if (scope == null) return null;
    if (scope.startsWith('title.class')) return CodeTokenKind.type;
    return switch (scope.split('.').first) {
      'built_in' => CodeTokenKind.builtIn,
      'keyword' ||
      'literal' ||
      'name' ||
      'selector-tag' ||
      'section' ||
      'doctag' ||
      'deletion' => CodeTokenKind.keyword,
      'string' ||
      'regexp' ||
      'symbol' ||
      'char' ||
      'addition' ||
      'code' ||
      'link' => CodeTokenKind.string,
      'number' => CodeTokenKind.number,
      'comment' || 'quote' => CodeTokenKind.comment,
      'title' || 'function' => CodeTokenKind.title,
      'type' || 'class' => CodeTokenKind.type,
      'attr' ||
      'attribute' ||
      'property' ||
      'selector-attr' ||
      'selector-class' ||
      'selector-id' ||
      'selector-pseudo' => CodeTokenKind.attribute,
      'variable' || 'template-variable' => CodeTokenKind.variable,
      'operator' ||
      'punctuation' ||
      'meta' ||
      'tag' ||
      'bullet' => CodeTokenKind.punctuation,
      _ => null,
    };
  }
}
