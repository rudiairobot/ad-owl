// Reports real (trusted) user clicks to the background worker, so it can tell a link the
// user chose to open in a new tab from a pop-up the page opened on its own.
(() => {
  // A link covering most of the page, or one you can't see, is a click-hijack, not a link
  // the user meant to follow.
  function looksReal(a) {
    if (a instanceof HTMLAreaElement) return true;
    const r = a.getBoundingClientRect();
    if (r.width * r.height > 0.5 * innerWidth * innerHeight) return false;
    let opacity = 1;
    for (let el = a; el && el !== document.documentElement; el = el.parentElement) {
      const s = getComputedStyle(el);
      if (s.visibility === 'hidden' || s.display === 'none') return false;
      opacity *= parseFloat(s.opacity);
    }
    return opacity > 0.1;
  }

  function report(kind, e) {
    if (!e.isTrusted) return;                      // clicks faked by page scripts never count
    const first = e.composedPath ? e.composedPath()[0] : e.target;
    const node = first instanceof Element ? first : first && first.parentElement;
    const msg = { type: 'gesture', kind };
    const link = node && node.closest('a[href], area[href]');
    if (link) {
      if (looksReal(link)) msg.href = link.href;
    } else {
      const button = node && node.closest('button, input[type=submit], input[type=image]');
      const form = button && (button.form || button.closest('form'));
      // button.formAction falls back to the page's own URL, so only use it when it's set.
      if (form) msg.form = button.hasAttribute('formaction') ? button.formAction : form.action;
    }
    try { chrome.runtime.sendMessage(msg).catch(() => {}); } catch { /* extension was reloaded */ }
  }

  addEventListener('click', e => report('click', e), true);
  addEventListener('auxclick', e => report('click', e), true);      // middle-click
  addEventListener('contextmenu', e => report('menu', e), true);    // "Open Link in New Tab"
})();
