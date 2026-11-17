import 'dart:convert';

import 'paste_tree.dart';

/// Writes blocks as the HTML documents, mail and web editors paste: Google
/// Docs, Word, Gmail, Notion.
///
/// It says what [HtmlPasteReader] reads, so a note copied out and pasted back
/// in reads as the blocks it was. Where those apps differ from a browser, they
/// decide: a to-do's box is the ☐ or ☑ it looks like, which they keep where
/// they would drop a form's checkbox, and math is its TeX between dollars,
/// marked with the TeX so an editor that draws math can find it.
///
/// [embeds] stand in for characters of the words. Each key, a single
/// character, is written as the HTML it maps to wherever the words hold it:
/// the pictures of a note, which hold their place in its text as one
/// character each.
String writeHtml(
  List<PasteBlock> blocks, {
  Map<String, String> embeds = const {},
}) {
  final writer = _HtmlWriter(embeds);
  writer.blocks(blocks);
  return writer.out.toString();
}

class _HtmlWriter {
  _HtmlWriter(this.embeds);

  final Map<String, String> embeds;
  final out = StringBuffer();

  void blocks(List<PasteBlock> blocks) {
    PasteBlock? previous;
    for (final block in blocks) {
      if (block is PasteList && block.afterEmptyLine && previous is PasteList) {
        out.write('<p><br></p>');
      }
      _block(block);
      previous = block;
    }
  }

  void _block(PasteBlock block) {
    switch (block) {
      case PasteParagraph(:final inlines):
        out.write('<p>');
        _inlines(inlines);
        out.write('</p>');
      case PasteHeading(:final level, :final inlines):
        final tag = 'h${level.clamp(1, 6)}';
        out.write('<$tag>');
        _inlines(inlines);
        out.write('</$tag>');
      case PasteList():
        _list(block);
      case PasteQuote(:final blocks):
        out.write('<blockquote>');
        this.blocks(blocks);
        out.write('</blockquote>');
      case PasteCode(:final text, :final language):
        out.write('<pre><code');
        if (language != null && language.isNotEmpty) {
          out.write(' class="language-${_attribute(language)}"');
        }
        out
          ..write('>')
          ..write(_words(text, keepSpaces: false))
          ..write('</code></pre>');
      case PasteTable():
        _table(block);
      case PasteRule():
        out.write('<hr>');
      case PasteMathBlock(:final tex):
        out.write(_math(tex.trim(), display: true));
    }
  }

  void _list(PasteList list) {
    final tag = list.ordered ? 'ol' : 'ul';
    out.write(
      list.ordered && list.start != 1 ? '<ol start="${list.start}">' : '<$tag>',
    );
    for (final item in list.items) {
      final checked = item.checked;
      if (checked == null) {
        out.write('<li>');
      } else {
        out
          ..write('<li style="list-style-type:none">')
          ..write(checked ? '☑ ' : '☐ ');
      }
      var rest = item.blocks;
      if (rest.firstOrNull case PasteParagraph(:final inlines)) {
        _inlines(inlines);
        rest = rest.sublist(1);
      }
      blocks(rest);
      out.write('</li>');
    }
    out.write('</$tag>');
  }

  void _table(PasteTable table) {
    out.write(
      '<table border="1" cellpadding="4" style="border-collapse:collapse">',
    );
    for (var r = 0; r < table.rows.length; r++) {
      if (r == 0) out.write('<thead>');
      if (r == 1) out.write('<tbody>');
      out.write('<tr>');
      final cells = table.rows[r];
      for (var c = 0; c < cells.length; c++) {
        final tag = r == 0 ? 'th' : 'td';
        final align = c < table.aligns.length
            ? table.aligns[c]
            : PasteAlign.none;
        out.write(switch (align) {
          PasteAlign.none => '<$tag>',
          PasteAlign.center => '<$tag style="text-align:center">',
          PasteAlign.right => '<$tag style="text-align:right">',
        });
        _inlines(cells[c]);
        out.write('</$tag>');
      }
      out.write('</tr>');
      if (r == 0) out.write('</thead>');
    }
    if (table.rows.length > 1) out.write('</tbody>');
    out.write('</table>');
  }

  void _inlines(List<PasteInline> inlines) {
    String? link;
    for (final inline in inlines) {
      final href = switch (inline) {
        PasteText(:final href) ||
        PasteCodeSpan(:final href) ||
        PasteImageInline(:final href) => href,
        PasteMath() => link,
        PasteBreak() => null,
      };
      if (href != link) {
        if (link != null) out.write('</a>');
        if (href != null) out.write('<a href="${_attribute(href)}">');
        link = href;
      }
      switch (inline) {
        case PasteText(:final text, :final styles):
          _styled(styles, _words(text, keepSpaces: true));
        case PasteCodeSpan(:final code, :final styles):
          _styled(styles, '<code>${_words(code, keepSpaces: true)}</code>');
        case PasteMath(:final tex):
          out.write(_math(tex.trim(), display: false));
        case PasteBreak():
          out.write('<br>');
        case PasteImageInline(:final image):
          _image(image);
      }
    }
    if (link != null) out.write('</a>');
  }

  void _styled(Set<PasteStyle> styles, String html) {
    final tags = [
      for (final (style, tag) in _styleTags)
        if (styles.contains(style)) tag,
    ];
    for (final tag in tags) {
      out.write('<$tag>');
    }
    out.write(html);
    for (final tag in tags.reversed) {
      out.write('</$tag>');
    }
  }

  void _image(PasteImage image) {
    final bytes = image.bytes;
    final source = bytes != null && bytes.isNotEmpty
        ? 'data:${image.mime ?? 'image/png'};base64,${base64Encode(bytes)}'
        : image.src;
    if (source == null) {
      out.write(_words(image.alt, keepSpaces: false));
      return;
    }
    out.write(
      '<img src="${_attribute(source)}" alt="${_attribute(image.alt)}"',
    );
    final width = image.width;
    if (width != null && width > 0) out.write(' width="${width.round()}"');
    final height = image.height;
    if (height != null && height > 0) out.write(' height="${height.round()}"');
    out.write('>');
  }

  String _math(String tex, {required bool display}) {
    final latex = _attribute(tex);
    final shown = _words(tex, keepSpaces: false, embedded: false);
    return display
        ? '<div class="math math-display" data-latex="$latex">\$\$$shown\$\$</div>'
        : '<span class="math math-inline" data-latex="$latex">\$$shown\$</span>';
  }

  /// Words as HTML text, with their [embeds] in place. A run of spaces keeps
  /// its width with [keepSpaces], where HTML would close it up to one.
  String _words(String text, {required bool keepSpaces, bool embedded = true}) {
    final result = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      final embed = embeds[char];
      if (embed != null) {
        if (embedded) result.write(embed);
        continue;
      }
      result.write(switch (char) {
        '&' => '&amp;',
        '<' => '&lt;',
        '>' => '&gt;',
        ' ' when keepSpaces && i > 0 && text[i - 1] == ' ' => '&nbsp;',
        _ => char,
      });
    }
    return result.toString();
  }

  String _attribute(String value) => const HtmlEscape(
    HtmlEscapeMode.attribute,
  ).convert(value.split('').where((char) => !embeds.containsKey(char)).join());
}

const _styleTags = [
  (PasteStyle.bold, 'b'),
  (PasteStyle.italic, 'i'),
  (PasteStyle.strike, 's'),
  (PasteStyle.underline, 'u'),
  (PasteStyle.superscript, 'sup'),
  (PasteStyle.subscript, 'sub'),
];
