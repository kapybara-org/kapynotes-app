import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import 'kapy_ai_parts.dart';

/// An answer, drawn from the little Markdown a model writes: paragraphs,
/// headings as bold lines, bullet and numbered lists, bold, italic, inline
/// code, fenced code and links.
///
/// An answer is untrusted text, so this is deliberately small and owns every
/// rule rather than handing the text to a general renderer: there is no HTML,
/// no image and nothing fetched, so `<img>` or `<script>` stays the literal
/// characters it was. A link is live only for http, https and mailto, opens
/// only when it is clicked, and opens outside the app; any other scheme
/// (`javascript:`, `file:`, an app's own) is left as its words.
class KapyAiMarkdown extends StatefulWidget {
  const KapyAiMarkdown(this.text, {super.key, this.launch = _openOutside});

  final String text;

  /// Opens a link the reader clicked. Replaced in tests.
  final Future<void> Function(Uri uri) launch;

  static Future<void> _openOutside(Uri uri) async {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// [url] if it may be opened: a web address with a host, or mail.
  static Uri? safeLink(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    return switch (uri.scheme.toLowerCase()) {
      'http' || 'https' when uri.host.isNotEmpty => uri,
      'mailto' when uri.path.isNotEmpty => uri,
      _ => null,
    };
  }

  /// Where [uri] really goes, to print beside its words: the host of a web
  /// address, the address of mail. Null when [label] already says it, so
  /// "example.com" is not followed by "(example.com)".
  ///
  /// The words of a link are whatever the model, or a note it was shown,
  /// chose to write, so they say nothing about the address. The host is the
  /// part a reader can check at a glance.
  static String? destination(Uri uri, String label) {
    final said = label.trim().toLowerCase();
    if (uri.scheme.toLowerCase() == 'mailto') {
      return said.replaceFirst('mailto:', '') == uri.path.toLowerCase()
          ? null
          : uri.path;
    }
    final host = uri.host.toLowerCase();
    final named = said
        .replaceFirst(RegExp(r'^https?://'), '')
        .split(RegExp(r'[/?#]'))
        .first
        .replaceFirst('www.', '');
    return named == host.replaceFirst('www.', '') ? null : host;
  }

  @override
  State<KapyAiMarkdown> createState() => _KapyAiMarkdownState();
}

class _KapyAiMarkdownState extends State<KapyAiMarkdown> {
  /// A link's tap handler lives as long as the build that made it.
  final _recognizers = <TapGestureRecognizer>[];

  static final _fence = RegExp(r'^\s*```');
  static final _item = RegExp(r'^\s*([-*+•]|\d{1,3}[.)])\s+(.*)$');
  static final _heading = RegExp(r'^\s*#{1,6}\s+(.*)$');
  static final _inline = RegExp(
    r'`([^`]+)`'
    r'|\*\*(.+?)\*\*'
    r'|__(.+?)__'
    r'|\*(?![\s*])(.+?)\*'
    r'|(?<![A-Za-z0-9])_(?![\s_])(.+?)_(?![A-Za-z0-9])'
    r'|\[([^\]]+)\]\(([^)\s]+)\)',
  );

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final palette = context.palette;
    final body = kapyText(13.5, 21, palette.textPrimary);
    final blocks = <Widget>[];
    final paragraph = <String>[];

    void flush() {
      if (paragraph.isEmpty) return;
      blocks.add(
        Text.rich(TextSpan(children: _spans(paragraph.join('\n'), body))),
      );
      paragraph.clear();
    }

    final lines = widget.text.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (_fence.hasMatch(line)) {
        flush();
        final code = <String>[];
        while (++index < lines.length && !_fence.hasMatch(lines[index])) {
          code.add(lines[index]);
        }
        blocks.add(_code(code.join('\n')));
        continue;
      }
      if (line.trim().isEmpty) {
        flush();
        continue;
      }
      if (_heading.firstMatch(line) case final heading?) {
        flush();
        blocks.add(
          Text.rich(
            TextSpan(
              children: _spans(
                heading[1]!,
                body.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        );
        continue;
      }
      if (_item.firstMatch(line) case final item?) {
        flush();
        final marker = item[1]!;
        final numbered = RegExp(r'\d').hasMatch(marker);
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: numbered ? 22 : 14,
                  child: Text(
                    numbered ? marker : '•',
                    style: body.copyWith(color: palette.textSecondary),
                  ),
                ),
                Expanded(
                  child: Text.rich(TextSpan(children: _spans(item[2]!, body))),
                ),
              ],
            ),
          ),
        );
        continue;
      }
      paragraph.add(line.trim());
    }
    flush();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final block in blocks) ...[
          if (block != blocks.first) const SizedBox(height: 10),
          block,
        ],
      ],
    );
  }

  Widget _code(String code) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.kapyHighlight,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(
          code,
          style: TextStyle(
            fontFamily: AppFonts.mono,
            fontFamilyFallback: AppFonts.monoFallback,
            fontSize: 12.5,
            height: 19 / 12.5,
            color: palette.textPrimary,
          ),
        ),
      ),
    );
  }

  /// [text]'s inline marks as spans in [style]. Bold and italic nest; code
  /// and a link's words are taken as they are.
  List<InlineSpan> _spans(String text, TextStyle style) {
    final palette = context.palette;
    final spans = <InlineSpan>[];
    var at = 0;
    for (final match in _inline.allMatches(text)) {
      if (match.start > at) {
        spans.add(
          TextSpan(text: text.substring(at, match.start), style: style),
        );
      }
      at = match.end;
      if (match[1] case final code?) {
        spans.add(
          TextSpan(
            text: code,
            style: style.copyWith(
              fontFamily: AppFonts.mono,
              fontFamilyFallback: AppFonts.monoFallback,
              fontSize: (style.fontSize ?? 13.5) - 1,
              backgroundColor: palette.kapyHighlight,
            ),
          ),
        );
      } else if (match[2] ?? match[3] case final bold?) {
        spans.addAll(_spans(bold, style.copyWith(fontWeight: FontWeight.w700)));
      } else if (match[4] ?? match[5] case final italic?) {
        spans.addAll(
          _spans(italic, style.copyWith(fontStyle: FontStyle.italic)),
        );
      } else {
        final label = match[6]!;
        final uri = KapyAiMarkdown.safeLink(match[7]!);
        if (uri == null) {
          spans.addAll(_spans(label, style));
          continue;
        }
        final recognizer = TapGestureRecognizer()
          ..onTap = () => unawaited(widget.launch(uri));
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: label,
            recognizer: recognizer,
            mouseCursor: SystemMouseCursors.click,
            style: style.copyWith(
              color: palette.accentText,
              decoration: TextDecoration.underline,
              decorationColor: palette.accentText.withValues(alpha: 0.5),
            ),
          ),
        );
        if (KapyAiMarkdown.destination(uri, label) case final where?) {
          spans.add(
            TextSpan(
              text: ' ($where)',
              style: style.copyWith(
                color: palette.textTertiary,
                fontSize: (style.fontSize ?? 13.5) - 1,
                fontWeight: FontWeight.w400,
                fontStyle: FontStyle.normal,
              ),
            ),
          );
        }
      }
    }
    if (at < text.length) {
      spans.add(TextSpan(text: text.substring(at), style: style));
    }
    return spans;
  }
}
