// 2026-11-18 (board memory) — measure the iOS board embed in WebKit (Playwright, same engine as iOS; Linux build,
// so absolute numbers are an approximation of the iPad, the relative causes are what counts).
// For each test board × viewport (iPhone 390×844 @3, iPad 1024×1366 @2): open /embed/idea/<project>/<idea> exactly
// like the app (signed in via one-time ticket, app embed), wait, pan, zoom; meanwhile sample the WebKit processes'
// RSS every second and collect page metrics: <video> elements and their state, images and their decoded pixels,
// bytes received per media type. Output: board-memory.json + per-board screenshots (synthetic test content only).
const { webkit } = require('playwright');
const fs = require('fs');
const { execSync } = require('child_process');

const PROJECT = 'c15ead5c-1d16-4f9b-ac97-547fb244e7a4';
const BOARDS = JSON.parse(process.env.BOARDS || '[]'); // [{title,id}]
const QUERY = process.env.EMBED_QUERY || ''; // e.g. "lite=1&media=still" for the fixed variants
const VIEWPORTS = [
  { name: 'iphone', width: 390, height: 844, dpr: 3 },
  { name: 'ipad', width: 1024, height: 1366, dpr: 2 },
];

function webkitRssMB() {
  try {
    const out = execSync("ps -eo rss,comm | grep -E 'WebKitWebProces|WebKitGPUProces|WebKitNetworkPr' || true").toString();
    const by = {};
    for (const l of out.trim().split('\n').filter(Boolean)) {
      const [rss, name] = l.trim().split(/\s+/);
      by[name] = (by[name] || 0) + Number(rss) / 1024;
    }
    return by;
  } catch { return {}; }
}

async function pageMetrics(page) {
  return page.evaluate(() => {
    const vids = [...document.querySelectorAll('video')];
    const imgs = [...document.querySelectorAll('img')];
    const decodedMB = imgs.filter((i) => i.complete && i.naturalWidth).reduce((s, i) => s + i.naturalWidth * i.naturalHeight * 4, 0) / 1048576;
    return {
      dom_nodes: document.getElementsByTagName('*').length,
      videos: vids.length,
      videos_with_poster: vids.filter((v) => v.poster).length,
      videos_preload: vids.reduce((m, v) => ((m[v.preload || '?'] = (m[v.preload || '?'] || 0) + 1), m), {}),
      videos_loaded_data: vids.filter((v) => v.readyState >= 2).length,
      videos_playing: vids.filter((v) => !v.paused).length,
      video_px_max: vids.reduce((m, v) => Math.max(m, v.videoWidth * v.videoHeight), 0),
      images: imgs.length,
      images_loaded: imgs.filter((i) => i.complete && i.naturalWidth).length,
      images_decoded_mb: +decodedMB.toFixed(1),
      image_max_px: imgs.reduce((m, i) => Math.max(m, i.naturalWidth * i.naturalHeight), 0),
      canvas: [...document.querySelectorAll('canvas')].map((c) => `${c.width}x${c.height}`),
      dpr: window.devicePixelRatio,
    };
  });
}

(async () => {
  const secret = process.env.DEBUG_TICKET_SECRET || '';
  if (!secret) throw new Error('DEBUG_TICKET_SECRET missing');
  fs.mkdirSync('shots', { recursive: true });
  const results = [];
  for (const vp of VIEWPORTS) {
    const browser = await webkit.launch();
    const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, deviceScaleFactor: vp.dpr, isMobile: true, hasTouch: true,
      userAgent: 'Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148' });
    const page = await ctx.newPage();
    const r = await fetch('https://subshot.ch/debug/test-ticket', { method: 'POST', headers: { 'X-Debug-Secret': secret } });
    if (r.status !== 200) throw new Error('ticket ' + r.status);
    const { ticket } = await r.json();
    await page.goto(`https://app.subshot.ch/embed/auth?ticket=${encodeURIComponent(ticket)}&next=/embed/warm`);
    await page.waitForURL((u) => u.pathname.startsWith('/embed/warm'), { timeout: 60000 });
    await page.waitForTimeout(3000);
    for (const b of BOARDS) {
      await page.goto('https://app.subshot.ch/embed/warm');
      await page.waitForTimeout(4000);
      const base = webkitRssMB();
      const bytes = {};
      const onResp = async (resp) => {
        const ct = (resp.headers()['content-type'] || '').split(';')[0];
        const len = Number(resp.headers()['content-length'] || 0);
        const k = ct.startsWith('video') ? 'video' : ct.startsWith('image') ? 'image' : 'other';
        bytes[k] = (bytes[k] || 0) + len;
      };
      page.on('response', onResp);
      let peak = {};
      const timer = setInterval(() => {
        const m = webkitRssMB();
        for (const [k, v] of Object.entries(m)) peak[k] = Math.max(peak[k] || 0, v);
      }, 1000);
      const url = `https://app.subshot.ch/embed/idea/${PROJECT}/${b.id}${QUERY ? '?' + QUERY : ''}`;
      await page.goto(url, { waitUntil: 'domcontentloaded' });
      await page.waitForTimeout(25000);
      const loaded = await pageMetrics(page);
      const atLoad = webkitRssMB();
      await page.screenshot({ path: `shots/${b.title.replace(/\s+/g, '-')}-${vp.name}-1.png` });
      // pan + zoom (wheel = pan, ctrl+wheel = zoom on the board)
      await page.mouse.move(vp.width / 2, vp.height / 2);
      for (let i = 0; i < 6; i++) { await page.mouse.wheel(400, 300); await page.waitForTimeout(800); }
      for (let i = 0; i < 4; i++) { await page.keyboard.down('Control'); await page.mouse.wheel(0, -300); await page.keyboard.up('Control'); await page.waitForTimeout(800); }
      await page.waitForTimeout(4000);
      for (let i = 0; i < 6; i++) { await page.keyboard.down('Control'); await page.mouse.wheel(0, 400); await page.keyboard.up('Control'); await page.waitForTimeout(800); }
      await page.waitForTimeout(6000);
      const after = await pageMetrics(page);
      await page.screenshot({ path: `shots/${b.title.replace(/\s+/g, '-')}-${vp.name}-2.png` });
      clearInterval(timer);
      page.off('response', onResp);
      const res = { board: b.title, viewport: vp.name, query: QUERY || 'none', rss_before_mb: base, rss_at_load_mb: atLoad, rss_peak_mb: peak,
        received_mb: Object.fromEntries(Object.entries(bytes).map(([k, v]) => [k, +(v / 1e6).toFixed(1)])), at_load: loaded, after_pan_zoom: after };
      for (const side of ['rss_before_mb', 'rss_at_load_mb', 'rss_peak_mb']) for (const k in res[side]) res[side][k] = Math.round(res[side][k]);
      results.push(res);
      console.log(JSON.stringify(res));
    }
    await browser.close();
  }
  fs.writeFileSync('board-memory.json', JSON.stringify(results, null, 2));
})().catch((e) => { console.error(String(e.message || e)); process.exit(1); });
