#!/bin/bash
# Regenerates the README screenshots in docs/ from sample data.
# Runs a separate copy of the app against a throwaway data folder, a fake hosts file and
# DNS port 5399, so it never touches this Mac's real settings or your own stats.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d build/Ad-Owl.app ] || ./scripts/build-app.sh
BIN="build/Ad-Owl.app/Contents/MacOS/Ad-Owl"
REAL="$HOME/Library/Application Support/HostShield"
DEMO="$(mktemp -d)"
mkdir -p docs "$DEMO/cache"
cp -p "$REAL"/cache/* "$DEMO/cache/" 2>/dev/null || true   # downloaded filter lists (keeps their dates), so counts are realistic
python3 scripts/sample-data.py "$DEMO"

shot() {   # shot <section> <file>
  rm -f "$DEMO/.running"
  HOSTSHIELD_HOME="$DEMO" HOSTSHIELD_SKIP_NETWORK=1 HOSTSHIELD_DNS_PORT=5399 HOSTSHIELD_HOSTS="$DEMO/hosts" \
    ADOWL_SECTION="$1" ADOWL_SNAPSHOT="$PWD/docs/$2" "$BIN" >/dev/null 2>&1 &
  sleep 2.5
  # A little live traffic for the query feed.
  for d in www.apple.com securepubads.g.doubleclick.net github.com www.google-analytics.com \
           api.github.com pagead2.googlesyndication.com en.wikipedia.org ib.adnxs.com \
           static.criteo.net www.youtube.com sb.scorecardresearch.com cdn.jsdelivr.net; do
    dig @127.0.0.1 -p 5399 +short +time=1 +tries=1 "$d" >/dev/null 2>&1 || true
  done
  wait
  echo "docs/$2"
}
shot "Protection" protection.png
shot "Traffic" traffic.png
shot "Filters" filters.png
rm -rf "$DEMO"
