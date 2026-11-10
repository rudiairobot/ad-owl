// Helpers shared by the background worker and the toolbar popup.

/** "news.bbc.co.uk" -> "bbc.co.uk", "a.b.example.com" -> "example.com". Good enough for pop-up decisions. */
export function siteOf(host) {
  host = (host || '').toLowerCase().replace(/\.$/, '');
  if (!host.includes('.') || /^[\d.]+$/.test(host) || host.includes(':')) return host;
  const labels = host.split('.');
  if (labels.length <= 2) return host;
  const [sld, tld] = labels.slice(-2);
  const twoPartSuffix = tld.length === 2 && sld.length <= 3;   // co.uk, com.au, ac.jp …
  return labels.slice(twoPartSuffix ? -3 : -2).join('.');
}

export function hostOf(url) {
  try { return new URL(url).hostname; } catch { return ''; }
}

export function sameSite(a, b) {
  const x = siteOf(hostOf(a));
  return x !== '' && x === siteOf(hostOf(b));
}

/** URL without its #fragment, for comparing a clicked link with the tab it opened. */
export function strip(url) {
  try { const u = new URL(url); u.hash = ''; return u.href; } catch { return url || ''; }
}
