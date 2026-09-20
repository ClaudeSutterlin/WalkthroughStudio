// Render .mmd files to SVG+PNG with the bundled mermaid build in headless chromium.
// This is the offline path the app uses (BrandedRenderer + WKWebView); rendering here
// proves the projector emits Mermaid that the pinned build actually accepts.
import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, basename } from 'node:path';

const [,, dir, vendor, outDir] = process.argv;
const mermaid = readFileSync(vendor, 'utf8');
const files = readdirSync(dir).filter(f => f.endsWith('.mmd')).sort();
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--no-sandbox'] });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2 });
page.on('pageerror', e => console.log('PAGE ERROR', e.message.slice(0, 200)));
let failures = 0;
for (const f of files) {
  const src = readFileSync(join(dir, f), 'utf8');
  // mermaid.run() races its own startOnLoad pass and can mark an element processed
  // without emitting an svg; mermaid.render() takes the text directly and honours the
  // config we just set, which is what the app does with BrandTheme's tokens.
  await page.setContent(`<!doctype html><html><head><meta charset="utf-8"><style>
    body{margin:0;background:#FFFBF5;font-family:Georgia,serif}
    #d{padding:28px}
  </style></head><body><div id="d"></div>
  <script>${mermaid}</script></body></html>`, { waitUntil: 'load' });
  const result = await page.evaluate(async (text) => {
    try {
      window.mermaid.initialize({ startOnLoad: false, securityLevel: 'loose', theme: 'base', themeVariables: {
        primaryColor: '#FFFBF5', primaryTextColor: '#1A1612', primaryBorderColor: '#1A1612',
        lineColor: '#1A1612', secondaryColor: '#F2E8DC', tertiaryColor: '#FFFBF5',
        fontFamily: 'Georgia, serif', fontSize: '15px' } });
      const { svg: markup } = await window.mermaid.render('g' + Math.floor(performance.now() * 1000), text);
      document.getElementById('d').innerHTML = markup;
      const svg = document.querySelector('#d svg');
      if (!svg) return { ok: false, error: 'no svg produced' };
      svg.removeAttribute('height'); svg.style.maxWidth = 'none';
      const box = svg.getBoundingClientRect();
      return { ok: true, svg: svg.outerHTML, w: Math.round(box.width), h: Math.round(box.height),
               nodes: svg.querySelectorAll('.node, .er.entityBox, .actor, g.root .nodes g').length,
               text: Array.from(svg.querySelectorAll('text')).slice(0,4).map(t=>t.textContent.trim()).filter(Boolean) };
    } catch (e) { return { ok: false, error: String(e && e.message || e).slice(0, 300) }; }
  }, src);
  const name = basename(f, '.mmd');
  if (!result.ok) { console.log(`FAIL ${name}: ${result.error}`); failures++; continue; }
  writeFileSync(join(outDir, name + '.svg'), result.svg);
  const el = await page.$('#d');
  await el.screenshot({ path: join(outDir, name + '.png') });
  console.log(`ok   ${name}: ${result.w}x${result.h}px, ${result.nodes} nodes, text: ${JSON.stringify(result.text)}`);
}
await browser.close();
console.log(failures ? `${failures} diagram(s) failed` : 'all diagrams rendered');
process.exit(failures ? 1 : 0);
