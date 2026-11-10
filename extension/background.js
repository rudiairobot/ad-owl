// Decides, for every new tab or window a page opens, whether the user actually asked for it.
//
// Allowed:  the user clicked (or middle-clicked, or right-clicked "Open in New Tab") a visible
//           link to exactly that address, submitted a form to it, or clicked something on a
//           page that opens another page of the same site. Sites on the allow list are never touched.
// Blocked:  everything else: window.open() from scripts or iframes, faked clicks, page-wide
//           click hijacks, hidden or full-page links, and anything opened with no click at all.
import { siteOf, hostOf, sameSite, strip } from './shared.js';

const CLICK_MS = 1000;     // how long a click can "explain" a new tab
const MENU_MS = 15000;     // a right-click menu stays open while the user picks an item
const GRACE_MS = 150;      // the click message can arrive just after the new tab does

const gestures = new Map();   // tabId -> last trusted gesture { kind, href?, form?, t }

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (msg.type === 'gesture' && sender.tab) gestures.set(sender.tab.id, { ...msg, t: Date.now() });
});

const seen = new Set();   // new tabs already judged, so the two signals below never double up

// Main signal: a page (or one of its frames) opened a new tab or window.
chrome.webNavigation.onCreatedNavigationTarget.addListener(d =>
  consider({ sourceTabId: d.sourceTabId, tabId: d.tabId, url: d.url }));

// Backup signal: some tricks (window.open borrowed from a javascript: iframe) never fire the
// event above, but the new tab still records which tab opened it.
chrome.tabs.onCreated.addListener(tab => {
  if (tab.openerTabId == null) return;                 // Cmd-T, bookmarks, other apps
  setTimeout(() => consider({ sourceTabId: tab.openerTabId, tabId: tab.id, url: tab.pendingUrl || tab.url || '' }), 100);
});

async function consider(d) {
  if (seen.has(d.tabId)) return;
  seen.add(d.tabId);
  setTimeout(() => seen.delete(d.tabId), 60000);
  const source = await tabUrl(d.sourceTabId);
  if (!source || !/^https?:/.test(source)) return;     // opened by the browser or another extension
  const { allow = [] } = await chrome.storage.local.get('allow');
  if (allow.includes(siteOf(hostOf(source)))) return;

  let verdict = judge(d, source);
  if (verdict === 'unknown') {
    await new Promise(r => setTimeout(r, GRACE_MS));
    verdict = judge(d, source);
  }
  if (verdict !== 'allow') await block(d, source);
}

function judge(d, source) {
  const g = gestures.get(d.sourceTabId);
  if (!g || Date.now() - g.t > (g.kind === 'menu' ? MENU_MS : CLICK_MS)) return 'unknown';
  if (g.href && strip(g.href) === strip(d.url)) return 'allow';
  if (g.form && sameDocument(g.form, d.url)) return 'allow';
  if (g.kind === 'click' && sameSite(source, d.url)) return 'allow';
  return 'block';
}

function sameDocument(a, b) {
  try { const x = new URL(a), y = new URL(b); return x.origin === y.origin && x.pathname === y.pathname; }
  catch { return false; }
}

async function tabUrl(id) {
  try { const t = await chrome.tabs.get(id); return t.url || t.pendingUrl || ''; } catch { return ''; }
}

// Storage writes are chained so two pop-ups blocked at once can't lose a count.
let queue = Promise.resolve();
function block(d, source) {
  chrome.tabs.remove(d.tabId).catch(() => {});
  queue = queue.then(async () => {
    const key = `tab:${d.sourceTabId}`;
    const { [key]: entry = { page: strip(source), count: 0, items: [] } } = await chrome.storage.session.get(key);
    entry.count += 1;
    entry.items = [{ url: d.url, t: Date.now() }, ...entry.items].slice(0, 20);
    const { total = 0 } = await chrome.storage.local.get('total');
    await chrome.storage.session.set({ [key]: entry });
    await chrome.storage.local.set({ total: total + 1 });
    await chrome.action.setBadgeText({ tabId: d.sourceTabId, text: String(entry.count) });
  }).catch(() => {});
  return queue;
}

// A new page in the tab starts a fresh count.
chrome.webNavigation.onCommitted.addListener(d => {
  if (d.frameId !== 0) return;
  queue = queue.then(async () => {
    const key = `tab:${d.tabId}`;
    const { [key]: entry } = await chrome.storage.session.get(key);
    if (entry && entry.page !== strip(d.url)) {
      await chrome.storage.session.remove(key);
      await chrome.action.setBadgeText({ tabId: d.tabId, text: '' });
    }
  }).catch(() => {});
});

chrome.tabs.onRemoved.addListener(id => {
  gestures.delete(id);
  chrome.storage.session.remove(`tab:${id}`);
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.action.setBadgeBackgroundColor({ color: '#D63AF9' });
  chrome.action.setBadgeTextColor?.({ color: '#FFFFFF' });
});
