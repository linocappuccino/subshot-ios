// 2026-11-24 — removes ONLY the three synthetic memory-test boards of the test account (created 2026-11-18 by the
// board-fixture workflow, run 44334351085) and proves their R2 media are gone. Safety:
//   • exact id + title match against the list from that run; anything else → abort, nothing deleted
//   • only DELETE /ideas/{id} (the idea + its board; the server deletes the board's R2 prefix with it) —
//     no project, no section, no post-production video is touched
//   • before: every media URL of the three boards (src / thumb / srcset / item); after: each one must answer 404
// Signed URLs are never printed (only counts and R2 error codes).
const { chromium } = require('playwright');
const fs = require('fs');

const API = 'https://subshot.ch';
const P = 'c15ead5c-1d16-4f9b-ac97-547fb244e7a4';
const EXPECTED = {
  'df5e018a-7afb-4ee7-9bb9-da08b53da388': 'Speichertest 12',
  'de384bb3-4ab6-4264-9106-8eca1f65d8d0': 'Speichertest 40',
  '61f61ef1-b3e9-4442-8047-df5b170dbdbb': 'Speichertest 100',
};
let page;
const log = [];
const say = (k, v) => { log.push({ step: k, ...v }); console.log(k.padEnd(40), JSON.stringify(v)); };
async function token() { return page.evaluate(async () => await window.Clerk.session.getToken()); }
async function api(method, path) {
  const r = await fetch(API + '/' + path, { method, headers: { Authorization: 'Bearer ' + (await token()) } });
  const text = await r.text();
  let json = null; try { json = text ? JSON.parse(text) : null; } catch { /* */ }
  return { status: r.status, json };
}
function mediaUrls(board) {
  const urls = new Set();
  const addSrcset = (s) => (s || '').split(',').map((p) => p.trim().split(/\s+/)[0]).filter(Boolean).forEach((u) => urls.add(u));
  for (const el of board?.data?.elements || []) {
    for (const k of ['src', 'thumb_src', 'image_src', 'image_thumb_src']) if (el[k]) urls.add(el[k]);
    addSrcset(el.srcset); addSrcset(el.image_srcset);
    for (const it of el.items || []) { if (it.src) urls.add(it.src); if (it.thumb_src) urls.add(it.thumb_src); addSrcset(it.srcset); }
  }
  return [...urls].filter((u) => /r2\.cloudflarestorage\.com/.test(u));
}
async function r2State(url) {
  // presigned GET URLs are signed for GET → 1-byte range request (a HEAD would not match the signature)
  const r = await fetch(url, { headers: { Range: 'bytes=0-0' } });
  const text = r.status >= 400 ? await r.text() : '';
  return { status: r.status, code: (text.match(/<Code>([^<]+)<\/Code>/) || [])[1] || null };
}

(async () => {
  const secret = process.env.DEBUG_TICKET_SECRET || '';
  const tr = await fetch(API + '/debug/test-ticket', { method: 'POST', headers: { 'X-Debug-Secret': secret } });
  if (tr.status !== 200) throw new Error('ticket ' + tr.status);
  const { ticket } = await tr.json();
  const browser = await chromium.launch();
  page = await (await browser.newContext()).newPage();
  await page.goto(`https://app.subshot.ch/embed/auth?ticket=${encodeURIComponent(ticket)}&next=/embed/warm`);
  await page.waitForURL((u) => u.pathname.startsWith('/embed/warm'), { timeout: 60000 });
  await page.waitForFunction(() => window.Clerk && window.Clerk.session, null, { timeout: 30000 });

  // 1) verify: exactly the three expected ideas, nothing else named «Speichertest»
  const ideas = await api('GET', `projects/${P}/ideas`);
  const found = (ideas.json || []).filter((i) => (i.title || '').startsWith('Speichertest'));
  const ok = found.length === 3 && found.every((i) => EXPECTED[i.id] === i.title);
  say('verify ids against 2026-11-18 list', { ideas_in_project: (ideas.json || []).length, speichertest_found: found.map((i) => `${i.title} ${i.id}`), match: ok });
  if (!ok) { say('ABORT', { reason: 'ids / titles do not match the list — nothing deleted' }); await browser.close(); fs.writeFileSync('board-cleanup.json', JSON.stringify(log, null, 2)); process.exit(1); }
  const videosBefore = await api('GET', `projects/${P}/videos`);

  // 2) collect every media URL before deleting
  const urlsById = {};
  for (const id of Object.keys(EXPECTED)) {
    const b = await api('GET', `ideas/${id}/board`);
    urlsById[id] = mediaUrls(b.json);
    const sample = urlsById[id][0] ? await r2State(urlsById[id][0]) : null;
    say(`before ${EXPECTED[id]}`, { board: b.status, r2_urls: urlsById[id].length, first_url_now: sample });
  }

  // 3) delete the three ideas
  for (const id of Object.keys(EXPECTED)) {
    const d = await api('DELETE', `ideas/${id}`);
    say(`delete ${EXPECTED[id]}`, { status: d.status });
  }

  // 4) prove: ideas gone, every R2 URL 404, project + post-production videos untouched
  for (const id of Object.keys(EXPECTED)) {
    const g = await api('GET', `ideas/${id}`);
    const states = [];
    for (const u of urlsById[id]) states.push(await r2State(u));
    const tally = states.reduce((m, s) => ((m[`${s.status}${s.code ? ' ' + s.code : ''}`] = (m[`${s.status}${s.code ? ' ' + s.code : ''}`] || 0) + 1), m), {});
    say(`after ${EXPECTED[id]}`, { idea_get: g.status, r2_checked: states.length, r2_results: tally });
  }
  const proj = await api('GET', `projects/${P}`);
  const videosAfter = await api('GET', `projects/${P}/videos`);
  say('project + videos untouched', { project: proj.status, videos_before: (videosBefore.json || []).length, videos_after: (videosAfter.json || []).length });
  await browser.close();
  fs.writeFileSync('board-cleanup.json', JSON.stringify(log, null, 2));
})().catch((e) => { console.error(String(e.message || e)); process.exit(1); });
