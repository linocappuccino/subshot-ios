// 2026-11-18 — hybrid plan check: are the web pages usable at iPhone (390 px) and iPad (1024 px) width?
// Signs in as the fixed test account (one-time ticket via the CI secret, never printed) and screenshots
// post-production, ideas/storyboard and deliver of the demo project. Output: shots/<page>-<width>.png + report.txt
const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const secret = process.env.DEBUG_TICKET_SECRET || '';
  if (!secret) { console.log('DEBUG_TICKET_SECRET missing'); process.exit(1); }
  const r = await fetch('https://subshot.ch/debug/test-ticket', { method: 'POST', headers: { 'X-Debug-Secret': secret } });
  if (r.status !== 200) { console.log('ticket http', r.status); process.exit(1); }
  const { ticket } = await r.json();
  fs.mkdirSync('shots', { recursive: true });
  const lines = [];
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1024, height: 1366 }, deviceScaleFactor: 2, hasTouch: true });
  const page = await ctx.newPage();
  await page.goto(`https://app.subshot.ch/embed/auth?ticket=${encodeURIComponent(ticket)}&next=/embed/warm`, { waitUntil: 'domcontentloaded' });
  await page.waitForURL(/embed\/warm/, { timeout: 45000 }).catch(() => lines.push('auth ended on ' + page.url().replace(/\?.*/, '')));
  const pid = 'c15ead5c-1d16-4f9b-ac97-547fb244e7a4';
  const pages = { postpro: `/projects/${pid}/postproduction`, ideas: `/projects/${pid}`, deliver: `/projects/${pid}/deliver` };
  for (const w of [390, 1024]) {
    await page.setViewportSize({ width: w, height: w === 390 ? 844 : 1366 });
    for (const [name, path] of Object.entries(pages)) {
      await page.goto('https://app.subshot.ch' + path, { waitUntil: 'domcontentloaded' });
      await page.waitForTimeout(9000);
      const m = await page.evaluate(() => ({
        overflow: document.documentElement.scrollWidth - window.innerWidth,
        height: document.documentElement.scrollHeight,
      }));
      await page.screenshot({ path: `shots/${name}-${w}.png` });
      await page.screenshot({ path: `shots/${name}-${w}-full.png`, fullPage: true });
      lines.push(`${name} ${w}px url=${page.url().replace(/\?.*/, '')} horizontal_overflow_px=${m.overflow} page_height_px=${m.height}`);
    }
  }
  await browser.close();
  fs.writeFileSync('shots/report.txt', lines.join('\n') + '\n');
  console.log(lines.join('\n'));
})();
