import { selectEl } from './helpers.mjs';
const wait = (ms) => async () => new Promise(r => setTimeout(r, ms));
const nth = (a) => {
  const els = document.querySelectorAll(a.sel); const el = els[a.i || 0]; if (!el) return false;
  const r = document.createRange();
  if (a.contents) r.selectNodeContents(el); else r.selectNode(el);
  const s = getSelection(); s.removeAllRanges(); s.addRange(r); return String(s).length;
};
const firstBlocks = (a) => {
  const root = document.querySelector(a.root); if (!root) return false;
  const kids = [...root.children].filter(k => k.innerText.trim().length || k.querySelector('img'));
  const r = document.createRange(); r.setStartBefore(kids[a.from || 0]); r.setEndAfter(kids[Math.min(kids.length - 1, a.to)]);
  const s = getSelection(); s.removeAllRanges(); s.addRange(r); return String(s).length;
};
export default [
  { source:'github', case:'readme-got-headings-tables-code', url:'https://github.com/sindresorhus/got', open:{waitUntil:'domcontentloaded'}, prepare:wait(2500),
    select: nth, selectArg:{sel:'article.markdown-body', contents:true},
    how:'Opened the rendered README of github.com/sindresorhus/got and selected the entire README body (article.markdown-body) with a DOM range, then ran document.execCommand("copy").',
    notes:'GitHub-rendered markdown: headings wrapped in div.markdown-heading with an <a class="anchor"> permalink containing an octicon <svg> (and the heading text), <table>s, <pre><code> blocks wrapped in div.highlight with <div class="zeroclipboard-container"> copy buttons, and badges as <img> inside <a>.' },
  { source:'github', case:'issue-body-task-list', url:'https://github.com/rust-lang/rust/issues/44265', open:{waitUntil:'domcontentloaded'}, prepare:wait(3000),
    select: nth, selectArg:{sel:'.markdown-body', i:0, contents:true},
    how:'Opened the rust-lang/rust tracking issue #44265 (generic associated types) and selected the issue body (the first .markdown-body) with a DOM range, then ran document.execCommand("copy").',
    notes:'Issue body with nested task lists (ul.contains-task-list, li.task-list-item with <input type="checkbox" class="task-list-item-checkbox">, checked and unchecked), links to issues/PRs rendered as plain links, and headings without anchors in this view.' },
  { source:'github', case:'pr-body-checklist', url:'https://github.com/nodejs/node/issues/28831', open:{waitUntil:'domcontentloaded'}, prepare:wait(3000),
    select: nth, selectArg:{sel:'.markdown-body', i:0, contents:true},
    how:'Opened the nodejs/node pull request #28831 and selected the PR description (first .markdown-body, a short checklist body) with a DOM range, then ran document.execCommand("copy").',
    notes:'Short PR description: a "Refs:" line and a Checklist section of checkbox items (task-list-item) with inline code; small on purpose.' },
  { source:'web', case:'mdn-html-images-relative-urls', url:'https://developer.mozilla.org/en-US/docs/Learn_web_development/Core/Structuring_content/HTML_images', open:{waitUntil:'domcontentloaded'}, prepare:wait(3500),
    select: nth, selectArg:{sel:'.reference-layout__body', contents:true},
    how:'Opened the MDN "HTML images" learning article and selected the whole <article> with a DOM range, then ran document.execCommand("copy").',
    notes:'The source page uses root-relative image URLs (src="/en-US/docs/Learn_web_development/.../basic-image.png"). Chrome resolves URLs while serializing a selection, so the clipboard HTML carries absolute https://developer.mozilla.org/... URLs: relative URLs will not appear in a real Chrome copy. Code blocks use <pre class="brush: html"> with highlighted spans.' },
  { source:'web', case:'getemoji-people-skin-tones', url:'https://getemoji.com/', open:{waitUntil:'domcontentloaded'}, prepare:wait(2500),
    select: () => { const s = [...document.querySelectorAll('main section')]; const r = document.createRange(); r.setStartBefore(s[2]); r.setEndAfter(s[4]); const g = getSelection(); g.removeAllRanges(); g.addRange(r); return String(g).length; },
    how:'Opened getemoji.com and selected three emoji sections (People and Fantasy, Clothing and Accessories, Pale Emojis) with a DOM range, then ran document.execCommand("copy").',
    notes:'Emoji heavy: ZWJ sequences, skin-tone modifiers (U+1F3FB-1F3FF), variation selectors; check surrogate pairs and joiners survive in both html and plain text.' },
  { source:'stackexchange', case:'askubuntu-answer-code-blocks', url:'https://askubuntu.com/questions/46627', open:{waitUntil:'domcontentloaded'}, prepare:wait(4000),
    select: nth, selectArg:{sel:'.answer', i:0, contents:true},
    how:'Opened the Ask Ubuntu question 46627 (Stack Exchange network; stackoverflow.com itself serves a Cloudflare challenge to headless Chrome) and selected the first answer with a DOM range, then ran document.execCommand("copy").',
    notes:'Same markup as Stack Overflow answers: <pre class="lang-bash s-code-block"><code class="hljs language-bash"> blocks with highlight.js spans, inline <code>, <kbd>, lists. Substitute for the blocked stackoverflow.com capture.' },
];
