const wait = (ms) => async () => new Promise(r => setTimeout(r, ms));
const geminiLargest = () => {
  const els = [...document.querySelectorAll('message-content')];
  els.sort((a, b) => b.innerText.length - a.innerText.length);
  const el = els[0]; if (!el) return false;
  const r = document.createRange(); r.selectNodeContents(el);
  const s = getSelection(); s.removeAllRanges(); s.addRange(r); return String(s).length;
};
const pplxLargest = () => {
  const els = [...document.querySelectorAll('div[class*="_root_"]')].filter(e => !e.closest('[class*="user-bubble"]') && e.querySelector('p'));
  els.sort((a, b) => b.innerText.length - a.innerText.length);
  const el = els[0]; if (!el) return false;
  const r = document.createRange(); r.selectNodeContents(el);
  const s = getSelection(); s.removeAllRanges(); s.addRange(r); return String(s).length;
};
const gem = (id, kase, what, notes) => ({ source:'gemini', case:kase+'-selection', url:'https://gemini.google.com/share/'+id, open:{waitUntil:'domcontentloaded'}, prepare:wait(6000), select:geminiLargest,
  how:'Opened the public Gemini share page and selected the longest response (a <message-content> element: '+what+') with a DOM range, then ran document.execCommand("copy"). The shared (signed-out) view has no per-response copy button, only "Copy prompt" on user turns, so there is no copy-button capture.', notes });
const ppx = (id, kase, what, notes) => [
  { source:'perplexity', case:kase+'-selection', url:'https://www.perplexity.ai/session/'+id, open:{waitUntil:'domcontentloaded'}, prepare:wait(6000), select:pplxLargest,
    how:'Opened the public Perplexity session page and selected the answer body ('+what+') with a DOM range, then ran document.execCommand("copy").', notes },
  { source:'perplexity', case:kase+'-copy-button', url:'https://www.perplexity.ai/session/'+id, open:{waitUntil:'domcontentloaded'}, prepare:wait(6000),
    action: async (p) => { const b = await p.$('button[aria-label="Copy"]'); if (!b) throw new Error('no Copy button'); await b.click(); },
    how:'Opened the public Perplexity session page and clicked the answer\'s own "Copy" button ('+what+').', notes },
];
export default [
  gem('918e7883df8a','math-tables','KaTeX math and tables','Math is rendered by Gemini as <span class="math-inline" data-math="..."> / <div class="math-block" data-math="..."> carrying the TeX in the data-math attribute with KaTeX DOM inside.'),
  gem('7af54a6861d7','code-tables','code blocks and tables','Gemini code blocks are <code-block> custom elements with a header (language label, copy button) around <pre><code>.'),
  gem('1e70ae398d26','nested-lists-long','a ~40k-character answer with nested lists and tables','Long answer with many nested lists, headings, 4 tables.'),
  gem('6e00fab74749','math-heavy','52 math nodes','Math-heavy answer.'),
  ...ppx('cb8dfa18-d668-4bad-ae57-83b1cf7cbbcc','table-links','a table and citations','Tables with Perplexity citation chips (<a> / <span> with source favicons) and a "Copy table" toolbar.'),
  ...ppx('08b4e2d1-f249-4827-8b69-2f3d7207a753','table-math','tables and some math','Tables and inline math.'),
  ...ppx('a46245cd-5731-42f1-9158-4de7c9c37bbe','code','a code answer','Code block answer.'),
  ...ppx('38843335-64cd-4c03-bdbc-a7721a99813b','nested-lists','nested lists with citations','Lists with citation markers.'),
];
