/// A host name as the network sees it, so a name that only looks like
/// another one cannot pass for it: "exаmple.com" with a Cyrillic "а" is
/// `xn--exmple-4nf.com`.
///
/// Each label with a character outside ASCII becomes `xn--` and its
/// Punycode (RFC 3492); the rest are lowercased and left alone. Dart's [Uri]
/// does not do this. It lowercases but does no Unicode mapping (IDNA's
/// NFKC step), which is fine here: the result is for a reader to compare, and
/// a name that maps differently only ever shows as its own `xn--` form.
String asciiHost(String host) {
  final labels = host
      .toLowerCase()
      .replaceAll(RegExp('[\u3002\uff0e\uff61]'), '.')
      .split('.');
  return [
    for (final label in labels)
      label.runes.every((rune) => rune < 128)
          ? label
          : 'xn--${punycode(label)}',
  ].join('.');
}

/// RFC 3492's encoder, for one label.
String punycode(String input) {
  const base = 36;
  const tMin = 1;
  const tMax = 26;
  final runes = input.runes.toList();
  final out = StringBuffer();
  for (final rune in runes) {
    if (rune < 128) out.writeCharCode(rune);
  }
  final basic = out.length;
  var handled = basic;
  if (basic > 0) out.write('-');

  int digit(int d) => d < 26 ? 97 + d : 22 + d;

  int adapt(int delta, int points, bool first) {
    delta = first ? delta ~/ 700 : delta ~/ 2;
    delta += delta ~/ points;
    var k = 0;
    while (delta > ((base - tMin) * tMax) ~/ 2) {
      delta ~/= base - tMin;
      k += base;
    }
    return k + (base - tMin + 1) * delta ~/ (delta + 38);
  }

  var n = 128;
  var delta = 0;
  var bias = 72;
  while (handled < runes.length) {
    final next = runes
        .where((rune) => rune >= n)
        .reduce((a, b) => a < b ? a : b);
    delta += (next - n) * (handled + 1);
    n = next;
    for (final rune in runes) {
      if (rune < n) delta++;
      if (rune != n) continue;
      var q = delta;
      for (var k = base; ; k += base) {
        final t = k <= bias
            ? tMin
            : k >= bias + tMax
            ? tMax
            : k - bias;
        if (q < t) break;
        out.writeCharCode(digit(t + (q - t) % (base - t)));
        q = (q - t) ~/ (base - t);
      }
      out.writeCharCode(digit(q));
      bias = adapt(delta, handled + 1, handled == basic);
      delta = 0;
      handled++;
    }
    delta++;
    n++;
  }
  return out.toString();
}
