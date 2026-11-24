// 2026-11-24 — live check of the upload-size contract (API 7ec9b9b) with EXACTLY the app's flow and headers, as
// the test account, in its demo project (own temporary post-production section; projects are not created /
// deleted — Lino's rule 2026-11-23: only a person deletes projects). Afterwards the test video is deleted (server
// removes its R2 files and the then empty unplanned section) and the deletion is checked.
//   a) small file, correct size_bytes → PUT ok, complete ok, version visible
//   b) size_bytes 60 GB → 413 upload_too_large, decoded like the app (UploadLimitProblem.parse)
//   c) wrong Content-Length → R2 403
// No token / ticket / signed URL is ever printed.
const { chromium } = require('playwright');
const fs = require('fs');

const API = 'https://subshot.ch';
const P = 'c15ead5c-1d16-4f9b-ac97-547fb244e7a4';
let page;
const log = [];
const say = (k, v) => { log.push({ step: k, ...v }); console.log(k.padEnd(34), JSON.stringify(v)); };

async function token() { return page.evaluate(async () => await window.Clerk.session.getToken()); }
async function api(method, path, body) {
  const r = await fetch(API + '/' + path, {
    method, headers: { Authorization: 'Bearer ' + (await token()), ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  let json = null; try { json = text ? JSON.parse(text) : null; } catch { /* */ }
  return { status: r.status, json, text };
}
// the app's decoding (Subshot/Services/UploadLimit.swift UploadLimitProblem.parse)
function appParse(status, body) {
  if (status !== 413 || !body || typeof body !== 'object') return null;
  if (body.error === 'upload_too_large') return { kind: 'tooLarge', sizeBytes: body.size_bytes ?? null, maxBytes: body.max_bytes ?? null };
  if (body.error === 'storage_limit_reached') return { kind: 'storageFull', used: body.used_bytes ?? null, limit: body.limit_bytes ?? null, scope: body.scope ?? null };
  return null;
}
// the app's PUT (APIClient.uploadVideoFile): Content-Type + Content-Length = file size
async function put(url, buf, contentType, contentLength) {
  const r = await fetch(url, { method: 'PUT', headers: { 'Content-Type': contentType, 'Content-Length': String(contentLength) }, body: buf, duplex: 'half' });
  const text = await r.text();
  const code = (text.match(/<Code>([^<]+)<\/Code>/) || [])[1] || null;
  return { status: r.status, r2Code: code };
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

  const file = fs.readFileSync('test.mp4');
  const N = file.length;
  // setup like the app's multi-upload: unplanned post-production section + video
  const sec = await api('POST', `projects/${P}/sections`, { name: 'ZZ Upload-Test (CI, wird gelöscht)', sort_order: 9999, start_in_postproduction: true });
  say('setup section', { status: sec.status });
  const vid = await api('POST', `sections/${sec.json.id}/videos`, { title: 'ZZ Upload-Test (CI)', sort_order: 0 });
  say('setup video', { status: vid.status });
  const videoId = vid.json.id;
  let readyUrl = null;
  try {
    // a) correct size
    const va = await api('POST', `videos/${videoId}/versions`, { original_filename: 'test.mp4', content_type: 'video/mp4', size_bytes: N });
    say('a) create version (size_bytes=' + N + ')', { status: va.status, has_upload_url: !!va.json?.playback_url });
    const pa = await put(va.json.playback_url, file, 'video/mp4', N);
    say('a) R2 PUT exact length', pa);
    const ca = await api('POST', `video-versions/${va.json.id}/complete`, { file_size_bytes: N, duration_seconds: 2 });
    say('a) complete', { status: ca.status, version_status: ca.json?.status });
    const list = await api('GET', `sections/${sec.json.id}/videos`);
    const v = (list.json || []).find((x) => x.id === videoId);
    const ver = v?.versions?.find((x) => x.id === va.json.id);
    readyUrl = ver?.playback_url || null;
    say('a) version visible', { status: list.status, version_status: ver?.status, file_size_bytes: ver?.file_size_bytes });

    // b) 60 GB
    const vb = await api('POST', `videos/${videoId}/versions`, { original_filename: 'big.mp4', content_type: 'video/mp4', size_bytes: 60000000000 });
    say('b) create version 60 GB', { status: vb.status, body: vb.json, app_decodes_as: appParse(vb.status, vb.json) });

    // c) wrong Content-Length (announced N, sends N+1000)
    const vc = await api('POST', `videos/${videoId}/versions`, { original_filename: 'wrong.mp4', content_type: 'video/mp4', size_bytes: N });
    const bigger = Buffer.concat([file, Buffer.alloc(1000)]);
    const pc = await put(vc.json.playback_url, bigger, 'video/mp4', bigger.length);
    say('c) R2 PUT wrong length', pc);
  } finally {
    // cleanup: delete the test video (server: versions, R2 files, the empty unplanned section)
    const d = await api('DELETE', `videos/${videoId}`);
    say('cleanup delete video', { status: d.status });
    const after = await api('GET', `sections/${sec.json.id}/videos`);
    say('cleanup section gone?', { status: after.status });
    if (after.status === 200) { const ds = await api('DELETE', `sections/${sec.json.id}`); say('cleanup delete section', { status: ds.status }); }
    const vids = await api('GET', `projects/${P}/videos`);
    say('cleanup video gone from project', { gone: !(vids.json || []).some((x) => x.id === videoId) });
    if (readyUrl) {
      const r = await fetch(readyUrl);
      const text = await r.text();
      say('cleanup R2 file gone', { status: r.status, r2Code: (text.match(/<Code>([^<]+)<\/Code>/) || [])[1] || null });
    }
    await browser.close();
    fs.writeFileSync('upload-live.json', JSON.stringify(log, null, 2));
  }
})().catch((e) => { console.error(String(e.message || e)); process.exit(1); });
