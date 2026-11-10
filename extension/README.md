# Ad-Owl Pop-up Blocker (browser extension)

Companion to the Ad-Owl Mac app. The app blocks ad, tracker and malware **domains** for every app on
your Mac; this extension stops what DNS can't see: **pop-ups, pop-unders and click-hijacking tabs**
that a page opens on its own.

## Install in Chrome or Brave

1. Download **`ad-owl-extension-chrome.zip`** from the
   [latest release](https://github.com/rudiairobot/ad-owl/releases/latest) and double-click it.
   That gives you an `ad-owl-extension` folder. Move it somewhere permanent (e.g. Documents),
   because the browser loads it from there every time.
2. Open `chrome://extensions` (Chrome) or `brave://extensions` (Brave).
3. Turn on **Developer mode** (top-right switch).
4. Click **Load unpacked** and choose the `ad-owl-extension` folder.
   (From a clone of this repo, choose the `extension` folder instead.)
5. Pin it: click the puzzle-piece icon in the toolbar, then the pin next to **Ad-Owl Pop-up Blocker**.

It stays installed when the browser restarts. After pulling a newer version, click the ↻ reload
icon on the extension's card in the extensions page.

Edge and Arc work the same way (`edge://extensions`, or Arc's Extensions menu).

## What it does

When a page opens a new tab or window, the extension checks whether you actually asked for it.

**Allowed**
- Links you click, middle-click, or open with right-click › Open Link in New Tab
- Forms you submit to a new tab
- A page opening another page of the **same site** when you click something
- Anything on sites you put on the allow list

**Blocked** (the tab is closed immediately and counted)
- `window.open()` from scripts, including ones borrowed from hidden or `javascript:` iframes
- Faked clicks on hidden links, script-submitted forms
- Page-wide click hijacks and invisible full-page links
- Pop-ups opened with a delay after your click, or with no click at all

The toolbar icon shows how many pop-ups were blocked on the current page. Click it to:
- see what was blocked and **Open** any of them anyway
- **Allow pop-ups on this site**, for sign-in ("Sign in with Google"), payment or chat windows
- manage the list of allowed sites

The extension keeps its settings and counts locally and sends nothing anywhere.

## Testing

`test/run.mjs` drives a throwaway Brave profile with real mouse clicks (your own profile is never
touched) against a local page of pop-up tricks:

```bash
node extension/test/run.mjs              # with the extension: 11/11 cases as expected
node extension/test/run.mjs --without    # Brave's own blocker alone, for comparison: 5/11
EXTRA_URL=https://webbrowsertools.com/popup-blocker/ node extension/test/run.mjs
```

On webbrowsertools.com's test page (47 controls) Brave alone lets 36 open; with the extension 6
open, all by design: 4 are real links you click (that page makes every link open in a new tab) and
2 open another page of the same site.

## Limits

- Only new tabs and windows are blocked. A page that redirects **itself** to an ad, or shows an
  in-page overlay, isn't a pop-up; Ad-Owl's DNS filter blocks the known ad networks behind those.
- Same-site pop-ups on a click are allowed on purpose, so a site's own help, print or share
  windows keep working.
- Firefox and Safari versions are planned.
