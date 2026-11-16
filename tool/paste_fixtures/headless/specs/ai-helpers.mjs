// Page-side: select the idx-th assistant answer on a ChatGPT share page, the way a user dragging from its first line to its last would.
export const answerRange = (idx) => {
  const btn = [...document.querySelectorAll('button')].filter(b => /^copy response$/i.test(b.getAttribute('aria-label') || ''))[idx];
  if (!btn) return false;
  const BLOCK = 'p, h1, h2, h3, h4, h5, h6, ul, ol, pre, table, blockquote, hr';
  let a = btn.parentElement;
  while (a && ![...a.querySelectorAll(BLOCK)].some(e => !btn.contains(e) && e.innerText.trim().length)) a = a.parentElement;
  if (!a) return false;
  const blocks = [...a.querySelectorAll(BLOCK)].filter(e => !e.parentElement.closest(BLOCK) || !a.contains(e.parentElement.closest(BLOCK)));
  const r = document.createRange();
  r.setStartBefore(blocks[0]); r.setEndAfter(blocks[blocks.length - 1]);
  const s = getSelection(); s.removeAllRanges(); s.addRange(r);
  return String(s).length;
};
export const clickCopy = (idx) => async (page) => {
  const btns = await page.$$('button[aria-label="Copy response"]');
  if (!btns[idx]) throw new Error('no copy button ' + idx);
  await btns[idx].click();
};
