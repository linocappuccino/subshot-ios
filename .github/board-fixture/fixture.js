// 2026-11-18 (board memory, iOS) — synthetic test boards in the TEST account's demo project, never customer data.
// create: three ideas «Speichertest 12/40/100» with generated media (see make_media.sh):
//   12  = replica of the crashing board's structure: 2 groups of 6 videos (432×768 nodes, 1080×1920 H.264,
//         10 × 2.5 Mbit/s + 2 × 15 Mbit/s originals) + a vote group with 8 text cards
//   40  = 16 videos + 20 photos (4000×3000) + 4 GIFs
//   100 = 30 videos + 60 photos + 10 GIFs
// delete: removes every idea whose title starts with «Speichertest» (the server deletes its R2 files with it).
// Sign-in: one-time ticket for the test account (CI secret), the Clerk session token comes from the page.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const API = 'https://subshot.ch';
const PROJECT = 'c15ead5c-1d16-4f9b-ac97-547fb244e7a4';
const PREFIX = 'Speichertest';
const MEDIA = process.env.MEDIA_DIR || 'media';

let page;
async function token() {
  return page.evaluate(async () => (window.Clerk && window.Clerk.session ? await window.Clerk.session.getToken() : null));
}
async function call(method, p, body) {
  const t = await token();
  if (!t) throw new Error('no session token');
  const r = await fetch(API + p, {
    method,
    headers: { Authorization: 'Bearer ' + t, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`${method} ${p.replace(/[0-9a-f-]{36}/g, ':id')} → ${r.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

let n = 0;
const id = () => (Date.now().toString(16) + (n++).toString(16).padStart(4, '0')).slice(-16).padStart(16, 'a');

async function upload(ideaId, file, mime) {
  const size = fs.statSync(file).size;
  const t = await call('POST', `/ideas/${ideaId}/board/uploads`, { filename: path.basename(file), content_type: mime, size });
  const put = await fetch(t.upload_url, { method: 'PUT', headers: { 'Content-Type': mime }, body: fs.readFileSync(file) });
  if (!put.ok) throw new Error('R2 PUT ' + put.status);
  return { key: t.key, size };
}

function mimeOf(f) {
  return f.endsWith('.mp4') ? 'video/mp4' : f.endsWith('.gif') ? 'image/gif' : 'image/jpeg';
}

async function board(title, files, layout) {
  const idea = await call('POST', `/projects/${PROJECT}/ideas`, { title, text: 'Synthetischer Speichertest (CI), wird wieder gelöscht.', sort_order: 999 });
  const els = [];
  let bytes = 0;
  for (const f of files) {
    const mime = mimeOf(f);
    const u = await upload(idea.id, path.join(MEDIA, f), mime);
    bytes += u.size;
    els.push({ id: id(), type: mime.startsWith('video') ? 'video' : 'image', asset_key: u.key, mime, name: f });
  }
  const elements = layout(els);
  const cur = await call('GET', `/ideas/${idea.id}/board`);
  await call('PUT', `/ideas/${idea.id}/board`, { version: cur.version, data: { elements, connectors: [] } });
  return { id: idea.id, title, nodes: elements.length, media: els.length, upload_mb: +(bytes / 1e6).toFixed(1) };
}

// replica of the crashing board's geometry (positions / sizes only)
function gtaLayout(media) {
  const out = [];
  const g1 = { id: id(), type: 'group', title: 'GRUPPE A', x: 2136, y: -352, w: 1392, h: 1648, z: 2, children: [] };
  const g2 = { id: id(), type: 'group', title: 'GRUPPE B', x: 3624, y: -352, w: 1392, h: 1648, z: 8, children: [] };
  const cols = [0, 456, 912], rows = [-288, 504];
  media.forEach((m, i) => {
    const g = i < 6 ? g1 : g2;
    const k = i % 6;
    Object.assign(m, { x: g.x + 24 + cols[k % 3], y: rows[Math.floor(k / 3)], w: 432, h: 768, z: 3 + i });
    g.children.push(m.id);
  });
  const vote = { id: id(), type: 'group', vote: true, title: 'TEXT VARIANTEN', x: 3120, y: -976, w: 960, h: 543, z: 14, children: [] };
  const texts = [];
  for (let i = 0; i < 8; i++) {
    const t = { id: id(), type: 'text', color: 'default', html: `<p>Variante ${i + 1}</p><p>Testtext für den Speichertest.</p>`,
      x: 3144 + 312 * Math.floor(i / 2 % 3), y: -912 + 118 * (i % 2) + (i >= 6 ? 240 : 0), w: 288, h: 94, z: 15 + i };
    texts.push(t);
    vote.children.push(t.id);
  }
  out.push(g1, ...media.slice(0, 6), g2, ...media.slice(6), vote, ...texts);
  return out;
}

// grid: 6 per row, portrait videos 432×768, photos 600×450, GIFs 480×480
function gridLayout(media) {
  let x = 0, y = 0, rowH = 0, col = 0;
  media.forEach((m, i) => {
    const [w, h] = m.mime.startsWith('video') ? [432, 768] : m.mime === 'image/gif' ? [480, 480] : [600, 450];
    Object.assign(m, { x, y, w, h, z: i + 1 });
    x += w + 40;
    rowH = Math.max(rowH, h);
    if (++col === 6) { col = 0; x = 0; y += rowH + 40; rowH = 0; }
  });
  return media;
}

(async () => {
  const action = process.argv[2];
  const secret = process.env.DEBUG_TICKET_SECRET || '';
  if (!secret) throw new Error('DEBUG_TICKET_SECRET missing');
  const r = await fetch(API + '/debug/test-ticket', { method: 'POST', headers: { 'X-Debug-Secret': secret } });
  if (r.status !== 200) throw new Error('ticket ' + r.status);
  const { ticket } = await r.json();
  const browser = await chromium.launch();
  page = await (await browser.newContext()).newPage();
  await page.goto(`https://app.subshot.ch/embed/auth?ticket=${encodeURIComponent(ticket)}&next=/embed/warm`);
  await page.waitForURL((u) => u.pathname.startsWith('/embed/warm'), { timeout: 60000 });
  await page.waitForFunction(() => window.Clerk && window.Clerk.session, null, { timeout: 30000 });

  const ideas = await call('GET', `/projects/${PROJECT}/ideas`);
  const old = ideas.filter((i) => (i.title || '').startsWith(PREFIX));
  if (action === 'delete' || action === 'create') {
    for (const i of old) await call('DELETE', `/ideas/${i.id}`);
    console.log(`deleted ${old.length} old test idea(s)`);
  }
  if (action === 'create') {
    const ls = (re) => fs.readdirSync(MEDIA).filter((f) => re.test(f)).sort();
    const vWeb = ls(/^v25-/), vOrig = ls(/^v15-/), photos = ls(/^p-/), gifs = ls(/^g-/);
    const out = [];
    // 12: as on the crashing board, the 2 originals sit at positions 2 and 7
    const gta = [vWeb[0], vOrig[0], ...vWeb.slice(1, 5), vOrig[1], ...vWeb.slice(5, 10)];
    out.push(await board(`${PREFIX} 12`, gta, gtaLayout));
    out.push(await board(`${PREFIX} 40`, [...vWeb.slice(0, 16), ...photos.slice(0, 20), ...gifs.slice(0, 4)], gridLayout));
    out.push(await board(`${PREFIX} 100`, [...vWeb.slice(0, 30), ...photos.slice(0, 60), ...gifs.slice(0, 10)], gridLayout));
    fs.writeFileSync('fixture.json', JSON.stringify(out, null, 2));
    console.log(JSON.stringify(out, null, 2));
  }
  await browser.close();
})().catch((e) => { console.error(String(e.message || e)); process.exit(1); });
