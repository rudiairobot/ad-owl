import { siteOf, hostOf } from './shared.js';

const $ = id => document.getElementById(id);
const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
const pageUrl = tab?.url || '';
const site = /^https?:/.test(pageUrl) ? siteOf(hostOf(pageUrl)) : '';

async function render() {
  const key = `tab:${tab?.id}`;
  const [{ [key]: entry }, { allow = [], total = 0 }] =
    await Promise.all([chrome.storage.session.get(key), chrome.storage.local.get(['allow', 'total'])]);

  $('site').textContent = site || 'This page can’t open pop-ups';
  $('count').textContent = entry?.count ?? 0;
  $('countLabel').textContent = (entry?.count === 1) ? 'pop-up blocked on this page' : 'pop-ups blocked on this page';
  $('total').textContent = total.toLocaleString();

  const items = entry?.items ?? [];
  $('listCard').hidden = items.length === 0;
  $('list').replaceChildren(...items.map(({ url }) => {
    const li = document.createElement('li');
    const span = document.createElement('span');
    span.textContent = url;
    span.title = url;
    const open = document.createElement('button');
    open.textContent = 'Open';
    open.title = 'Open this pop-up in a new tab';
    open.onclick = () => chrome.tabs.create({ url, openerTabId: tab.id });
    li.append(span, open);
    return li;
  }));

  $('allow').checked = allow.includes(site);
  $('allow').disabled = !site;
  $('allowRow').classList.toggle('disabled', !site);
  $('allowRow').querySelector('strong').textContent = site ? `Allow pop-ups on ${site}` : 'Allow pop-ups on this site';

  $('allowedCount').textContent = allow.length;
  $('allowedList').replaceChildren(...allow.map(s => {
    const li = document.createElement('li');
    const span = document.createElement('span');
    span.textContent = s;
    const remove = document.createElement('button');
    remove.textContent = 'Remove';
    remove.onclick = () => setAllowed(s, false);
    li.append(span, remove);
    return li;
  }));
}

async function setAllowed(s, on) {
  const { allow = [] } = await chrome.storage.local.get('allow');
  const next = on ? [...new Set([...allow, s])].sort() : allow.filter(x => x !== s);
  await chrome.storage.local.set({ allow: next });
  render();
}

$('allow').addEventListener('change', e => setAllowed(site, e.target.checked));
render();
