#!/usr/bin/env python3
"""Writes appcast.json, the small public file CueLevel reads to learn about new versions.
Usage: make-appcast.py <dmg> <version> <build> <download-url> <notes-file> <out-json>"""
import hashlib, json, os, sys, datetime
dmg, version, build, url, notes_file, out = sys.argv[1:7]
digest = hashlib.sha256()
with open(dmg, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""): digest.update(chunk)
notes = open(notes_file, encoding="utf-8").read().strip() if os.path.exists(notes_file) else ""
feed = {
    "schema": 1,
    "version": version,
    "build": int(build),
    "minimumSystemVersion": "13.0",
    "published": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "url": url,
    "sha256": digest.hexdigest(),
    "size": os.path.getsize(dmg),
    "teamID": "327ABFB3W2",
    "notes": notes,
}
with open(out, "w", encoding="utf-8") as f: json.dump(feed, f, indent=2, ensure_ascii=False); f.write("\n")
print(json.dumps(feed, indent=2, ensure_ascii=False))
