import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'mathml_tex.dart';
import 'paste_tree.dart';

/// Image bytes a clipboard carried alongside its markup, by the URL or file
/// name the markup refers to them by: Safari's web archive, an RTFD's
/// attachments.
typedef PasteResources = Map<String, ({Uint8List bytes, String mime})>;

/// Reads clipboard HTML into [PasteBlock]s.
///
/// HTML on a clipboard is whatever the source app thought would survive a
/// trip into another app: a browser's serialization of the selection with
/// computed styles inlined, Google Docs' spans with weights in their style
/// attributes, Word's paragraphs pretending to be lists, KaTeX's three copies
/// of every formula. This keeps what was meant — structure, emphasis, links,
/// math, code, pictures — and throws away how it was drawn.
class HtmlPasteReader {
  HtmlPasteReader({this.baseUrl, this.resources = const {}});

  /// The page the selection came from, for its relative links and pictures.
  final Uri? baseUrl;
  final PasteResources resources;

  final _CssSheet _css = _CssSheet();

  /// The size most of the words are set in, for markup that says what is a
  /// heading only by its size: Apple's, from Notes, Pages and TextEdit.
  double? _textSize;

  /// Whether the markup is a word processor's (Google Docs, Word), where
  /// code is written as paragraphs set in a monospace face.
  var _editorDocument = false;

  List<PasteBlock> read(String html) {
    final document = html_parser.parse(_withoutDownlevelConditionals(html));
    for (final style in document.querySelectorAll('style')) {
      _css.add(style.text);
    }
    final root = document.body ?? document.documentElement;
    if (root == null) return const [];
    final generator = document
        .querySelector('meta[name="Generator"]')
        ?.attributes['content'];
    _textSize = generator != null && generator.startsWith('Cocoa HTML Writer')
        ? _commonSize(root)
        : null;
    _editorDocument =
        html.contains('docs-internal-guid') ||
        (generator?.startsWith('Microsoft') ?? false);
    _rewriteWordLists(root);
    _splitTaskItems(root);
    final out = _Builder();
    _walkChildren(root, const _Context(), out);
    out.flush();
    return _mergeAdjacentCode(out.blocks);
  }

  /// Whether [html] is code that a code editor copied: every word set in a
  /// monospace face and nothing else to say — no headings, lists, links,
  /// tables or pictures. JetBrains, Xcode's rich text and terminals write
  /// their colours this way, and the words are the code.
  bool readsAsCode(String html) {
    final document = html_parser.parse(html);
    for (final style in document.querySelectorAll('style')) {
      _css.add(style.text);
    }
    final root = document.body;
    if (root == null) return false;
    const structure =
        'pre, code, h1, h2, h3, h4, h5, h6, li, table, img, a[href], '
        'blockquote';
    if (root.querySelector(structure) != null) return false;
    var words = false;
    final pending = <dom.Node>[root];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node is dom.Text) {
        if (node.data.trim().isEmpty) continue;
        words = true;
        if (!_monospaced(node.parent)) return false;
        continue;
      }
      if (node is dom.Element && _dropped.contains(node.localName)) continue;
      pending.addAll(node.nodes);
    }
    return words;
  }

  bool _monospaced(dom.Element? element) {
    for (var at = element; at != null; at = at.parent) {
      final declarations = _css.declarationsFor(at);
      final face =
          declarations['font-family'] ??
          declarations['font'] ??
          at.attributes['face'];
      if (face != null) {
        return _monospace.hasMatch(face.split(',').first);
      }
    }
    return false;
  }

  /// Whether a word processor's paragraph is a line of code: every word in
  /// it set in a monospace face, with nothing in it a code block can't hold.
  bool _isCodeParagraph(dom.Element paragraph) {
    if (paragraph.querySelector('a[href], img') != null) return false;
    var words = false;
    final pending = <dom.Node>[paragraph];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node is dom.Text) {
        if (node.data.trim().isEmpty) continue;
        words = true;
        if (!_monospaced(node.parent)) return false;
        continue;
      }
      pending.addAll(node.nodes);
    }
    return words;
  }

  static final _monospace = RegExp(
    r'mono|menlo|monaco|consolas|courier|jetbrains|fira ?code|source ?code|'
    r'cascadia|inconsolata|hack\b',
    caseSensitive: false,
  );

  // ---------------------------------------------------------------------
  // Walking

  void _walkChildren(dom.Node parent, _Context context, _Builder out) {
    for (final node in parent.nodes) {
      _walk(node, context, out);
    }
  }

  void _walk(dom.Node node, _Context context, _Builder out) {
    if (node is dom.Text) {
      out.line.addText(node.data, context);
      return;
    }
    if (node is! dom.Element) return;
    final element = node;
    final tag = element.localName ?? '';
    if (_dropped.contains(tag) || _droppedClass(element)) return;
    final declarations = _css.declarationsFor(element);
    if (_isHidden(element, declarations) &&
        !_isMath(element) &&
        element.querySelector('math') == null) {
      return;
    }

    if (_isMath(element)) {
      final math = _readMath(element);
      if (math != null) {
        if (math.display) {
          out.flush();
          out.blocks.add(PasteMathBlock(math.tex));
        } else {
          out.line.add(PasteMath(math.tex));
        }
        return;
      }
    }

    // Perplexity's source chip: its source's name, linked, and set apart
    // from the sentence it ends.
    final citation = element.attributes['data-pplx-citation-url'];
    if (citation != null) {
      final label = element.text.replaceAll(RegExp(r'\s*\+\d+\s*$'), '').trim();
      final href = _resolveLink(citation);
      if (label.isNotEmpty && href != null) {
        out.line
          ..addText(' ', context)
          ..addText(label, _Context(styles: context.styles, href: href));
      }
      return;
    }

    final inner = _styled(element, declarations, context);

    if (tag == 'p' && _editorDocument && _isCodeParagraph(element)) {
      out.flush();
      out.blocks.add(PasteCode(_codeText(element).trimRight()));
      return;
    }

    final wordTitle = tag == 'p'
        ? _wordTitleLevel(element) ?? _sizedTitleLevel(element)
        : null;
    if (wordTitle != null) {
      out.flush();
      final inlines = _inlinesOf(element, inner);
      if (_hasWords(inlines)) {
        out.blocks.add(PasteHeading(wordTitle, _unboldedHeading(inlines)));
      }
      return;
    }

    switch (tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        out.flush();
        final inlines = _inlinesOf(element, inner);
        if (_hasWords(inlines)) {
          out.blocks.add(
            PasteHeading(
              int.parse(tag.substring(1)),
              _unboldedHeading(inlines),
            ),
          );
        }
        return;
      case 'ul' || 'ol' || 'menu' || 'dir':
        out.flush();
        final list = _readList(element, inner);
        if (list.items.isNotEmpty) out.blocks.add(list);
        return;
      case 'li':
        // An item with no list around it: what a selection that starts
        // inside a list serialises as.
        out.flush();
        out.blocks.add(
          PasteList(ordered: false, items: [_readItem(element, inner)]),
        );
        return;
      case 'blockquote':
        out.flush();
        final blocks = _blocksOf(element, inner);
        if (blocks.isNotEmpty) out.blocks.add(PasteQuote(blocks));
        return;
      case 'pre':
        out.flush();
        final code = _readPre(element);
        if (code != null) out.blocks.add(code);
        return;
      case 'code' || 'kbd' || 'samp' || 'tt':
        final text = _codeText(element);
        if (text.contains('\n') && text.trim().isNotEmpty) {
          out.flush();
          out.blocks.add(
            PasteCode(_trimCode(text), language: _languageOf(element)),
          );
        } else if (text.isNotEmpty) {
          out.line.add(
            PasteCodeSpan(text, styles: inner.styles, href: inner.href),
          );
        }
        return;
      case 'table':
        out.flush();
        _readTable(element, inner, out);
        return;
      case 'hr':
        out.flush();
        out.blocks.add(const PasteRule());
        return;
      case 'br':
        out.line.addBreak(inner);
        return;
      case 'img':
        _readImage(element, inner, out);
        return;
      case 'input':
        final type = element.attributes['type']?.toLowerCase();
        if (type == 'checkbox') {
          final checked = element.attributes.containsKey('checked');
          out.line.addText(checked ? '☑ ' : '☐ ', inner);
        }
        return;
      case 'rt':
        out.line.addText('(', inner);
        _walkChildren(element, inner, out);
        out.line.addText(')', inner);
        return;
      case 'dt' || 'summary':
        out.flush();
        _walkChildren(element, inner.withStyle(PasteStyle.bold), out);
        out.flush();
        return;
    }

    if (_isBlock(tag, declarations)) {
      out.flush();
      _walkChildren(element, inner, out);
      out.flush();
      return;
    }
    _walkChildren(element, inner, out);
  }

  List<PasteBlock> _blocksOf(dom.Element element, _Context context) {
    final out = _Builder();
    _walkChildren(element, context, out);
    out.flush();
    return out.blocks;
  }

  /// A heading's or a cell's words: its blocks flattened into one run, each
  /// block after the first on a line of its own.
  List<PasteInline> _inlinesOf(dom.Element element, _Context context) {
    final out = _Builder();
    _walkChildren(element, context, out);
    out.flush();
    return _flatten(out.blocks);
  }

  List<PasteInline> _flatten(List<PasteBlock> blocks, {String bullet = ''}) {
    final result = <PasteInline>[];
    void lineBreak() {
      if (result.isNotEmpty && result.last is! PasteBreak) {
        result.add(const PasteBreak());
      }
    }

    for (final block in blocks) {
      switch (block) {
        case PasteParagraph(:final inlines) || PasteHeading(:final inlines):
          lineBreak();
          if (bullet.isNotEmpty) result.add(PasteText(bullet));
          result.addAll(inlines);
        case PasteList(:final items, :final ordered, :final start):
          for (var i = 0; i < items.length; i++) {
            final item = items[i];
            final marker = item.checked != null
                ? (item.checked! ? '☑ ' : '☐ ')
                : ordered
                ? '${start + i}. '
                : '• ';
            lineBreak();
            result.addAll(_flatten(item.blocks, bullet: marker));
          }
        case PasteQuote(:final blocks):
          lineBreak();
          result.addAll(_flatten(blocks));
        case PasteCode(:final text):
          lineBreak();
          result.add(PasteCodeSpan(text.replaceAll('\n', ' ')));
        case PasteMathBlock(:final tex):
          lineBreak();
          result.add(PasteMath(tex));
        case PasteTable(:final rows):
          for (final row in rows) {
            lineBreak();
            for (var c = 0; c < row.length; c++) {
              if (c > 0) result.add(const PasteText(' · '));
              result.addAll(row[c]);
            }
          }
        case PasteRule():
          lineBreak();
      }
    }
    while (result.isNotEmpty && result.last is PasteBreak) {
      result.removeLast();
    }
    return result;
  }

  // ---------------------------------------------------------------------
  // Styles

  _Context _styled(
    dom.Element element,
    Map<String, String> declarations,
    _Context context,
  ) {
    final styles = {...context.styles};
    switch (element.localName) {
      case 'b' || 'strong':
        styles.add(PasteStyle.bold);
      case 'i' || 'em' || 'cite' || 'var' || 'dfn':
        styles.add(PasteStyle.italic);
      case 'u' || 'ins':
        styles.add(PasteStyle.underline);
      case 's' || 'strike' || 'del':
        styles.add(PasteStyle.strike);
      case 'sup':
        styles.add(PasteStyle.superscript);
      case 'sub':
        styles.add(PasteStyle.subscript);
    }
    final weight = declarations['font-weight'];
    if (weight != null) {
      final numeric = int.tryParse(weight);
      if (weight == 'bold' ||
          weight == 'bolder' ||
          (numeric != null && numeric >= 600)) {
        styles.add(PasteStyle.bold);
      } else if (weight == 'normal' ||
          weight == 'lighter' ||
          (numeric != null && numeric < 600)) {
        styles.remove(PasteStyle.bold);
      }
    }
    final fontStyle = declarations['font-style'];
    if (fontStyle == 'italic' || fontStyle == 'oblique') {
      styles.add(PasteStyle.italic);
    } else if (fontStyle == 'normal') {
      styles.remove(PasteStyle.italic);
    }
    final decoration =
        '${declarations['text-decoration'] ?? ''} '
        '${declarations['text-decoration-line'] ?? ''}';
    if (decoration.contains('underline')) styles.add(PasteStyle.underline);
    if (decoration.contains('line-through')) styles.add(PasteStyle.strike);
    final vertical = declarations['vertical-align'];
    if (vertical == 'super') styles.add(PasteStyle.superscript);
    if (vertical == 'sub') styles.add(PasteStyle.subscript);

    var href = context.href;
    if (element.localName == 'a') {
      href = _resolveLink(element.attributes['href']);
    }
    // A link says it is one by being a link; the underline a page draws under
    // it is not emphasis the writer chose.
    if (href != null) styles.remove(PasteStyle.underline);

    final whiteSpace = declarations['white-space'];
    var pre = context.pre;
    var preLine = context.preLine;
    if (whiteSpace != null) {
      preLine = whiteSpace == 'pre-line';
      pre =
          !preLine &&
          (whiteSpace.startsWith('pre') || whiteSpace == 'break-spaces');
    }
    return _Context(styles: styles, href: href, pre: pre, preLine: preLine);
  }

  bool _isHidden(dom.Element element, Map<String, String> declarations) {
    if (element.attributes.containsKey('hidden')) return true;
    if (element.attributes['aria-hidden'] == 'true') return true;
    if (declarations['display'] == 'none') return true;
    if (declarations['visibility'] == 'hidden') return true;
    for (final name in element.classes) {
      if (_screenReaderOnly.contains(name)) return true;
    }
    return false;
  }

  static bool _isBlock(String tag, Map<String, String> declarations) {
    final display = declarations['display'];
    if (display != null) {
      if (display.startsWith('inline')) return false;
      if (display == 'block' ||
          display == 'flex' ||
          display == 'grid' ||
          display == 'list-item' ||
          display.startsWith('table') ||
          display == 'flow-root') {
        return true;
      }
    }
    return _blockTags.contains(tag);
  }

  // ---------------------------------------------------------------------
  // Lists

  PasteList _readList(dom.Element list, _Context context) {
    final ordered = list.localName == 'ol';
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = <PasteListItem>[];
    final levels = <int?>[];
    for (final child in list.nodes) {
      if (child is dom.Text) {
        if (child.data.trim().isEmpty) continue;
        items.add(
          PasteListItem([
            PasteParagraph([PasteText(child.data.trim())]),
          ]),
        );
        levels.add(null);
        continue;
      }
      if (child is! dom.Element) continue;
      final declarations = _css.declarationsFor(child);
      if (_isHidden(child, declarations)) continue;
      final tag = child.localName;
      if (tag == 'ul' || tag == 'ol') {
        // A list straight inside a list — Google Docs and hand-written HTML
        // both do it — belongs to the item before it.
        final nested = _readList(child, _styled(child, declarations, context));
        if (nested.items.isEmpty) continue;
        if (items.isEmpty) {
          items.add(PasteListItem([nested]));
          levels.add(null);
        } else {
          final last = items.removeLast();
          items.add(
            PasteListItem([...last.blocks, nested], checked: last.checked),
          );
        }
        continue;
      }
      items.add(_readItem(child, _styled(child, declarations, context)));
      levels.add(int.tryParse(child.attributes['aria-level'] ?? ''));
    }
    final nestedByLevel = _nestByLevel(items, levels, ordered);
    return PasteList(
      ordered: ordered,
      start: start,
      items: nestedByLevel ?? items,
    );
  }

  /// Google Docs writes one flat list and says each item's depth in
  /// `aria-level`. Rebuilds the nesting it means, or returns null when the
  /// levels say nothing.
  List<PasteListItem>? _nestByLevel(
    List<PasteListItem> items,
    List<int?> levels,
    bool ordered,
  ) {
    final known = levels.whereType<int>().toSet();
    if (known.length < 2 || levels.contains(null)) return null;
    final base = known.reduce((a, b) => a < b ? a : b);
    List<PasteListItem> build(int from, int to, int level) {
      final result = <PasteListItem>[];
      var i = from;
      while (i < to) {
        final item = items[i];
        var j = i + 1;
        while (j < to && levels[j]! > level) {
          j++;
        }
        if (j > i + 1) {
          final children = build(i + 1, j, levels[i + 1]!);
          result.add(
            PasteListItem([
              ...item.blocks,
              PasteList(ordered: ordered, items: children),
            ], checked: item.checked),
          );
        } else {
          result.add(item);
        }
        i = j;
      }
      return result;
    }

    return build(0, items.length, base);
  }

  PasteListItem _readItem(dom.Element item, _Context context) {
    bool? checked;
    final role = item.attributes['role'];
    if (role == 'checkbox') {
      checked = item.attributes['aria-checked'] == 'true';
    }
    final box = item.querySelector(
      'input[type=checkbox], input[type="checkbox"]',
    );
    if (box != null && _belongsToItem(box, item)) {
      checked = box.attributes.containsKey('checked');
      box.remove();
    }
    final notionBox = item.querySelector('.checkbox');
    if (checked == null && notionBox != null) {
      checked = notionBox.classes.contains('checkbox-on');
      notionBox.remove();
    }
    var blocks = _blocksOf(item, context);
    if (checked == null && blocks.isNotEmpty) {
      final (marker, rest) = _leadingTaskMarker(blocks.first);
      if (marker != null) {
        checked = marker;
        blocks = [?rest, ...blocks.skip(1)];
      }
    }
    return PasteListItem(blocks, checked: checked);
  }

  /// Whether a checkbox is this item's own rather than one in a list nested
  /// inside it.
  static bool _belongsToItem(dom.Element box, dom.Element item) {
    for (var parent = box.parent; parent != null; parent = parent.parent) {
      if (identical(parent, item)) return true;
      if (parent.localName == 'li') return false;
    }
    return false;
  }

  /// An item whose words open with a box drawn as a character — `☐`, `☑`,
  /// `[ ]`, `[x]` — which is how many apps export a checklist.
  static (bool?, PasteBlock?) _leadingTaskMarker(PasteBlock block) {
    if (block is! PasteParagraph || block.inlines.isEmpty) return (null, block);
    final first = block.inlines.first;
    if (first is! PasteText) return (null, block);
    final match = RegExp(
      r'^\s*(☐|☑|☒|✅|\[ \]|\[[xX]\])\s+',
    ).firstMatch(first.text);
    if (match == null) return (null, block);
    final marker = match.group(1)!;
    final checked = marker != '☐' && marker != '[ ]';
    final remaining = first.text.substring(match.end);
    return (
      checked,
      PasteParagraph([
        if (remaining.isNotEmpty)
          PasteText(remaining, styles: first.styles, href: first.href),
        ...block.inlines.skip(1),
      ]),
    );
  }

  // ---------------------------------------------------------------------
  // Code

  PasteCode? _readPre(dom.Element pre) {
    final codes = pre.querySelectorAll('code');
    final code = codes.length == 1 ? codes.single : null;
    final text = _codeText(code ?? pre);
    if (text.trim().isEmpty) return null;
    return PasteCode(
      _trimCode(text),
      language:
          (code == null ? null : _languageOf(code)) ??
          _languageOf(pre) ??
          _languageOfAncestors(pre) ??
          _toolbarLanguage(pre, code),
    );
  }

  /// The text of a code element as it reads: line breaks kept, toolbars and
  /// line numbers left out.
  String _codeText(dom.Element element) {
    final buffer = StringBuffer();
    void visit(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.data);
        return;
      }
      if (node is! dom.Element) return;
      final tag = node.localName;
      if (tag == 'br') {
        buffer.write('\n');
        return;
      }
      if (_dropped.contains(tag) || _droppedClass(node)) return;
      if (_isHidden(node, _css.declarationsFor(node))) return;
      if (_lineNumberClass(node)) return;
      final block =
          _isBlock(tag ?? '', _css.declarationsFor(node)) && tag != 'code';
      if (block && buffer.isNotEmpty && !_endsWithNewline(buffer)) {
        buffer.write('\n');
      }
      for (final child in node.nodes) {
        visit(child);
      }
      if (block && !_endsWithNewline(buffer)) buffer.write('\n');
    }

    for (final child in element.nodes) {
      visit(child);
    }
    return buffer.toString().replaceAll('\r\n', '\n').replaceAll('\u00a0', ' ');
  }

  static bool _endsWithNewline(StringBuffer buffer) =>
      buffer.isNotEmpty && buffer.toString().endsWith('\n');

  static String _trimCode(String text) {
    var result = text;
    while (result.startsWith('\n')) {
      result = result.substring(1);
    }
    return result.trimRight();
  }

  static final _languageClass = RegExp(
    r'(?:^|\s)(?:language|lang|highlight-source|brush:?)-?([A-Za-z0-9_+#.-]+)',
  );

  String? _languageOf(dom.Element element) {
    final declared =
        element.attributes['data-language'] ??
        element.attributes['data-lang'] ??
        element.attributes['lang'];
    if (declared != null && _plausibleLanguage(declared)) {
      return declared.toLowerCase();
    }
    final match = _languageClass.firstMatch(element.className);
    final language = match?.group(1);
    if (language == null) return null;
    return _normalizedLanguage(language);
  }

  String? _languageOfAncestors(dom.Element element) {
    var parent = element.parent;
    for (var depth = 0; parent != null && depth < 3; depth++) {
      final language = _languageOf(parent);
      if (language != null) return language;
      parent = parent.parent;
    }
    return null;
  }

  /// The label above a code block in ChatGPT, Claude and Gemini: a short
  /// word on its own in the block's header, outside the code itself.
  String? _toolbarLanguage(dom.Element pre, dom.Element? code) {
    final container = code == null ? pre : _blockContainerOf(pre);
    for (final candidate in container.querySelectorAll('div, span')) {
      if (code != null && _contains(candidate, code)) continue;
      if (code != null && _contains(code, candidate)) continue;
      if (candidate.children.isNotEmpty) continue;
      final text = candidate.text.trim();
      if (_plausibleLanguage(text)) return _normalizedLanguage(text);
    }
    return null;
  }

  static dom.Element _blockContainerOf(dom.Element pre) {
    final parent = pre.parent;
    if (parent != null && parent.localName != 'body') {
      final label = parent.querySelectorAll('pre');
      if (label.length == 1) return parent;
    }
    return pre;
  }

  static bool _contains(dom.Element outer, dom.Element inner) {
    for (dom.Node? node = inner; node != null; node = node.parent) {
      if (identical(node, outer)) return true;
    }
    return false;
  }

  static bool _plausibleLanguage(String text) =>
      text.isNotEmpty &&
      text.length <= 24 &&
      RegExp(r'^[A-Za-z][A-Za-z0-9_+#.\- ]*$').hasMatch(text) &&
      !_notLanguages.contains(text.toLowerCase());

  static String _normalizedLanguage(String raw) {
    final lower = raw.trim().toLowerCase();
    return switch (lower) {
      'c++' => 'cpp',
      'c#' => 'csharp',
      'f#' => 'fsharp',
      'objective-c' => 'objectivec',
      'shell' || 'bash' || 'sh' || 'zsh' || 'console' => lower,
      _ => lower.replaceAll(' ', '-'),
    };
  }

  static bool _lineNumberClass(dom.Element element) {
    for (final name in element.classes) {
      if (name == 'linenumber' ||
          name == 'line-number' ||
          name == 'lineno' ||
          name == 'gutter' ||
          name == 'react-syntax-highlighter-line-number') {
        return true;
      }
    }
    return false;
  }

  /// Code a source splits into one `pre` per line — Notion, some
  /// highlighters — read back as one block.
  static List<PasteBlock> _mergeAdjacentCode(List<PasteBlock> blocks) {
    final merged = <PasteBlock>[];
    var lines = false;
    for (final block in blocks) {
      final line =
          block is PasteCode &&
          block.language == null &&
          !block.text.contains('\n');
      final last = merged.isEmpty ? null : merged.last;
      if (line && lines && last is PasteCode) {
        merged[merged.length - 1] = PasteCode('${last.text}\n${block.text}');
        continue;
      }
      merged.add(block);
      lines = line;
    }
    return merged;
  }

  /// GitHub draws a checklist as one list item holding every task. Each task
  /// becomes an item of its own here, so each keeps its own box.
  static void _splitTaskItems(dom.Element root) {
    for (final item in root.querySelectorAll('li')) {
      final parent = item.parent;
      if (parent == null) continue;
      final boxes = [
        for (final box in item.querySelectorAll('input[type="checkbox"]'))
          if (identical(_closestItem(box), item)) box,
      ];
      if (boxes.length < 2) continue;
      final tasks = <dom.Element>[];
      for (final box in boxes) {
        var task = box;
        while (task.parent != null &&
            !identical(task.parent, item) &&
            task.parent!.querySelectorAll('input[type="checkbox"]').length ==
                1) {
          task = task.parent!;
        }
        tasks.add(task);
      }
      var after = _nextElementSibling(item);
      for (final task in tasks.reversed) {
        final split = dom.Element.tag('li')..append(task);
        parent.insertBefore(split, after);
        after = split;
      }
      if (item.text.trim().isEmpty) item.remove();
    }
  }

  static dom.Element? _closestItem(dom.Element element) {
    for (var at = element.parent; at != null; at = at.parent) {
      if (at.localName == 'li') return at;
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Tables

  void _readTable(dom.Element table, _Context context, _Builder out) {
    final rows = _ownRows(table);
    if (_isLayoutTable(table, rows)) {
      for (final row in rows) {
        for (final cell in row.children) {
          if (cell.localName != 'td' && cell.localName != 'th') continue;
          out.flush();
          _walkChildren(cell, context, out);
          out.flush();
        }
      }
      return;
    }

    final grid = <List<List<PasteInline>>>[];
    final aligns = <PasteAlign>[];
    final pending = <int, ({int rows, List<PasteInline> value})>{};
    for (var r = 0; r < rows.length; r++) {
      final cells = <List<PasteInline>>[];
      var column = 0;
      void fillSpans() {
        while (pending.containsKey(column)) {
          final span = pending[column]!;
          cells.add(const []);
          if (span.rows <= 1) {
            pending.remove(column);
          } else {
            pending[column] = (rows: span.rows - 1, value: span.value);
          }
          column++;
        }
      }

      for (final cell in rows[r].children) {
        if (cell.localName != 'td' && cell.localName != 'th') continue;
        final declarations = _css.declarationsFor(cell);
        if (_isHidden(cell, declarations)) continue;
        fillSpans();
        final read = _inlinesOf(cell, _styled(cell, declarations, context));
        final inlines = r == 0 ? _withoutBold(read) : read;
        final colspan = (int.tryParse(cell.attributes['colspan'] ?? '') ?? 1)
            .clamp(1, 64);
        final rowspan = (int.tryParse(cell.attributes['rowspan'] ?? '') ?? 1)
            .clamp(1, 512);
        while (aligns.length <= column + colspan - 1) {
          aligns.add(PasteAlign.none);
        }
        if (r == 0 || aligns[column] == PasteAlign.none) {
          final align = _alignOf(cell, declarations);
          if (align != PasteAlign.none) aligns[column] = align;
        }
        for (var c = 0; c < colspan; c++) {
          cells.add(c == 0 ? inlines : const []);
          if (rowspan > 1) {
            pending[column] = (rows: rowspan - 1, value: inlines);
          }
          column++;
        }
      }
      fillSpans();
      grid.add(cells);
    }
    while (grid.isNotEmpty && grid.last.every((cell) => !_hasWords(cell))) {
      grid.removeLast();
    }
    if (grid.isEmpty) return;
    final width = grid.fold<int>(
      0,
      (most, row) => row.length > most ? row.length : most,
    );
    if (width == 0) return;
    for (final row in grid) {
      while (row.length < width) {
        row.add(const []);
      }
    }
    while (aligns.length < width) {
      aligns.add(PasteAlign.none);
    }
    final caption = table.querySelector('caption');
    if (caption != null) {
      final words = _inlinesOf(caption, context.withStyle(PasteStyle.bold));
      if (_hasWords(words)) out.blocks.add(PasteParagraph(words));
    }
    out.blocks.add(PasteTable(grid, aligns.sublist(0, width)));
  }

  /// Rows that belong to this table, not to one nested in it.
  static List<dom.Element> _ownRows(dom.Element table) {
    final rows = <dom.Element>[];
    void collect(dom.Element parent) {
      for (final child in parent.children) {
        switch (child.localName) {
          case 'tr':
            rows.add(child);
          case 'thead' || 'tbody' || 'tfoot':
            collect(child);
        }
      }
    }

    collect(table);
    return rows;
  }

  /// A table used to lay a page out — an email's columns, a site's sidebar —
  /// rather than to hold data. Its cells are read as the blocks they hold.
  bool _isLayoutTable(dom.Element table, List<dom.Element> rows) {
    final role = table.attributes['role'];
    if (role == 'presentation' || role == 'none') return true;
    if (rows.isEmpty) return true;
    if (table.querySelector('table') != null) return true;
    var widest = 0;
    for (final row in rows) {
      final count = row.children
          .where((cell) => cell.localName == 'td' || cell.localName == 'th')
          .length;
      if (count > widest) widest = count;
    }
    if (widest <= 1) return true;
    // A cell holding headings or several paragraphs of prose is a column of
    // a page, not a value.
    for (final cell in table.querySelectorAll('td')) {
      if (cell.querySelector('h1, h2, h3, h4, blockquote, pre') != null) {
        return true;
      }
    }
    return false;
  }

  /// A header cell's words without the bold a header is drawn in anyway.
  static List<PasteInline> _withoutBold(List<PasteInline> inlines) => [
    for (final inline in inlines)
      switch (inline) {
        PasteText(:final text, :final styles, :final href)
            when styles.contains(PasteStyle.bold) =>
          PasteText(
            text,
            styles: {...styles}..remove(PasteStyle.bold),
            href: href,
          ),
        PasteCodeSpan(:final code, :final styles, :final href)
            when styles.contains(PasteStyle.bold) =>
          PasteCodeSpan(
            code,
            styles: {...styles}..remove(PasteStyle.bold),
            href: href,
          ),
        _ => inline,
      },
  ];

  static PasteAlign _alignOf(
    dom.Element cell,
    Map<String, String> declarations,
  ) {
    final value = (declarations['text-align'] ?? cell.attributes['align'] ?? '')
        .toLowerCase();
    return switch (value) {
      'center' => PasteAlign.center,
      'right' || 'end' => PasteAlign.right,
      _ => PasteAlign.none,
    };
  }

  // ---------------------------------------------------------------------
  // Images

  void _readImage(dom.Element image, _Context context, _Builder out) {
    final alt = (image.attributes['alt'] ?? '').trim();
    if (_isEmojiImage(image, alt)) {
      out.line.addText(_emojiOf(image, alt), context);
      return;
    }
    final declarations = _css.declarationsFor(image);
    final width =
        _pixels(image.attributes['width']) ?? _pixels(declarations['width']);
    final height =
        _pixels(image.attributes['height']) ?? _pixels(declarations['height']);
    // Tracking pixels, spacers, favicons and the little icons beside a
    // citation: furniture, not content.
    if ((width != null && width <= 24) || (height != null && height <= 24)) {
      return;
    }
    final source = _imageSource(image);
    if (source == null) {
      if (alt.isNotEmpty) out.line.addText(alt, context);
      return;
    }
    if (source.contains('favicon')) return;
    if (_isVector(source)) {
      if (alt.isNotEmpty) out.line.addText(alt, context);
      return;
    }
    PasteImage picture;
    if (source.startsWith('data:')) {
      final decoded = _decodeDataUri(source);
      if (decoded == null) {
        if (alt.isNotEmpty) out.line.addText(alt, context);
        return;
      }
      picture = PasteImage(
        bytes: decoded.bytes,
        mime: decoded.mime,
        alt: alt,
        width: width,
        height: height,
      );
    } else {
      final resolved = _resolve(source);
      final carried =
          resources[source] ?? (resolved == null ? null : resources[resolved]);
      if (carried != null) {
        picture = PasteImage(
          src: resolved,
          bytes: carried.bytes,
          mime: carried.mime,
          alt: alt,
          width: width,
          height: height,
        );
      } else if (resolved != null) {
        picture = PasteImage(
          src: resolved,
          alt: alt,
          width: width,
          height: height,
        );
      } else {
        if (alt.isNotEmpty) out.line.addText(alt, context);
        return;
      }
    }
    out.line.add(PasteImageInline(picture, href: context.href));
  }

  /// Whether a picture is drawn in SVG, which a note can't hold: badges,
  /// logos. Read from its file name or data type, or for GitHub's image
  /// proxy from the address it hides in hex.
  static bool _isVector(String source) {
    if (source.toLowerCase().startsWith('data:image/svg')) return true;
    var address = Uri.tryParse(source);
    if (address == null) return false;
    if (address.host == 'camo.githubusercontent.com') {
      final hex = address.pathSegments.lastOrNull ?? '';
      if (RegExp(r'^(?:[0-9a-f]{2})+$').hasMatch(hex)) {
        final original = Uri.tryParse(
          utf8.decode([
            for (var i = 0; i < hex.length; i += 2)
              int.parse(hex.substring(i, i + 2), radix: 16),
          ], allowMalformed: true),
        );
        if (original != null) address = original;
      }
    }
    return address.path.toLowerCase().endsWith('.svg') ||
        address.host == 'img.shields.io' ||
        address.host == 'badgen.net' ||
        address.pathSegments.contains('badge');
  }

  String? _imageSource(dom.Element image) {
    final attributes = image.attributes;
    final src = attributes['src'];
    // A lazy-loaded picture keeps a 1x1 stand-in in src and the real one in
    // a data attribute until it scrolls into view.
    final lazy =
        attributes['data-src'] ??
        attributes['data-original'] ??
        attributes['data-lazy-src'];
    if (lazy != null &&
        (src == null || src.startsWith('data:image/gif') || src.isEmpty)) {
      return lazy;
    }
    if (src != null && src.isNotEmpty) return src;
    final srcset = attributes['srcset'];
    if (srcset != null && srcset.isNotEmpty) {
      return srcset.split(',').last.trim().split(RegExp(r'\s+')).first;
    }
    return null;
  }

  static bool _isEmojiImage(dom.Element image, String alt) {
    final classes = image.className.toLowerCase();
    if (classes.contains('emoji') ||
        image.attributes.containsKey('data-stringify-emoji')) {
      return alt.isNotEmpty;
    }
    // A picture whose alt text is a single emoji, or a :shortcode:, is an
    // emoji drawn as a picture.
    if (RegExp(r'^:[a-z0-9_+\-]+:$').hasMatch(alt)) return true;
    return alt.isNotEmpty &&
        alt.runes.length <= 2 &&
        alt.runes.every((rune) => rune >= 0x2190);
  }

  /// The emoji a picture of one stands for: the code points its file is
  /// named after, as Slack, GitHub and Twemoji name them, or else its alt
  /// text, which for a custom emoji is its :shortcode:.
  static String _emojiOf(dom.Element image, String alt) {
    final file = Uri.tryParse(
      image.attributes['src'] ?? '',
    )?.pathSegments.lastOrNull;
    final match = _codePointFile.firstMatch(file ?? '');
    if (match == null) return alt;
    final points = [
      for (final part in match.group(1)!.split('-')) int.parse(part, radix: 16),
    ];
    final emoji = points.any((point) => point >= 0x2000 && point <= 0x10FFFF);
    return emoji ? String.fromCharCodes(points) : alt;
  }

  static final _codePointFile = RegExp(
    r'^([0-9a-f]{2,6}(?:-[0-9a-f]{2,6})*)(?:@\dx)?\.(?:png|svg|gif|webp)$',
    caseSensitive: false,
  );

  static ({Uint8List bytes, String mime})? _decodeDataUri(String uri) {
    final comma = uri.indexOf(',');
    if (comma < 0) return null;
    final header = uri.substring(5, comma);
    final mime = header.split(';').first.toLowerCase();
    if (!mime.startsWith('image/')) return null;
    try {
      final payload = uri.substring(comma + 1);
      final bytes = header.contains(';base64')
          ? base64.decode(payload.replaceAll(RegExp(r'\s'), ''))
          : Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
      if (bytes.isEmpty) return null;
      return (bytes: bytes, mime: mime);
    } on FormatException {
      return null;
    }
  }

  static double? _pixels(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^\s*([0-9.]+)\s*(px)?\s*$').firstMatch(value);
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  // ---------------------------------------------------------------------
  // Links

  String? _resolveLink(String? raw) {
    if (raw == null) return null;
    final href = raw.trim();
    if (href.isEmpty || href.startsWith('#')) return null;
    final lower = href.toLowerCase();
    if (lower.startsWith('javascript:') ||
        lower.startsWith('data:') ||
        lower.startsWith('vbscript:')) {
      return null;
    }
    final resolved = _resolve(href);
    if (resolved == null) return null;
    final uri = Uri.tryParse(resolved);
    // Google wraps every link in a document in a redirect through itself.
    if (uri != null &&
        (uri.host == 'www.google.com' || uri.host == 'google.com') &&
        uri.path == '/url') {
      final target = uri.queryParameters['q'] ?? uri.queryParameters['url'];
      if (target != null && target.startsWith('http')) return target;
    }
    return resolved;
  }

  /// An absolute address for [raw], or null when it is relative and there is
  /// nothing to resolve it against.
  String? _resolve(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    if (uri.hasScheme) {
      const allowed = {'http', 'https', 'mailto', 'tel', 'file', 'ftp'};
      return allowed.contains(uri.scheme.toLowerCase()) ? uri.toString() : null;
    }
    final base = baseUrl;
    if (base == null) return null;
    return base.resolveUri(uri).toString();
  }

  // ---------------------------------------------------------------------
  // Math

  static bool _isMath(dom.Element element) {
    final tag = element.localName;
    if (tag == 'math' || tag == 'mjx-container') return true;
    if (tag == 'script') {
      final type = element.attributes['type'] ?? '';
      return type.startsWith('math/tex');
    }
    final classes = element.classes;
    return classes.contains('katex') ||
        classes.contains('katex-display') ||
        classes.contains('mwe-math-element') ||
        classes.contains('MathJax_Display') ||
        (classes.contains('math-display') ||
                classes.contains('math-block') ||
                classes.contains('math-inline')) &&
            (element.attributes.containsKey('data-latex') ||
                element.attributes.containsKey('data-math'));
  }

  ({String tex, bool display})? _readMath(dom.Element element) {
    final tag = element.localName;
    final classes = element.classes;
    if (tag == 'script') {
      final tex = element.text.trim();
      if (tex.isEmpty) return null;
      return (
        tex: tex,
        display: (element.attributes['type'] ?? '').contains('display'),
      );
    }
    final latex =
        element.attributes['data-latex'] ?? element.attributes['data-math'];
    if (latex != null && latex.trim().isNotEmpty) {
      return (
        tex: latex.trim(),
        display:
            classes.contains('math-display') || classes.contains('math-block'),
      );
    }
    final annotation = element.querySelector(
      'annotation[encoding="application/x-tex"], annotation[encoding="TeX"]',
    );
    final display =
        classes.contains('katex-display') ||
        element.querySelector('.katex-display') != null ||
        element.attributes['display'] == 'true' ||
        element.attributes['display'] == 'block' ||
        element.querySelector('math[display="block"]') != null ||
        element.querySelector('.mwe-math-fallback-image-display') != null ||
        classes.contains('MathJax_Display');
    if (annotation != null && annotation.text.trim().isNotEmpty) {
      return (tex: _cleanTex(annotation.text), display: display);
    }
    final math = tag == 'math' ? element : element.querySelector('math');
    final alttext = math?.attributes['alttext'];
    if (alttext != null && alttext.trim().isNotEmpty) {
      return (tex: _cleanTex(alttext), display: display);
    }
    final source = _parsoidTex(math);
    if (source != null) return (tex: _cleanTex(source), display: display);
    final fallback = element.querySelector('img[alt]');
    final alt = fallback?.attributes['alt'];
    if (alt != null && alt.trim().isNotEmpty) {
      return (tex: _cleanTex(alt), display: display);
    }
    if (math != null) {
      final tex = mathmlToTex(math);
      if (tex.isNotEmpty) return (tex: tex, display: display);
    }
    // Drawn math with no TeX and no MathML: its text is the nearest honest
    // thing.
    final text = element.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return null;
    return (tex: text, display: display);
  }

  static String _cleanTex(String raw) {
    var tex = raw.trim();
    final wrapper = RegExp(
      r'^\{\\(?:displaystyle|textstyle)\s*(.*)\}$',
      dotAll: true,
    ).firstMatch(tex);
    if (wrapper != null) tex = wrapper.group(1)!.trim();
    return tex.replaceFirst(
      RegExp(r'^\\(?:displaystyle|textstyle)(?![A-Za-z])\s*'),
      '',
    );
  }

  /// The TeX Wikipedia's Parsoid keeps in a formula's data-mw.
  static String? _parsoidTex(dom.Element? math) {
    final raw = math?.attributes['data-mw'];
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      final body = decoded is Map ? decoded['body'] : null;
      final source = body is Map ? body['extsrc'] : null;
      return source is String && source.trim().isNotEmpty ? source : null;
    } on FormatException {
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Word

  /// Word writes a list as paragraphs, each saying in its style which list
  /// and level it is on and carrying its bullet as text. Turns runs of them
  /// into real lists before the walk, so the rest of the reader never has to
  /// know.
  void _rewriteWordLists(dom.Element root) {
    final paragraphs = root
        .querySelectorAll('p, h1, h2, h3, h4, h5, h6, div')
        .where((p) => _msoListLevel(p) != null)
        .toList();
    if (paragraphs.isEmpty) return;
    var index = 0;
    while (index < paragraphs.length) {
      final first = paragraphs[index];
      final run = <dom.Element>[first];
      var next = index + 1;
      while (next < paragraphs.length &&
          identical(_nextElementSibling(run.last), paragraphs[next]) &&
          !(_msoListLevel(paragraphs[next]) == 1 &&
              _msoListId(paragraphs[next]) != _msoListId(first))) {
        run.add(paragraphs[next]);
        next++;
      }
      _replaceWithList(run);
      index = next;
    }
  }

  static dom.Element? _nextElementSibling(dom.Element element) {
    final parent = element.parent;
    if (parent == null) return null;
    final siblings = parent.children;
    final at = siblings.indexOf(element);
    return at >= 0 && at + 1 < siblings.length ? siblings[at + 1] : null;
  }

  /// Which of the document's lists a paragraph belongs to, so that a
  /// numbered list right after a bulleted one stays a list of its own.
  static String? _msoListId(dom.Element element) => RegExp(
    r'mso-list:\s*(l\d+)\s+level',
  ).firstMatch(element.attributes['style'] ?? '')?.group(1);

  static int? _msoListLevel(dom.Element element) {
    final style = element.attributes['style'] ?? '';
    final match = RegExp(r'mso-list:\s*l\d+\s+level(\d+)').firstMatch(style);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  void _replaceWithList(List<dom.Element> paragraphs) {
    final parent = paragraphs.first.parent;
    if (parent == null) return;
    // (list element, level) from the outermost in.
    final stack = <(dom.Element, int)>[];
    dom.Element? outermost;
    for (final paragraph in paragraphs) {
      final level = _msoListLevel(paragraph) ?? 1;
      final marker = _takeWordMarker(paragraph);
      final ordered =
          marker != null && RegExp(r'^[0-9A-Za-z]{1,4}[.)]$').hasMatch(marker);
      while (stack.isNotEmpty && stack.last.$2 > level) {
        stack.removeLast();
      }
      if (stack.isEmpty || stack.last.$2 < level) {
        final list = dom.Element.tag(ordered ? 'ol' : 'ul');
        if (ordered) {
          final number = int.tryParse(marker.substring(0, marker.length - 1));
          if (number != null && number != 1) {
            list.attributes['start'] = '$number';
          }
        }
        if (stack.isEmpty) {
          outermost = list;
        } else {
          final parentList = stack.last.$1;
          final lastItem = parentList.children.isEmpty
              ? null
              : parentList.children.last;
          (lastItem ?? parentList).append(list);
        }
        stack.add((list, level));
      }
      final item = dom.Element.tag('li');
      for (final node in [...paragraph.nodes]) {
        item.append(node);
      }
      stack.last.$1.append(item);
    }
    parent.insertBefore(outermost!, paragraphs.first);
    for (final paragraph in paragraphs) {
      paragraph.remove();
    }
  }

  /// Removes the bullet or number Word wrote as text in front of an item, and
  /// returns it.
  static String? _takeWordMarker(dom.Element paragraph) {
    for (final span in paragraph.querySelectorAll('span')) {
      final style = span.attributes['style'] ?? '';
      if (style.contains('mso-list:Ignore') ||
          style.contains('mso-list: Ignore')) {
        final text = span.text.replaceAll('\u00a0', ' ').trim();
        // The span that holds the marker can sit inside one that styles it.
        var outer = span;
        while (outer.parent != null &&
            !identical(outer.parent, paragraph) &&
            outer.parent!.text.replaceAll('\u00a0', ' ').trim() == text) {
          outer = outer.parent!;
        }
        outer.remove();
        return text;
      }
    }
    return null;
  }

  /// A paragraph set well above the size of the words around it, in markup
  /// with no other way of saying it is a heading.
  int? _sizedTitleLevel(dom.Element paragraph) {
    final textSize = _textSize;
    if (textSize == null) return null;
    final size = _fontSize(paragraph);
    final words = paragraph.text.trim();
    if (size == null || words.isEmpty || words.length > 120) return null;
    final ratio = size / textSize;
    if (ratio >= 1.6) return 1;
    if (ratio >= 1.2) return 2;
    return null;
  }

  double? _commonSize(dom.Element root) {
    final bySize = <double, int>{};
    for (final element in root.querySelectorAll('p, li')) {
      final size = _fontSize(element);
      if (size == null) continue;
      bySize[size] = (bySize[size] ?? 0) + element.text.trim().length;
    }
    if (bySize.isEmpty) return null;
    return bySize.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  double? _fontSize(dom.Element element) {
    final declarations = _css.declarationsFor(element);
    final value = declarations['font-size'] ?? declarations['font'];
    final match = RegExp(r'([0-9.]+)px').firstMatch(value ?? '');
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  /// A heading's words without the bold every heading is drawn in, when
  /// all of them were bold.
  static List<PasteInline> _unboldedHeading(List<PasteInline> inlines) {
    final words = inlines.whereType<PasteText>().where(
      (text) => text.text.trim().isNotEmpty,
    );
    if (words.isEmpty ||
        !words.every((text) => text.styles.contains(PasteStyle.bold))) {
      return inlines;
    }
    return _withoutBold(inlines);
  }

  /// A Word title or subtitle paragraph, which Word does not write as a
  /// heading element.
  static int? _wordTitleLevel(dom.Element paragraph) {
    for (final name in paragraph.classes) {
      if (name == 'MsoTitle') return 1;
      if (name == 'MsoSubtitle') return 2;
      final match = RegExp(r'^MsoHeading([1-6])$').firstMatch(name);
      if (match != null) return int.parse(match.group(1)!);
    }
    return null;
  }

  /// `<![if !supportLists]>` and its kind are not comments to an HTML5
  /// parser, which keeps the text between them; that text is the marker the
  /// list rewrite reads, so only the conditional markers themselves go.
  static String _withoutDownlevelConditionals(String html) =>
      html.replaceAll(RegExp(r'<!\[(?:if [^\]]*|endif)\]>'), '');

  // ---------------------------------------------------------------------

  bool _droppedClass(dom.Element element) {
    for (final name in element.classes) {
      if (_droppedClasses.contains(name)) return true;
    }
    // Wikipedia's footnote marks; the same class is a real link elsewhere.
    if (element.localName == 'sup' && element.classes.contains('reference')) {
      return true;
    }
    // ChatGPT's "Thought for 12s" above an answer.
    if (element.attributes.containsKey('data-cot-label')) return true;
    final testId = element.attributes['data-testid'] ?? '';
    if (testId.contains('copy') || testId.contains('citation-pill')) {
      return element.localName == 'button' || testId.contains('copy');
    }
    return false;
  }

  static bool _hasWords(List<PasteInline> inlines) => inlines.any(
    (inline) => switch (inline) {
      PasteText(:final text) => text.trim().isNotEmpty,
      PasteBreak() => false,
      _ => true,
    },
  );
}

const _dropped = {
  'script',
  'style',
  'noscript',
  'template',
  'iframe',
  'object',
  'embed',
  'canvas',
  'video',
  'audio',
  'button',
  'select',
  'option',
  'textarea',
  'svg',
  'head',
  'title',
  'meta',
  'link',
  'base',
  'map',
  'area',
  'track',
  'source',
  'rp',
  'wbr',
  'clipboard-copy',
  'tool-tip',
  'o:p',
  'xml',
  'v:shape',
  'v:imagedata',
};

const _droppedClasses = {
  // Wikipedia: section edit links, footnote marks, jump links.
  'mw-editsection',
  'mw-cite-backlink',
  'mw-jump-link',
  'noprint',
  // Wikipedia's picture of a formula, beside the MathML it is read from.
  'mwe-math-fallback-image-inline',
  'mwe-math-fallback-image-display',
  // GitHub: the link icon beside every heading, copy buttons.
  'anchor',
  'octicon',
  'zeroclipboard-container',
  // Copy buttons and code-block toolbars of AI chats and docs sites.
  'copy-button',
  'copy-code-button',
  'code-block-decoration',
};

const _screenReaderOnly = {
  'sr-only',
  'visually-hidden',
  'visuallyhidden',
  'screen-reader-text',
  'screenreader-only',
  'a11y-hidden',
  'assistive-text',
};

const _blockTags = {
  'address',
  'article',
  'aside',
  'blockquote',
  'body',
  'caption',
  'center',
  'dd',
  'details',
  'dialog',
  'div',
  'dl',
  'dt',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hgroup',
  'hr',
  'html',
  'legend',
  'li',
  'main',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'summary',
  'table',
  'tbody',
  'td',
  'tfoot',
  'th',
  'thead',
  'tr',
  'ul',
};

const _notLanguages = {
  'copy',
  'copy code',
  'copied',
  'copied!',
  'code',
  'edit',
  'run',
  'download',
  'wrap',
  'expand',
  'collapse',
  'preview',
};

/// What the walk carries down the tree: the emphasis in force, the link the
/// words are inside, and whether white space is kept as written.
class _Context {
  const _Context({
    this.styles = const {},
    this.href,
    this.pre = false,
    this.preLine = false,
  });

  final Set<PasteStyle> styles;
  final String? href;

  /// White space kept as written.
  final bool pre;

  /// Line breaks kept as written, while runs of spaces still collapse.
  final bool preLine;

  _Context withStyle(PasteStyle style) => _Context(
    styles: {...styles, style},
    href: href,
    pre: pre,
    preLine: preLine,
  );
}

class _Builder {
  final List<PasteBlock> blocks = [];
  final _Line line = _Line();

  void flush() {
    final inlines = line.take();
    if (inlines.isNotEmpty) blocks.add(PasteParagraph(inlines));
  }
}

/// The words of the block being read, with HTML's white space rules applied
/// as they arrive: runs of spaces and line breaks in the markup are one
/// space, and none at all at the start of a line.
class _Line {
  final List<PasteInline> _inlines = [];

  bool get _atLineStart =>
      _inlines.isEmpty ||
      _inlines.last is PasteBreak ||
      (_inlines.last is PasteText &&
          (_inlines.last as PasteText).text.endsWith(' '));

  void addText(String raw, _Context context) {
    var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    text = text.replaceAll(RegExp('[\u200b\u2060\ufeff\u00ad\ufffc]'), '');
    if (context.pre) {
      final lines = text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (i > 0) _inlines.add(const PasteBreak());
        _append(lines[i].replaceAll('\u00a0', ' '), context);
      }
      return;
    }
    if (context.preLine && text.contains('\n')) {
      final lines = text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (i > 0) addBreak(context);
        addText(lines[i], _Context(styles: context.styles, href: context.href));
      }
      return;
    }
    text = text.replaceAll(RegExp(r'[ \t\n\f]+'), ' ');
    if (text.startsWith(' ') && _atLineStart) text = text.substring(1);
    text = text.replaceAll('\u00a0', ' ');
    if (text.isEmpty) return;
    _append(text, context);
  }

  void _append(String text, _Context context) {
    if (text.isEmpty) return;
    final last = _inlines.isEmpty ? null : _inlines.last;
    if (last is PasteText &&
        last.href == context.href &&
        _sameStyles(last.styles, context.styles)) {
      _inlines[_inlines.length - 1] = PasteText(
        last.text + text,
        styles: last.styles,
        href: last.href,
      );
      return;
    }
    _inlines.add(PasteText(text, styles: context.styles, href: context.href));
  }

  void addBreak(_Context context) {
    _trimTrailingSpace();
    _inlines.add(const PasteBreak());
  }

  void add(PasteInline inline) => _inlines.add(inline);

  void _trimTrailingSpace() {
    if (_inlines.isEmpty) return;
    final last = _inlines.last;
    if (last is PasteText && last.text.endsWith(' ')) {
      final trimmed = last.text.trimRight();
      if (trimmed.isEmpty) {
        _inlines.removeLast();
      } else {
        _inlines[_inlines.length - 1] = PasteText(
          trimmed,
          styles: last.styles,
          href: last.href,
        );
      }
    }
  }

  List<PasteInline> take() {
    _trimTrailingSpace();
    while (_inlines.isNotEmpty && _inlines.last is PasteBreak) {
      _inlines.removeLast();
      _trimTrailingSpace();
    }
    while (_inlines.isNotEmpty && _inlines.first is PasteBreak) {
      _inlines.removeAt(0);
    }
    if (_inlines.isNotEmpty && _inlines.first is PasteText) {
      final first = _inlines.first as PasteText;
      final trimmed = first.text.trimLeft();
      if (trimmed.isEmpty) {
        _inlines.removeAt(0);
      } else if (trimmed.length != first.text.length) {
        _inlines[0] = PasteText(
          trimmed,
          styles: first.styles,
          href: first.href,
        );
      }
    }
    final hasContent = _inlines.any(
      (inline) =>
          inline is! PasteBreak &&
          (inline is! PasteText || inline.text.trim().isNotEmpty),
    );
    final result = hasContent
        ? List<PasteInline>.of(_inlines)
        : const <PasteInline>[];
    _inlines.clear();
    return result;
  }

  static bool _sameStyles(Set<PasteStyle> a, Set<PasteStyle> b) =>
      a.length == b.length && a.containsAll(b);
}

/// The few CSS rules clipboard HTML relies on: Apple's RTF conversion, Excel
/// and Word put bold and italic in classes defined in a style block.
class _CssSheet {
  final Map<String, Map<String, String>> _byClass = {};
  final Map<String, Map<String, String>> _byTagClass = {};
  final Map<dom.Element, Map<String, String>> _cache = {};

  static final _rule = RegExp(r'([^{}]+)\{([^}]*)\}');

  void add(String css) {
    final source = css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
    for (final match in _rule.allMatches(source)) {
      final declarations = parseDeclarations(match.group(2)!);
      if (declarations.isEmpty) continue;
      for (final raw in match.group(1)!.split(',')) {
        final selector = raw.trim();
        final simple = RegExp(
          r'^([a-zA-Z0-9]*)\.([A-Za-z0-9_-]+)$',
        ).firstMatch(selector);
        if (simple == null) continue;
        final tag = simple.group(1)!.toLowerCase();
        final name = simple.group(2)!;
        final target = tag.isEmpty
            ? _byClass.putIfAbsent(name, () => {})
            : _byTagClass.putIfAbsent('$tag.$name', () => {});
        target.addAll(declarations);
      }
    }
  }

  Map<String, String> declarationsFor(dom.Element element) {
    final cached = _cache[element];
    if (cached != null) return cached;
    final result = <String, String>{};
    if (_byClass.isNotEmpty || _byTagClass.isNotEmpty) {
      for (final name in element.classes) {
        result.addAll(_byClass[name] ?? const {});
        result.addAll(_byTagClass['${element.localName}.$name'] ?? const {});
      }
    }
    final inline = element.attributes['style'];
    if (inline != null) result.addAll(parseDeclarations(inline));
    return _cache[element] = result;
  }

  static Map<String, String> parseDeclarations(String block) {
    final result = <String, String>{};
    for (final part in block.split(';')) {
      final colon = part.indexOf(':');
      if (colon <= 0) continue;
      final name = part.substring(0, colon).trim().toLowerCase();
      var value = part.substring(colon + 1).trim().toLowerCase();
      value = value.replaceAll('!important', '').trim();
      if (name.isEmpty || value.isEmpty) continue;
      result[name] = value;
    }
    return result;
  }
}
