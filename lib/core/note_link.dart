import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A web address found in the note's plain text.
///
/// Links are derived instead of persisted. Pasting a URL therefore remains a
/// normal, lossless text edit, while the editor can still style and act on it.
@immutable
class NoteLink {
  const NoteLink({
    required this.start,
    required this.end,
    required this.text,
    required this.uri,
  });

  final int start;
  final int end;
  final String text;
  final Uri uri;

  TextRange get range => TextRange(start: start, end: end);

  @override
  bool operator ==(Object other) =>
      other is NoteLink &&
      other.start == start &&
      other.end == end &&
      other.text == text &&
      other.uri == uri;

  @override
  int get hashCode => Object.hash(start, end, text, uri);
}

// The first two alternatives are intentionally permissive after their
// unmistakable prefixes. Bare domains are stricter so calculator variables
// and ordinary dotted prose are less likely to become links by accident.
final RegExp _webLinkCandidate = RegExp(
  r'''(?:https?://[^\s<>"'\u2018\u2019\u201c\u201d]+|www\.[^\s<>"'\u2018\u2019\u201c\u201d]+|(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}(?::\d{1,5})?(?:[/?#][^\s<>"'\u2018\u2019\u201c\u201d]*)?)''',
  caseSensitive: false,
);

const _alwaysTrimFromEnd = '.,;:!?\u2026';
const _balancedClosers = <String, String>{')': '(', ']': '[', '}': '{'};
const _familiarTopLevelDomains = {
  'app',
  'ai',
  'biz',
  'blog',
  'cloud',
  'co',
  'com',
  'company',
  'dev',
  'design',
  'edu',
  'gov',
  'info',
  'int',
  'io',
  'live',
  'me',
  'mil',
  'mobi',
  'name',
  'net',
  'news',
  'online',
  'org',
  'page',
  'pro',
  'shop',
  'site',
  'software',
  'store',
  'tech',
  'test',
  'travel',
  'tv',
  'world',
  'xyz',
};

/// Finds safe, launchable HTTP(S) links without rewriting the source text.
List<NoteLink> findNoteLinks(String source) {
  if (source.isEmpty) return const [];

  final links = <NoteLink>[];
  for (final match in _webLinkCandidate.allMatches(source)) {
    if (!_hasLeadingBoundary(source, match.start)) continue;

    final end = _trimCandidateEnd(source, match.start, match.end);
    if (end <= match.start) continue;
    final text = source.substring(match.start, end);
    final lowerText = text.toLowerCase();
    final hasScheme =
        lowerText.startsWith('http://') || lowerText.startsWith('https://');
    final normalized = hasScheme ? text : 'https://$text';
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        (!hasScheme &&
            !lowerText.startsWith('www.') &&
            !_isPlausibleBareDomain(text, uri))) {
      continue;
    }

    links.add(NoteLink(start: match.start, end: end, text: text, uri: uri));
  }
  return List.unmodifiable(links);
}

bool _isPlausibleBareDomain(String text, Uri uri) {
  // A path, query, fragment, or port is strong enough evidence even for a new
  // or uncommon top-level domain. For a bare hostname, stay conservative so
  // ordinary dotted writing does not light up unexpectedly.
  if (text.contains('/') ||
      text.contains('?') ||
      text.contains('#') ||
      RegExp(r':\d').hasMatch(text)) {
    return true;
  }
  final topLevelDomain = uri.host.split('.').last.toLowerCase();
  return topLevelDomain.length == 2 ||
      _familiarTopLevelDomains.contains(topLevelDomain);
}

/// Returns the single link containing a caret or selection.
///
/// A partial selection inside a URL still identifies the whole link, which is
/// what makes Copy Link useful after a natural word-level long press.
NoteLink? noteLinkForSelection(List<NoteLink> links, TextSelection selection) {
  if (!selection.isValid) return null;
  for (final link in links) {
    if (selection.isCollapsed) {
      if (selection.start >= link.start && selection.start < link.end) {
        return link;
      }
      continue;
    }
    if (selection.start >= link.start && selection.end <= link.end) {
      return link;
    }
  }
  return null;
}

bool _hasLeadingBoundary(String source, int start) {
  if (start == 0) return true;
  final previous = source.codeUnitAt(start - 1);
  final isAsciiLetter =
      (previous >= 0x41 && previous <= 0x5a) ||
      (previous >= 0x61 && previous <= 0x7a);
  final isDigit = previous >= 0x30 && previous <= 0x39;
  return !isAsciiLetter &&
      !isDigit &&
      previous != 0x40 && // @
      previous != 0x5f && // _
      previous != 0x2d; // -
}

int _trimCandidateEnd(String source, int start, int initialEnd) {
  var end = initialEnd;
  while (end > start && _alwaysTrimFromEnd.contains(source[end - 1])) {
    end--;
  }

  var changed = true;
  while (changed && end > start) {
    changed = false;
    final closer = source[end - 1];
    final opener = _balancedClosers[closer];
    if (opener == null) continue;
    final candidate = source.substring(start, end);
    if (_occurrences(candidate, closer) > _occurrences(candidate, opener)) {
      end--;
      changed = true;
    }
  }
  return end;
}

int _occurrences(String value, String character) {
  var count = 0;
  for (var index = 0; index < value.length; index++) {
    if (value[index] == character) count++;
  }
  return count;
}
