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
  // /proc directly (the Playwright container has no ps): every WebKit helper process, RSS summed per name
  const by = {};
  for (const pid of fs.readdirSync('/proc').filter((d) => /^\d+$/.test(d))) {
    try {
      const comm = fs.readFileSync(`/proc/${pid}/comm`, 'utf8').trim();
      if (!/^WebKit(Web|GPU|Network)/.test(comm)) continue;
      const m = fs.readFileSync(`/proc/${pid}/status`, 'utf8').match(/VmRSS:\s+(\d+)/);
      if (m) by[comm] = (by[comm] || 0) + Number(m[1]) / 1024;
    } catch { /* process gone */ }
  }
  return by;
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

function withTimeout(p, ms, what) {
  return Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('timeout ' + what)), ms))]).catch((e) => ({ error: String(e.message || e) }));
}

(async () => {
  const secret = process.env.DEBUG_TICKET_SECRET || '';
  if (!secret) throw new Error('DEBUG_TICKET_SECRET missing');
  fs.mkdirSync('shots', { recursive: true });
  const results = [];
  for (const vp of VIEWPORTS) {
    const browser = await webkit.launch();
    const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, deviceScaleFactor: vp.dpr, isMobile: false, hasTouch: false,
      userAgent: 'Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148' });
    const login = await ctx.newPage();
    const r = await fetch('https://subshot.ch/debug/test-ticket', { method: 'POST', headers: { 'X-Debug-Secret': secret } });
    if (r.status !== 200) throw new Error('ticket ' + r.status);
    const { ticket } = await r.json();
    await login.goto(`https://app.subshot.ch/embed/auth?ticket=${encodeURIComponent(ticket)}&next=/embed/warm`);
    await login.waitForURL((u) => u.pathname.startsWith('/embed/warm'), { timeout: 60000 });
    await login.waitForTimeout(3000);
    await login.close();
    for (const b of BOARDS) {
      const page = await ctx.newPage();
      let crashed = null;
      page.on('crash', () => { crashed = new Date().toISOString(); console.log(crashed, b.title, vp.name, 'PAGE CRASHED'); });
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
      console.log(new Date().toISOString(), b.title, vp.name, 'loaded, measuring');
      const loaded = await withTimeout(pageMetrics(page), 20000, 'metrics');
      const atLoad = webkitRssMB();
      await withTimeout(page.screenshot({ path: `shots/${b.title.replace(/\s+/g, '-')}-${vp.name}-1.png`, timeout: 20000 }), 25000, 'shot1');
      console.log(new Date().toISOString(), b.title, vp.name, 'pan/zoom');
      // pan + zoom (wheel = pan, ctrl+wheel = zoom on the board)
      await page.mouse.move(vp.width / 2, vp.height / 2);
      await withTimeout((async () => {
        for (let i = 0; i < 6; i++) { await page.mouse.wheel(400, 300); await page.waitForTimeout(800); }
        for (let i = 0; i < 4; i++) { await page.keyboard.down('Control'); await page.mouse.wheel(0, -300); await page.keyboard.up('Control'); await page.waitForTimeout(800); }
        await page.waitForTimeout(4000);
        for (let i = 0; i < 6; i++) { await page.keyboard.down('Control'); await page.mouse.wheel(0, 400); await page.keyboard.up('Control'); await page.waitForTimeout(800); }
        await page.waitForTimeout(6000);
      })(), 60000, 'panzoom');
      const after = await withTimeout(pageMetrics(page), 20000, 'metrics2');
      await withTimeout(page.screenshot({ path: `shots/${b.title.replace(/\s+/g, '-')}-${vp.name}-2.png`, timeout: 20000 }), 25000, 'shot2');
      clearInterval(timer);
      page.off('response', onResp);
      const res = { board: b.title, viewport: vp.name, query: QUERY || 'none', crashed, rss_before_mb: base, rss_at_load_mb: atLoad, rss_peak_mb: peak,
        received_mb: Object.fromEntries(Object.entries(bytes).map(([k, v]) => [k, +(v / 1e6).toFixed(1)])), at_load: loaded, after_pan_zoom: after };
      for (const side of ['rss_before_mb', 'rss_at_load_mb', 'rss_peak_mb']) for (const k in res[side]) res[side][k] = Math.round(res[side][k]);
      results.push(res);
      console.log(JSON.stringify(res));
      fs.writeFileSync('board-memory.json', JSON.stringify(results, null, 2));
      await page.close().catch(() => {});
    }
    await browser.close();
  }
  fs.writeFileSync('board-memory.json', JSON.stringify(results, null, 2));
})().catch((e) => { console.error(String(e.message || e)); process.exit(1); });
