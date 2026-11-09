"""Writes a demo config.json and stats.json into the folder given, for README screenshots.
All numbers and domains are made up; nothing comes from a real Mac's traffic."""
import json, random, sys, time, datetime, os

home = sys.argv[1]
random.seed(7)

config = {
    "enabled": ["ads", "trackers", "malware", "cookieConsent", "distractions"],
    "allowlist": [], "customBlocks": [],
    "autoUpdate": False, "protectionEnabled": True, "method": "dns",
    "dnsFallback": True, "upstream": ["1.1.1.1", "9.9.9.9"], "dnsBackup": {},
}
json.dump(config, open(os.path.join(home, "config.json"), "w"))

now = time.time()
hour_now = int(now // 3600)
hours = {}
for h in range(hour_now - 23, hour_now + 1):
    local = datetime.datetime.fromtimestamp(h * 3600).hour
    busy = 1.0 if 8 <= local <= 23 else 0.15          # quiet overnight
    total = int(random.uniform(900, 2600) * busy)
    hours[str(h)] = [total, int(total * random.uniform(0.09, 0.16))]

top = {
    "securepubads.g.doubleclick.net": 412, "www.google-analytics.com": 377,
    "pagead2.googlesyndication.com": 254, "ib.adnxs.com": 198, "static.criteo.net": 163,
    "sb.scorecardresearch.com": 141, "connect.facebook.net": 122, "bat.bing.com": 97,
    "cdn.taboola.com": 84, "widgets.outbrain.com": 61, "cdn.cookielaw.org": 44,
}
start_of_day = datetime.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
stats = {"hours": hours, "top": top, "day": int(start_of_day // 86400)}
json.dump(stats, open(os.path.join(home, "stats.json"), "w"))
