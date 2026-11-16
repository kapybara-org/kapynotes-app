import 'dart:isolate';

import 'clipboard_snapshot.dart';
import 'html_reader.dart';
import 'markdown_text.dart';
import 'paste_tree.dart';
import 'paste_writers.dart';

/// Which of the clipboard's representations a paste was read from.
enum PasteKind { code, html, rtf, markdown, text, nothing }

class PasteConversion {
  const PasteConversion(this.kind, this.output);

  final PasteKind kind;
  final PasteOutput output;
}

/// Reads what the clipboard holds into what goes into the note, written as
/// markdown when [markdown] is on and in the editor's plain format when not.
///
/// The richest representation that says something wins, in this order:
/// code an editor copied (it is code, whatever its colours look like), HTML
/// that carries structure, rich text, plain text written in markdown, and
/// plain text. Two exceptions keep the obvious answer: the markdown an AI's
/// copy button writes beats the HTML it renders alongside, since it says
/// the same and is what the writer had; and HTML that is only a wrapper
/// around words loses to the words.
PasteConversion convertPaste(
  ClipboardSnapshot snapshot, {
  required bool markdown,
}) {
  final write = markdown ? writeMarkdownPaste : writePlainPaste;
  final text = snapshot.text == null ? null : cleanPastedText(snapshot.text!);
  final hasText = text != null && text.trim().isNotEmpty;

  if (snapshot.vscode != null && hasText) {
    return PasteConversion(
      PasteKind.code,
      write([PasteCode(_trimCode(text), language: snapshot.vscodeMode)]),
    );
  }

  final baseUrl = Uri.tryParse(snapshot.sourceUrl ?? '');
  for (final (kind, markup) in [
    (PasteKind.html, snapshot.html),
    (PasteKind.rtf, snapshot.rtfHtml),
  ]) {
    if (markup == null || markup.trim().isEmpty) continue;
    final reader = HtmlPasteReader(
      baseUrl: baseUrl != null && baseUrl.hasScheme ? baseUrl : null,
      resources: snapshot.resources,
    );
    if (hasText && reader.readsAsCode(markup)) {
      return PasteConversion(
        PasteKind.code,
        write([PasteCode(_trimCode(text))]),
      );
    }
    final blocks = reader.read(markup);
    if (hasText && !_hasPictures(blocks) && _isMarkdownSource(text, blocks)) {
      break;
    }
    if (!hasText || _hasStructure(blocks)) {
      return PasteConversion(kind, write(blocks));
    }
  }

  if (!hasText) {
    return const PasteConversion(PasteKind.nothing, PasteOutput(text: ''));
  }
  if (looksLikeMarkdown(text)) {
    return PasteConversion(
      PasteKind.markdown,
      markdown
          ? normalizeMarkdownPaste(text)
          : writePlainPaste(readMarkdownPaste(text)),
    );
  }
  return PasteConversion(PasteKind.text, PasteOutput(text: text));
}

/// [convertPaste] away from the UI isolate when the clipboard is big enough
/// for reading it to cost a frame.
Future<PasteConversion> convertPasteInBackground(
  ClipboardSnapshot snapshot, {
  required bool markdown,
}) {
  final size =
      (snapshot.html?.length ?? 0) +
      (snapshot.rtfHtml?.length ?? 0) +
      (snapshot.text?.length ?? 0);
  if (size < _backgroundThreshold) {
    return Future.value(convertPaste(snapshot, markdown: markdown));
  }
  return Isolate.run(() => convertPaste(snapshot, markdown: markdown));
}

const _backgroundThreshold = 32 * 1024;

String _trimCode(String text) {
  var code = text;
  while (code.startsWith('\n')) {
    code = code.substring(1);
  }
  return code.trimRight();
}

bool _hasPictures(List<PasteBlock> blocks) => blocks.any(
  (block) => switch (block) {
    PasteParagraph(:final inlines) || PasteHeading(:final inlines) =>
      inlines.any((inline) => inline is PasteImageInline),
    PasteList(:final items) => items.any((item) => _hasPictures(item.blocks)),
    PasteQuote(:final blocks) => _hasPictures(blocks),
    PasteTable(:final rows) => rows.any(
      (row) =>
          row.any((cell) => cell.any((inline) => inline is PasteImageInline)),
    ),
    _ => false,
  },
);

/// Whether [text] is the markdown an AI's copy button writes beside what it
/// drew from it, rather than the drawing's own words, as a selection's text
/// is. Code and stars on the page are in both; only the source has the
/// marks markdown draws with, so it has more of them.
bool _isMarkdownSource(String text, List<PasteBlock> blocks) {
  if (!looksLikeMarkdown(text)) return false;
  return _marks(text) - _marks(writePlainPaste(blocks).text) >= 4;
}

int _marks(String text) {
  var count = 0;
  for (final unit in text.codeUnits) {
    if (unit == 0x23 || unit == 0x2A || unit == 0x60 || unit == 0x7C) count++;
  }
  return count;
}

/// Whether HTML said more than its words: anything but plain paragraphs.
bool _hasStructure(List<PasteBlock> blocks) => blocks.any(
  (block) => switch (block) {
    PasteParagraph(:final inlines) => inlines.any(
      (inline) => switch (inline) {
        PasteText(:final styles, :final href) =>
          styles.isNotEmpty || href != null,
        PasteBreak() => false,
        _ => true,
      },
    ),
    _ => true,
  },
);
