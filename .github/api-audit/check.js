// 2026-11-24 — signed-in, READ-ONLY check of every main iOS screen's API calls against the live API, as the fixed
// test account (claude-urltest, demo project «Alpenbahn – Sommerkampagne»). Only GET requests; no write ever.
// Per screen: HTTP status, time, and whether the fields the app's models require are present (non-null).
// Also: the same calls without a token → must be 401. The token / ticket are never printed.
const { chromium } = require('playwright');
const fs = require('fs');

const API = 'https://subshot.ch';
const P = 'c15ead5c-1d16-4f9b-ac97-547fb244e7a4';

// required (non-optional in the Swift models) fields per response
const REQ = {
  project: ['id', 'name', 'sections', 'scenes', 'shots', 'module_concept', 'module_scripting', 'module_postproduction'],
  section: ['id', 'project_id', 'name', 'sort_order', 'has_project_info', 'todo_lists', 'in_postproduction', 'timecode_offset_seconds', 'reference_videos'],
  idea: ['id', 'project_id', 'title', 'text', 'status', 'sort_order', 'created_at'],
  video: ['id', 'section_id', 'title', 'sort_order', 'created_at', 'versions'],
  version: ['id', 'video_id', 'version_number', 'status', 'created_at'],
  member: ['user_id', 'email', 'role'],
};

let page;
async function token() {
  return page.evaluate(async () => (window.Clerk && window.Clerk.session ? await window.Clerk.session.getToken() : null));
}
async function get(path, auth = true) {
  const t0 = Date.now();
  const headers = auth ? { Authorization: 'Bearer ' + (await token()) } : {};
  const r = await fetch(API + '/' + path, { headers });
  const ms = Date.now() - t0;
  let body = null;
  try { body = await r.json(); } catch { /* not json */ }
  return { status: r.status, ms, body };
}
function missing(obj, keys) {
  if (!obj || typeof obj !== 'object') return keys;
  return keys.filter((k) => !(k in obj) || obj[k] === null);
}

(async () => {
  const secret = process.env.DEBUG_TICKET_SECRET || '';
  if (!secret) throw new Error('DEBUG_TICKET_SECRET missing');
  const tr = await fetch(API + '/debug/test-ticket', { method: 'POST', headers: { 'X-Debug-Secret': secret } });
  if (tr.status !== 200) throw new Error('ticket ' + tr.status);
  const { ticket } = await tr.json();
  const browser = await chromium.launch();
  page = await (await browser.newContext()).newPage();
  await page.goto(`https://app.subshot.ch/embed/auth?ticket=${encodeURIComponent(ticket)}&next=/embed/warm`);
  await page.waitForURL((u) => u.pathname.startsWith('/embed/warm'), { timeout: 60000 });
  await page.waitForFunction(() => window.Clerk && window.Clerk.session, null, { timeout: 30000 });

  const out = [];
  const add = (screen, path, res, issues = []) => {
    out.push({ screen, path: path.replace(P, ':project').replace(/[0-9a-f]{8}-[0-9a-f-]{27}/g, ':id'), status: res.status, ms: res.ms, issues });
  };

  // Projekte
  for (const p of ['me', 'projects', 'folders', 'me/notifications?unread_only=false', 'me/todo-sidebar', 'me/known-collaborators']) add('Projekte', p, await get(p));
  // Projekt-Detail (Konzept / Shotlist / On-Set)
  const det = await get(`projects/${P}`);
  const dIssues = missing(det.body, REQ.project).map((k) => 'project.' + k);
  for (const s of (det.body?.sections || [])) dIssues.push(...missing(s, REQ.section).map((k) => `section.${k}`));
  add('Shotlist/Konzept (Detail)', `projects/${P}`, det, [...new Set(dIssues)]);
  const ideas = await get(`projects/${P}/ideas`);
  const iIssues = [];
  for (const i of (Array.isArray(ideas.body) ? ideas.body : [])) iIssues.push(...missing(i, REQ.idea).map((k) => 'idea.' + k));
  add('Konzept', `projects/${P}/ideas`, ideas, [...new Set(iIssues)]);
  const firstIdea = Array.isArray(ideas.body) && ideas.body[0] ? ideas.body[0].id : null;
  if (firstIdea) {
    add('Konzept', `ideas/${firstIdea}/feedback`, await get(`ideas/${firstIdea}/feedback`));
    add('Board-Embed (API)', `ideas/${firstIdea}/board`, await get(`ideas/${firstIdea}/board`));
  }
  for (const p of [`projects/${P}/members`, `projects/${P}/annotations`, `projects/${P}/info-members`, `projects/${P}/scene-weather`, `projects/${P}/live-schedule`, `projects/${P}/callsheet/days`]) {
    const r = await get(p);
    const issues = p.endsWith('/members') && Array.isArray(r.body) ? [...new Set(r.body.flatMap((m) => missing(m, REQ.member).map((k) => 'member.' + k)))] : [];
    add(p.includes('callsheet') || p.includes('live-schedule') || p.includes('weather') ? 'On-Set/Planung' : 'Shotlist', p, r, issues);
  }
  const firstSection = det.body?.sections?.[0]?.id;
  if (firstSection) add('On-Set/Timecode', `sections/${firstSection}/markers`, await get(`sections/${firstSection}/markers`));
  // Postpro
  const vids = await get(`projects/${P}/videos`);
  const vIssues = [];
  for (const v of (Array.isArray(vids.body) ? vids.body : [])) {
    vIssues.push(...missing(v, REQ.video).map((k) => 'video.' + k));
    for (const x of v.versions || []) vIssues.push(...missing(x, REQ.version).map((k) => 'version.' + k));
  }
  add('Postpro', `projects/${P}/videos`, vids, [...new Set(vIssues)]);
  for (const p of [`projects/${P}/languages`, `projects/${P}/video-extras`, `projects/${P}/video-qc?target=-14`, `projects/${P}/feedback-rounds`]) add('Postpro', p, await get(p));
  // Deliver (web page; the app has no own screen) — the API the web uses
  for (const p of [`projects/${P}/deliver`, `projects/${P}/deliver-settings`]) add('Deliver (Web)', p, await get(p));
  // Board embed page itself (signed in)
  if (firstIdea) {
    const t0 = Date.now();
    const resp = await page.goto(`https://app.subshot.ch/embed/idea/${P}/${firstIdea}?media=still`);
    out.push({ screen: 'Board-Embed (Seite)', path: '/embed/idea/:project/:id?media=still', status: resp ? resp.status() : 0, ms: Date.now() - t0, issues: page.url().includes('/sign-in') ? ['redirected to sign-in'] : [] });
  }
  // Einstellungen
  add('Einstellungen', 'me', await get('me'));
  // 401 without token (same calls)
  for (const p of ['me', 'projects', `projects/${P}`, `projects/${P}/videos`, `projects/${P}/ideas`]) {
    const r = await get(p, false);
    out.push({ screen: 'ohne Token', path: p.replace(P, ':project'), status: r.status, ms: r.ms, issues: r.status === 401 ? [] : ['expected 401'] });
  }
  await browser.close();
  fs.writeFileSync('api-audit.json', JSON.stringify(out, null, 2));
  for (const o of out) console.log(`${o.screen.padEnd(26)} ${String(o.status).padEnd(4)} ${String(o.ms).padStart(5)} ms  ${o.path}${o.issues.length ? '  ISSUES: ' + o.issues.join(',') : ''}`);
})().catch((e) => { console.error(String(e.message || e)); process.exit(1); });
