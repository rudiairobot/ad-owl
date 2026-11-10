// Drives a throwaway Brave (or Chrome for Testing) profile over the DevTools protocol and checks
// which pop-up tricks the extension stops. Real mouse events are sent, so pages see trusted clicks.
//
//   node extension/test/run.mjs            # with the extension
//   node extension/test/run.mjs --without  # browser's own blocker only, for comparison
//   BROWSER=/path/to/chrome node extension/test/run.mjs
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const EXT = join(here, '..');
const BROWSER = process.env.BROWSER || '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser';
const WITHOUT = process.argv.includes('--without');
const PORT = 9333, SITE = 'http://127.0.0.1:8765/';
const sleep = ms => new Promise(r => setTimeout(r, ms));

// --- test page server -------------------------------------------------------------------------
const server = spawn('python3', ['-m', 'http.server', '8765', '--bind', '127.0.0.1', '--directory', join(here, 'site')],
                     { stdio: 'ignore' });

// --- browser ----------------------------------------------------------------------------------
const profile = mkdtempSync(join(tmpdir(), 'adowl-test-'));
const args = [`--user-data-dir=${profile}`, `--remote-debugging-port=${PORT}`, '--no-first-run',
  '--no-default-browser-check', '--headless=new', '--window-size=1200,900',
  '--disable-features=DisableLoadExtensionCommandLineSwitch'];
if (!WITHOUT) args.push(`--load-extension=${EXT}`, `--disable-extensions-except=${EXT}`);
const browser = spawn(BROWSER, [...args, 'about:blank'], { stdio: 'ignore' });
process.on('exit', () => { browser.kill(); server.kill(); rmSync(profile, { recursive: true, force: true }); });
process.on('uncaughtException', e => { console.error(e.message); process.exit(1); });

let wsUrl;
for (let i = 0; i < 50 && !wsUrl; i++) {
  await sleep(200);
  try { wsUrl = (await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json()).webSocketDebuggerUrl; } catch {}
}
if (!wsUrl) throw new Error('browser did not start');

// --- minimal CDP client -----------------------------------------------------------------------
const ws = new WebSocket(wsUrl);
await new Promise(r => ws.addEventListener('open', r, { once: true }));
let nextId = 1;
const pending = new Map();
ws.addEventListener('message', ev => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) {
    const { resolve, reject } = pending.get(m.id); pending.delete(m.id);
    m.error ? reject(new Error(m.error.message)) : resolve(m.result);
  }
});
const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const id = nextId++;
  pending.set(id, { resolve, reject });
  ws.send(JSON.stringify({ id, method, params, sessionId }));
});

async function targets() { return (await send('Target.getTargets')).targetInfos; }

if (!WITHOUT) {
  let worker;
  for (let i = 0; i < 25 && !worker; i++) {
    worker = (await targets()).find(t => t.type === 'service_worker' && t.url.endsWith('/background.js'));
    if (!worker) await sleep(200);
  }
  if (!worker) throw new Error('extension did not load');
}

async function evalInWorker(expr) {
  const worker = (await targets()).find(t => t.type === 'service_worker' && t.url.endsWith('/background.js'));
  const { sessionId } = await send('Target.attachToTarget', { targetId: worker.targetId, flatten: true });
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }, sessionId);
  await send('Target.detachFromTarget', { sessionId });
  return r.result.value;
}

// --- page helpers -----------------------------------------------------------------------------
const { targetId: pageId } = await send('Target.createTarget', { url: SITE });
const { sessionId: page } = await send('Target.attachToTarget', { targetId: pageId, flatten: true });
await send('Page.enable', {}, page);
await send('Runtime.enable', {}, page);

async function reload() {
  await send('Page.navigate', { url: SITE }, page);
  await sleep(700);
}

async function centerOf(selector) {
  const r = await send('Runtime.evaluate', {
    expression: `(() => { const b = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();
                         return [b.left + b.width / 2, b.top + b.height / 2]; })()`, returnByValue: true }, page);
  return r.result.value;
}

async function click(selector, button = 'left') {
  const [x, y] = await centerOf(selector);
  for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased'])
    await send('Input.dispatchMouseEvent', { type, x, y, button: type === 'mouseMoved' ? 'none' : button, clickCount: 1 }, page);
}

/** Runs a step and reports which new pages are still open afterwards, then closes them. */
async function opened(step) {
  const before = new Set((await targets()).map(t => t.targetId));
  await step();
  await sleep(1000);
  const fresh = (await targets()).filter(t => t.type === 'page' && !before.has(t.targetId));
  for (const t of fresh) await send('Target.closeTarget', { targetId: t.targetId }).catch(() => {});
  return fresh.map(t => t.url);
}

// --- cases ------------------------------------------------------------------------------------
const cases = [
  // [name, expected, step]
  ['Real link, target=_blank', 'opens', () => click('#link')],
  ['Middle-click on a link', 'opens', () => click('#link2', 'middle')],
  ['Real form submit to new tab', 'opens', () => click('#formReal')],
  ['Same-site window.open on click', 'opens', () => click('#sameSite')],
  ['window.open to another site', 'blocked', () => click('#btnCross')],
  ['Page-wide click hijack', 'blocked', () => click('#hijackText')],
  ['Faked click on hidden link', 'blocked', () => click('#synthetic')],
  ['window.open from fresh iframe', 'blocked', () => click('#iframeOpen')],
  ['Invisible full-page link', 'blocked', async () => { await click('#armOverlay'); await sleep(100); await click('body') }],
  ['Script submits hidden form', 'blocked', () => click('#formScript')],
  ['window.open 300 ms after click', 'blocked', () => click('#delayed')],
];

await reload();
let pass = 0;
console.log(WITHOUT ? 'Browser only (no extension):' : 'With Ad-Owl Pop-up Blocker:');
for (const [name, expected, step] of cases) {
  const urls = await opened(step);
  const got = urls.length ? 'opens' : 'blocked';
  const ok = got === expected;
  if (ok) pass++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name.padEnd(34)} expected ${expected.padEnd(8)} got ${got}${urls.length ? '  ' + urls.join(' ') : ''}`);
}
console.log(`${pass}/${cases.length} as expected`);

if (!WITHOUT) {
  const blocked = await evalInWorker(`chrome.storage.local.get('total').then(x => x.total)`);
  console.log(`Extension counted ${blocked} blocked`);
  await evalInWorker(`chrome.storage.local.set({ allow: ['127.0.0.1'] })`);
  const urls = await opened(() => click('#btnCross'));
  console.log(`${urls.length ? 'PASS' : 'FAIL'}  Allow-listed site can open pop-ups      got ${urls.length ? 'opens' : 'blocked'}`);
  await evalInWorker(`chrome.storage.local.set({ allow: [] })`);
}

if (process.env.EXTRA_URL) {   // optional: click every test control on an external page (webbrowsertools.com)
  const SELECTOR = process.env.EXTRA_SELECTOR || 'input[type=button], a[href*="example.com/test"], #method20, #method23';
  const fresh = async () => { await send('Page.navigate', { url: process.env.EXTRA_URL }, page); await sleep(2500); };
  const list = async () => (await send('Runtime.evaluate', { returnByValue: true, expression:
    `[...document.querySelectorAll(${JSON.stringify(SELECTOR)})].map(e => {
        const sec = e.closest('section, fieldset, div[id], li')?.querySelector('h2, h3, legend, b')?.innerText || '';
        return ((sec ? sec.trim().slice(0, 40) + ' › ' : '') + (e.value || e.innerText || e.id).trim()).slice(0, 70); })` }, page)).result.value;
  await fresh();
  const labels = await list();
  let opens = 0;
  for (let i = 0; i < labels.length; i++) {
    await fresh();          // some tests navigate or rewrite the page, so start each one clean
    await send('Runtime.evaluate', { expression:
      `(e => { e.dataset.adowlTest = 'x'; e.scrollIntoView({ block: 'center' }); })(document.querySelectorAll(${JSON.stringify(SELECTOR)})[${i}])` }, page);
    await sleep(150);
    let urls = [];
    try { urls = await opened(() => click('[data-adowl-test="x"]')); } catch {}
    if (urls.length) opens++;
    console.log(`${urls.length ? 'OPENED ' : 'blocked'}  ${labels[i]}${urls.length ? '  -> ' + urls[0].slice(0, 60) : ''}`);
  }
  console.log(`External page: ${labels.length} tests clicked, ${opens} opened a new tab or window`);
}

ws.close();
browser.kill();
server.kill();
await sleep(500);
rmSync(profile, { recursive: true, force: true });
process.exit(0);
