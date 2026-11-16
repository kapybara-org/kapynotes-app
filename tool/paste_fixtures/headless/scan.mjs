// node scan.mjs urls.txt out.jsonl  -- scores AI share pages by content features
import {launch, openPage, changeCount} from './lib.mjs';
import fs from 'node:fs';
const urls = fs.readFileSync(process.argv[2],'utf8').split('\n').filter(Boolean);
const out = process.argv[3];
const b = await launch();
let i = 0;
async function worker() {
  while (i < urls.length) {
    const u = urls[i++];
    let p;
    try {
      p = await b.newPage();
      await p.goto(u, {waitUntil:'domcontentloaded', timeout:30000}).catch(()=>{});
      await new Promise(r=>setTimeout(r,5000));
      const info = await p.evaluate(() => {
        const t = document.body.innerText;
        return { url: location.href, title: document.title, len: t.length,
          table: document.querySelectorAll('table').length, pre: document.querySelectorAll('pre').length,
          katex: document.querySelectorAll('.katex, [data-math], .math-block, .math-inline').length, cb: document.querySelectorAll('code-block, pre').length, mathml: document.querySelectorAll('math').length,
          nested: document.querySelectorAll('li li').length, h: document.querySelectorAll('h1,h2,h3,h4').length,
          emoji: (t.match(/\p{Extended_Pictographic}/gu)||[]).length, imgs: document.querySelectorAll('img').length,
          copy: [...document.querySelectorAll('button')].filter(b=>/copy/i.test(b.getAttribute('aria-label')||b.innerText||'')).length,
          blocked: /Just a moment|Verify you are human|Not Found|doesn't exist/i.test(document.title+t.slice(0,300)) };
      });
      fs.appendFileSync(out, JSON.stringify(info)+'\n');
    } catch(e) { fs.appendFileSync(out, JSON.stringify({url:u, err:e.message.slice(0,80)})+'\n'); }
    finally { if (p) await p.close().catch(()=>{}); }
  }
}
await Promise.all([1,2,3,4,5].map(worker));
await b.close();
