import {answerRange} from './ai-helpers.mjs';
// choose the longest assistant answer on the page and remember its index on the Page object
const pickBest = (fixed) => async (p) => {
  await new Promise(r => setTimeout(r, 8000));
  if (fixed !== undefined) { p.__best = fixed; return; }
  p.__best = await p.evaluate((fn) => {
    const f = eval('(' + fn + ')');
    const n = [...document.querySelectorAll('button')].filter(b => /^copy response$/i.test(b.getAttribute('aria-label') || '')).length;
    let best = 0, bl = -1;
    for (let i = 0; i < n; i++) { const l = f(i); if (l > bl) { bl = l; best = i; } }
    getSelection().removeAllRanges();
    return best;
  }, answerRange.toString());
};
const mk = (id, kase, what, notes, fixed) => [
  { source:'chatgpt', case: kase + '-copy-button', url:'https://chatgpt.com/share/' + id, open:{waitUntil:'domcontentloaded'}, prepare: pickBest(fixed),
    action: async (p) => { const b = await p.$$('button[aria-label="Copy response"]'); await b[p.__best].click(); },
    how: 'Opened the public ChatGPT share page and clicked the site\'s own "Copy response" button under the longest assistant answer (' + what + ').', notes },
  { source:'chatgpt', case: kase + '-selection', url:'https://chatgpt.com/share/' + id, open:{waitUntil:'domcontentloaded'}, prepare: pickBest(fixed),
    selectPage: async (p) => p.evaluate(answerRange, p.__best),
    how: 'Opened the public ChatGPT share page and selected the longest assistant answer (' + what + ') from its first block to its last with a DOM range (what a mouse drag over the answer yields), then ran document.execCommand("copy").', notes },
];
export default [
  ...mk('69ed83b1-3704-8322-bcf2-322aa85d7a99', 'math-number-theory', 'inline and display KaTeX math', 'KaTeX math: inline and display equations. Compare what the copy button writes with what a selection yields: the button writes text/plain (markdown-ish source) plus text/html, a selection writes Chrome-serialized rendered DOM.'),
  ...mk('512002b1-ceb3-48b5-9a29-d44b63f50460', 'math-stochastic-processes-german', 'German text with KaTeX', 'German-language answer with KaTeX math.'),
  ...mk('6ab5ca51-3e0c-83e8-a232-892d3e4ef914', 'table-math-headings', 'headings, a table and some math', 'Headings, a GFM table and inline math in one answer.'),
  ...mk('6ad8ad3d-3f6c-83e9-abf0-41da8a0d6573', 'code-tables-php', 'PHP and other code blocks plus tables', 'Many fenced code blocks of several languages, 5 tables, headings.'),
  ...mk('ccc23d98-6d4f-4be5-b9b6-b4464ff1bf9d', 'code-c-spanish', 'C code blocks in a Spanish answer', 'C code blocks with nested lists in Spanish.'),
  ...mk('691b4035-0ed8-800a-bee3-ae68e2a63cbb', 'nested-lists-emoji', 'deeply nested lists with emoji', 'Deeply nested bullet and numbered lists with emoji.', 11),
  ...mk('67bde29f-a56c-800a-8e26-44a5a3ad2326', 'nested-lists-emoji-2', 'nested lists, headings and emoji', 'Nested lists and emoji headings.'),
  ...mk('66eb36c5-a55c-8005-9ee1-d42770297d9b', 'code-nested-long', 'a long answer with code and nested lists', 'Long answer with 11 code blocks and nested lists.'),
  ...mk('6a6f09ff-2830-83ea-9578-de3016cfae1f', 'long-math-code-tables-images', 'math, code, tables and 57 images', 'Very long answer: 80 KaTeX nodes, ~48 code blocks, 3 tables, images.'),
];
