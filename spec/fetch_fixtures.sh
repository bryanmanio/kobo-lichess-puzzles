#!/bin/sh
# Refreshes spec/fixtures/puzzles.lua from live lichess puzzles.
#
# The puzzle batch endpoint serves anonymous callers, so no token is needed.
# Anonymous callers get a limited pool, which is fine: the point is to parse
# real payloads, not to enumerate puzzles. Never use this to bulk download;
# lichess publishes a full puzzle database for that.
set -e
cd "$(dirname "$0")/.."

raw=$(mktemp)
for angle in mix endgame opening middlegame advancedPawn; do
    curl -s "https://lichess.org/api/puzzle/batch/$angle?nb=50" >> "$raw"
    printf '\n' >> "$raw"
    sleep 1
done

python3 - "$raw" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
dec, i, pz = json.JSONDecoder(), 0, []
while i < len(text):
    while i < len(text) and text[i] != '{':
        i += 1
    if i >= len(text):
        break
    try:
        obj, end = dec.raw_decode(text, i)
        pz.extend(obj.get('puzzles', []))
        i = end
    except json.JSONDecodeError:
        i += 1   # skip non-JSON responses, e.g. an unknown angle returning HTML

seen = {e['puzzle']['id']: e for e in pz}
pz = sorted(seen.values(), key=lambda e: e['puzzle']['id'])

def q(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

out = ["-- Generated from live lichess puzzles by spec/fetch_fixtures.sh. Do not edit by hand.",
       "return {"]
for e in pz:
    p, g = e['puzzle'], e['game']
    out.append("  { id = %s, initialPly = %d, rating = %d, pgn = %s, solution = { %s } },"
               % (q(p['id']), p['initialPly'], p.get('rating', 0), q(g['pgn']),
                  ", ".join(q(m) for m in p['solution'])))
out.append("}")
open('spec/fixtures/puzzles.lua', 'w').write("\n".join(out) + "\n")
print("wrote %d puzzles to spec/fixtures/puzzles.lua" % len(pz))
PY
rm -f "$raw"
