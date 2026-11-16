import 'package:html/dom.dart' as dom;

/// TeX for presentation MathML, for math a page drew without keeping the
/// TeX it was written in: KaTeX once a selection has lost its annotation,
/// or MathML a page wrote by hand.
///
/// The aim is TeX that draws the same, not the TeX the author typed. A
/// symbol with no TeX name stays the character it is.
String mathmlToTex(dom.Element math) => _node(math).trim();

String _node(dom.Element element) {
  final children = element.children;
  switch (element.localName) {
    case 'annotation' || 'annotation-xml' || 'none' || 'mprescripts':
      return '';
    case 'semantics' || 'maction':
      return children.isEmpty ? '' : _node(children.first);
    case 'mi':
      return _identifier(
        element.text.trim(),
        element.attributes['mathvariant'],
      );
    case 'mn':
      return _symbols(element.text.trim());
    case 'mo':
      return _operator(element.text.trim());
    case 'mtext':
      return _text(element.text);
    case 'ms':
      return _text('"${element.text}"');
    case 'mspace':
      return _space(element.attributes['width']);
    case 'msup':
      return '${_base(children)}^${_argument(children, 1)}';
    case 'msub':
      return '${_base(children)}_${_argument(children, 1)}';
    case 'msubsup':
      return '${_base(children)}_${_argument(children, 1)}'
          '^${_argument(children, 2)}';
    case 'mfrac':
      final thickness = element.attributes['linethickness']?.trim();
      final binomial =
          thickness == '0' || thickness == '0px' || thickness == '0em';
      return '${binomial ? r'\binom' : r'\frac'}'
          '${_argument(children, 0)}${_argument(children, 1)}';
    case 'msqrt':
      return '\\sqrt{${_join(children)}}';
    case 'mroot':
      final index = children.length > 1 ? _node(children[1]) : '';
      return '\\sqrt[$index]${_argument(children, 0)}';
    case 'mover':
      return _over(children);
    case 'munder':
      return _under(children);
    case 'munderover':
      return _underOver(children);
    case 'mtable':
      final align = element.attributes['columnalign'] ?? '';
      return _table(
        element,
        align.startsWith('right left') ? 'aligned' : 'matrix',
      );
    case 'mphantom':
      return '\\phantom{${_join(children)}}';
    case 'menclose':
      final notation = element.attributes['notation'] ?? '';
      if (notation.contains('box')) return '\\boxed{${_join(children)}}';
      if (notation.contains('diagonalstrike')) {
        return '\\cancel{${_join(children)}}';
      }
      return _join(children);
    case 'mfenced':
      final open = element.attributes['open'] ?? '(';
      final close = element.attributes['close'] ?? ')';
      final separators = (element.attributes['separators'] ?? ',').trim();
      final parts = [for (final child in children) _node(child)];
      return '\\left${_fence(open)}'
          '${parts.join(separators.isEmpty ? ' ' : separators[0])}'
          '\\right${_fence(close)}';
    default:
      return _row(children);
  }
}

/// A row, with a fenced table read as the matrix it draws and any other
/// pair of stretchy fences as \left and \right.
String _row(List<dom.Element> children) {
  if (children.length < 2 ||
      !_isFence(children.first) ||
      !_isFence(children.last)) {
    return _join(children);
  }
  final open = children.first.text.trim();
  final close = children.last.text.trim();
  final inner = children.sublist(1, children.length - 1);
  if (inner.length == 1 && inner.single.localName == 'mtable') {
    final environment = switch ((open, close)) {
      ('(', ')') => 'pmatrix',
      ('[', ']') => 'bmatrix',
      ('{', '}') => 'Bmatrix',
      ('|', '|') => 'vmatrix',
      ('‖', '‖') || ('∥', '∥') => 'Vmatrix',
      ('{', '') => 'cases',
      _ => null,
    };
    if (environment != null) return _table(inner.single, environment);
  }
  return '\\left${_fence(open)}${_join(inner)}\\right${_fence(close)}';
}

bool _isFence(dom.Element element) =>
    element.localName == 'mo' && element.attributes['fence'] == 'true';

String _table(dom.Element table, String environment) {
  final rows = [
    for (final row in table.children)
      if (row.localName == 'mtr' || row.localName == 'mlabeledtr')
        [
          for (final cell in row.children)
            if (cell.localName == 'mtd') _node(cell).trim(),
        ].join(' & '),
  ];
  return '\\begin{$environment}${rows.join(r' \\ ')}\\end{$environment}';
}

/// Pieces of TeX side by side, kept apart only where a command's name would
/// otherwise run into the letter after it.
String _join(Iterable<dom.Element> elements) {
  final out = StringBuffer();
  var previous = '';
  for (final element in elements) {
    final piece = _node(element);
    if (piece.isEmpty) continue;
    if (_endsInCommand.hasMatch(previous) &&
        _startsWithLetter.hasMatch(piece)) {
      out.write(' ');
    }
    out.write(piece);
    previous = piece;
  }
  return out.toString();
}

final _endsInCommand = RegExp(r'\\[A-Za-z]+$');
final _startsWithLetter = RegExp(r'^[A-Za-z]');

String _base(List<dom.Element> children) {
  if (children.isEmpty) return '{}';
  final base = _node(children.first);
  return _isAtom(base) ? base : '{$base}';
}

String _argument(List<dom.Element> children, int index) =>
    index < children.length ? '{${_node(children[index])}}' : '{}';

bool _isAtom(String tex) => _atom.hasMatch(tex);

final _atom = RegExp(r'^(\\[A-Za-z]+|\\.|[^\\{}\s]|\{[^{}]*\})$');

String _over(List<dom.Element> children) {
  if (children.length < 2) return _join(children);
  final base = _node(children[0]);
  final mark = children[1].localName == 'mo' ? children[1].text.trim() : null;
  final single = _isAtom(base);
  final accent = switch (mark) {
    '^' || 'ˆ' || '\u0302' => single ? 'hat' : 'widehat',
    '~' || '˜' || '\u0303' => single ? 'tilde' : 'widetilde',
    '¯' ||
    '‾' ||
    'ˉ' ||
    '_' ||
    '\u0304' ||
    '\u0305' => single ? 'bar' : 'overline',
    '→' || '\u20D7' => single ? 'vec' : 'overrightarrow',
    '←' => 'overleftarrow',
    '˙' || '\u0307' => 'dot',
    '¨' || '\u0308' => 'ddot',
    'ˇ' || '\u030C' => 'check',
    '˘' || '\u0306' => 'breve',
    '⏞' || '︷' => 'overbrace',
    _ => null,
  };
  if (accent != null) return '\\$accent{$base}';
  if (_isBigOperator(base)) return '$base^{${_node(children[1])}}';
  return '\\overset{${_node(children[1])}}{$base}';
}

String _under(List<dom.Element> children) {
  if (children.length < 2) return _join(children);
  final base = _node(children[0]);
  final mark = children[1].localName == 'mo' ? children[1].text.trim() : null;
  if (mark == '_' || mark == '‾' || mark == '¯' || mark == '\u0332') {
    return '\\underline{$base}';
  }
  if (mark == '⏟' || mark == '︸') return '\\underbrace{$base}';
  if (_isBigOperator(base)) return '${base}_{${_node(children[1])}}';
  return '\\underset{${_node(children[1])}}{$base}';
}

String _underOver(List<dom.Element> children) {
  if (children.length < 3) return _under(children);
  final base = _node(children[0]);
  final under = _node(children[1]);
  final over = _node(children[2]);
  if (_isBigOperator(base)) return '${base}_{$under}^{$over}';
  return '\\overset{$over}{\\underset{$under}{$base}}';
}

bool _isBigOperator(String tex) =>
    _bigOperators.contains(tex) || tex.startsWith(r'\operatorname');

const _bigOperators = {
  r'\sum', r'\prod', r'\coprod', r'\int', r'\iint', r'\iiint', r'\oint', //
  r'\bigcup', r'\bigcap', r'\bigoplus', r'\bigotimes', r'\bigvee', //
  r'\bigwedge', r'\bigsqcup', r'\lim', r'\limsup', r'\liminf', r'\max', //
  r'\min', r'\sup', r'\inf', r'\det', r'\Pr', r'\gcd', r'\arg',
};

String _identifier(String text, String? variant) {
  if (text.isEmpty) return '';
  if (text.runes.length > 1) {
    if (_functions.contains(text)) return '\\$text';
    return _word.hasMatch(text)
        ? '\\operatorname{$text}'
        : '\\mathrm{${_symbols(text)}}';
  }
  final symbol = _symbols(text);
  final command = switch (variant) {
    'normal' when _word.hasMatch(text) => 'mathrm',
    'bold' => 'mathbf',
    'double-struck' => 'mathbb',
    'script' => 'mathcal',
    'fraktur' => 'mathfrak',
    'bold-italic' => 'boldsymbol',
    'sans-serif' => 'mathsf',
    'monospace' => 'mathtt',
    _ => null,
  };
  return command == null ? symbol : '\\$command{$symbol}';
}

final _word = RegExp(r'^[A-Za-z]+$');

String _operator(String text) {
  if (text.isEmpty) return '';
  if (_functions.contains(text)) return '\\$text';
  if (text.length > 1 && _word.hasMatch(text)) return '\\operatorname{$text}';
  return _symbols(text);
}

const _functions = {
  'sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'sinh', 'cosh', 'tanh', 'coth', //
  'arcsin', 'arccos', 'arctan', 'log', 'ln', 'lg', 'exp', 'lim', 'limsup', //
  'liminf', 'max', 'min', 'sup', 'inf', 'det', 'dim', 'ker', 'deg', 'gcd', //
  'hom', 'arg', 'Pr',
};

String _text(String text) {
  if (text.trim().isEmpty) {
    if (text.isEmpty) return '';
    return switch (text.runes.first) {
      0x2009 || 0x202F => r'\,',
      0x2005 => r'\:',
      0x2004 => r'\;',
      0x2003 => r'\quad',
      _ => r'\ ',
    };
  }
  final escaped = text
      .replaceAll('\\', r'\textbackslash{}')
      .replaceAllMapped(RegExp(r'[{}$%#&_]'), (match) => '\\${match[0]}');
  return '\\text{$escaped}';
}

String _space(String? width) {
  final em = double.tryParse(
    (width ?? '').replaceAll(RegExp(r'em$'), '').trim(),
  );
  if (em == null) return '';
  if (em >= 2) return r'\qquad';
  if (em >= 1) return r'\quad';
  if (em >= 0.27) return r'\;';
  if (em >= 0.22) return r'\:';
  if (em >= 0.16) return r'\,';
  if (em < 0) return r'\!';
  return '';
}

String _fence(String fence) => switch (fence) {
  '' => '.',
  '{' => r'\{',
  '}' => r'\}',
  '⟨' || '〈' => r'\langle',
  '⟩' || '〉' => r'\rangle',
  '‖' || '∥' => r'\Vert',
  '⌊' => r'\lfloor',
  '⌋' => r'\rfloor',
  '⌈' => r'\lceil',
  '⌉' => r'\rceil',
  _ => fence,
};

/// [text] with every character TeX has a name for written by that name.
String _symbols(String text) {
  final out = StringBuffer();
  var previous = '';
  for (final rune in text.runes) {
    final character = String.fromCharCode(rune);
    final piece = _symbolNames[character] ?? character;
    if (piece.isEmpty) continue;
    if (_endsInCommand.hasMatch(previous) &&
        _startsWithLetter.hasMatch(piece)) {
      out.write(' ');
    }
    out.write(piece);
    previous = piece;
  }
  return out.toString();
}

const _symbolNames = {
  '\u2061': '', '\u2062': '', '\u2063': '', '\u2064': '', //
  '\u2212': '-', '#': r'\#', '\$': r'\$', '%': r'\%', '&': r'\&', //
  '_': r'\_', '{': r'\{', '}': r'\}', '~': r'\sim', '\\': r'\backslash', //
  'α': r'\alpha', 'β': r'\beta', 'γ': r'\gamma', 'δ': r'\delta', //
  'ϵ': r'\epsilon', 'ε': r'\varepsilon', 'ζ': r'\zeta', 'η': r'\eta', //
  'θ': r'\theta', 'ϑ': r'\vartheta', 'ι': r'\iota', 'κ': r'\kappa', //
  'λ': r'\lambda', 'μ': r'\mu', 'ν': r'\nu', 'ξ': r'\xi', 'π': r'\pi', //
  'ϖ': r'\varpi', 'ρ': r'\rho', 'ϱ': r'\varrho', 'σ': r'\sigma', //
  'ς': r'\varsigma', 'τ': r'\tau', 'υ': r'\upsilon', 'ϕ': r'\phi', //
  'φ': r'\varphi', 'χ': r'\chi', 'ψ': r'\psi', 'ω': r'\omega', //
  'Γ': r'\Gamma', 'Δ': r'\Delta', 'Θ': r'\Theta', 'Λ': r'\Lambda', //
  'Ξ': r'\Xi', 'Π': r'\Pi', 'Σ': r'\Sigma', 'Υ': r'\Upsilon', //
  'Φ': r'\Phi', 'Ψ': r'\Psi', 'Ω': r'\Omega', //
  '∀': r'\forall', '∃': r'\exists', '∄': r'\nexists', '∂': r'\partial', //
  '∇': r'\nabla', '∞': r'\infty', '∅': r'\emptyset', '∈': r'\in', //
  '∉': r'\notin', '∋': r'\ni', '⊂': r'\subset', '⊃': r'\supset', //
  '⊆': r'\subseteq', '⊇': r'\supseteq', '⊊': r'\subsetneq', //
  '∪': r'\cup', '∩': r'\cap', '∖': r'\setminus', '∧': r'\land', //
  '∨': r'\lor', '¬': r'\neg', '⊕': r'\oplus', '⊗': r'\otimes', //
  '⊙': r'\odot', '×': r'\times', '÷': r'\div', '·': r'\cdot', //
  '⋅': r'\cdot', '∘': r'\circ', '∗': r'\ast', '±': r'\pm', '∓': r'\mp', //
  '≤': r'\le', '≥': r'\ge', '≦': r'\leqq', '≧': r'\geqq', '≪': r'\ll', //
  '≫': r'\gg', '≠': r'\ne', '≈': r'\approx', '≃': r'\simeq', //
  '≅': r'\cong', '≡': r'\equiv', '∼': r'\sim', '∝': r'\propto', //
  '⊥': r'\perp', '∥': r'\parallel', '‖': r'\Vert', '∣': r'\mid', //
  '∤': r'\nmid', '→': r'\to', '←': r'\leftarrow', '↔': r'\leftrightarrow', //
  '⇒': r'\Rightarrow', '⇐': r'\Leftarrow', '⇔': r'\Leftrightarrow', //
  '↦': r'\mapsto', '⟶': r'\longrightarrow', '⟹': r'\Longrightarrow', //
  '⟺': r'\Longleftrightarrow', '↑': r'\uparrow', '↓': r'\downarrow', //
  '…': r'\ldots', '⋯': r'\cdots', '⋮': r'\vdots', '⋱': r'\ddots', //
  '∑': r'\sum', '∏': r'\prod', '∐': r'\coprod', '∫': r'\int', //
  '∬': r'\iint', '∭': r'\iiint', '∮': r'\oint', '⋃': r'\bigcup', //
  '⋂': r'\bigcap', '⨁': r'\bigoplus', '⨂': r'\bigotimes', //
  '⌊': r'\lfloor', '⌋': r'\rfloor', '⌈': r'\lceil', '⌉': r'\rceil', //
  '⟨': r'\langle', '⟩': r'\rangle', '′': "'", '″': "''", '‴': "'''", //
  'ℝ': r'\mathbb{R}', 'ℕ': r'\mathbb{N}', 'ℤ': r'\mathbb{Z}', //
  'ℚ': r'\mathbb{Q}', 'ℂ': r'\mathbb{C}', 'ℓ': r'\ell', 'ℏ': r'\hbar', //
  'ℜ': r'\Re', 'ℑ': r'\Im', 'ℵ': r'\aleph', '∠': r'\angle', //
  '△': r'\triangle', '□': r'\square', '°': r'^\circ',
};
