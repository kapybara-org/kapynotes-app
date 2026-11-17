import { selectEl } from './helpers.mjs';
const sel = selectEl;
// range from the start of an element matched by 'from' to the end of the element matched by 'to'
const range = (a) => {
  const ps = [...document.querySelectorAll('#mw-content-text .mw-parser-output p')].filter(p => p.innerText.trim().length > 40 && !p.closest('table, .infobox, .navbox, .hatnote, figure, .thumb, .metadata'));
  let startEl = a.from ? document.querySelector(a.from) : ps[0];
  if (!startEl) return false;
  startEl = startEl.closest('.mw-heading') || startEl;
  const after = ps.filter(p => startEl === p || (startEl.compareDocumentPosition(p) & Node.DOCUMENT_POSITION_FOLLOWING));
  const endEl = after[a.n - 1];
  if (!endEl) return false;
  const r = document.createRange(); r.setStartBefore(startEl); r.setEndAfter(endEl);
  const s = getSelection(); s.removeAllRanges(); s.addRange(r); return String(s).length;
};
const mergedTable = () => {
  const t = [...document.querySelectorAll('table.wikitable')].find(t => t.querySelector('[rowspan]') && t.querySelector('[colspan]'));
  if (!t) return false;
  const r = document.createRange(); r.selectNode(t);
  const s = getSelection(); s.removeAllRanges(); s.addRange(r); return String(s).length;
};
export default [
  { source:'wikipedia', case:'quadratic-formula-math', url:'https://en.wikipedia.org/wiki/Quadratic_formula',
    select: range, selectArg:{n:3},
    how: 'Selected the first three paragraphs of the English Wikipedia article "Quadratic formula" (inline and display math) and ran document.execCommand("copy").',
    notes:'Math is rendered by MediaWiki as <span class="mwe-math-element"> containing a MathML <math> tree plus an <img class="mwe-math-fallback-image-*"> SVG fallback (hidden with CSS); the plain text carries the math as linearised text, with the TeX only in <annotation encoding="application/x-tex"> inside the MathML. Chrome inlines computed styles into every element of the selection.' },
  { source:'wikipedia', case:'quadratic-formula-derivation', url:'https://en.wikipedia.org/wiki/Quadratic_formula',
    select: sel, selectArg:'#mw-content-text .mw-parser-output', 
    how:'Selected the whole article body of "Quadratic formula" (all sections, 200+ MathML formulas) and ran document.execCommand("copy").', notes:'Whole-article selection: MathML-heavy, section headings with [edit] links, reference markers [1], navboxes.' },
  { source:'wikipedia', case:'periodic-table-merged-cells', url:'https://en.wikipedia.org/wiki/Periodic_table',
    select: mergedTable, how:'Selected the first wikitable that uses both rowspan and colspan (orbital/shell capacity table) in the "Periodic table" article and ran document.execCommand("copy").',
    notes:'Table with rowspan/colspan merged cells; selection of the table node itself so the <table> wrapper is in the HTML.' },
  { source:'wikipedia', case:'einstein-infobox-lead', url:'https://en.wikipedia.org/wiki/Albert_Einstein',
    select: range, selectArg:{from:'table.infobox', n:4},
    how:'Selected from the infobox through the fourth paragraph of the lead of "Albert Einstein" and ran document.execCommand("copy").',
    notes:'Infobox (table.infobox.biography.vcard) with image, nested tables/lists, plus lead paragraphs containing [1] reference markers (<sup class="reference">) and hatnotes. Relative-protocol image URLs (//upload.wikimedia.org/...).' },
  { source:'wikipedia', case:'einstein-section-with-edit-links', url:'https://en.wikipedia.org/wiki/Albert_Einstein',
    select: range, selectArg:{from:'[id="Childhood,_youth_and_education"]', n:6},
    how:'Selected the "Childhood, youth and education" heading plus its first six paragraphs in "Albert Einstein" and ran document.execCommand("copy").',
    notes:'Heading with the [edit] link (<span class="mw-editsection">) and many <sup class="reference">[n]</sup> citation markers that should usually be dropped.' },
  { source:'wikipedia', case:'cairo-arabic-rtl', url:'https://ar.wikipedia.org/wiki/القاهرة', pageUrl:'https://ar.wikipedia.org/wiki/%D8%A7%D9%84%D9%82%D8%A7%D9%87%D8%B1%D8%A9',
    select: range, selectArg:{n:5},
    how:'Selected the first paragraphs of the Arabic Wikipedia article "القاهرة" (Cairo) and ran document.execCommand("copy").',
    notes:'Right-to-left Arabic text (dir="rtl" on the page, text-align computed styles), with Latin/digits mixed in and bidi references.' },
  { source:'wikipedia', case:'tokyo-japanese', url:'https://ja.wikipedia.org/wiki/東京都', pageUrl:'https://ja.wikipedia.org/wiki/%E6%9D%B1%E4%BA%AC%E9%83%BD',
    select: range, selectArg:{n:5},
    how:'Selected the first paragraphs of the Japanese Wikipedia article 東京都 and ran document.execCommand("copy").', notes:'CJK text with ruby/furigana-style markup possible, full-width punctuation, no spaces between words.' },
  { source:'wikipedia', case:'tokyo-climate-table-cjk', url:'https://ja.wikipedia.org/wiki/東京都', pageUrl:'https://ja.wikipedia.org/wiki/%E6%9D%B1%E4%BA%AC%E9%83%BD',
    select: mergedTable, how:'Selected the first wikitable with merged cells on the Japanese article 東京都 (climate data) and ran document.execCommand("copy").', notes:'Merged-cell data table with CJK headers and numeric data.' },
  { source:'wikipedia', case:'roman-emperors-long', url:'https://en.wikipedia.org/wiki/List_of_Roman_emperors',
    select: sel, selectArg:'#mw-content-text .mw-parser-output',
    how:'Selected the entire article body of "List of Roman emperors" (the very long case: ~1,700 text lines, 200+ images, many large tables) and ran document.execCommand("copy").',
    notes:'The long-answer stand-in: tens of thousands of nodes, hundreds of <img> with srcset and protocol-relative URLs, nested tables with rowspan. Expect a multi-MB HTML payload and a >100 kB plain text.' },
];
