// Page-side helper: select a range from a CSS selector (whole element contents) or from one element's start to another's end.
export const selectEl = (arg) => {
  const a = typeof arg === 'string' ? { sel: arg } : arg;
  const first = document.querySelector(a.sel);
  if (!first) return false;
  const r = document.createRange();
  if (a.to) {
    const last = document.querySelector(a.to);
    if (!last) return false;
    r.setStartBefore(first); r.setEndAfter(last);
  } else r.selectNodeContents(first);
  const s = getSelection(); s.removeAllRanges(); s.addRange(r);
  return String(s).length || true;
};
