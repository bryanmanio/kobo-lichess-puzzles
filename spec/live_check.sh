#!/bin/sh
# Verifies a real lichess token against the live API.
#
# The stubbed suites cannot cover the submission path, because it needs a real
# token and really does change your rating. This script checks it deliberately.
#
# Usage:
#   ./spec/live_check.sh <token>            read-only checks
#   ./spec/live_check.sh <token> --submit   also submit ONE casual result
#
# --submit sends rated=false, so lichess records the puzzle as seen but your
# rating is left alone. Nothing is submitted without that flag.
set -e

TOKEN="$1"
if [ -z "$TOKEN" ]; then
    echo "usage: $0 <token> [--submit]" >&2
    exit 2
fi
AUTH="Authorization: Bearer $TOKEN"
API="https://lichess.org"

echo "== 1. Token and account =="
account=$(curl -s -H "$AUTH" "$API/api/account")
echo "$account" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("  could not parse the response; is the token correct?"); sys.exit(1)
if d.get("error"):
    print("  error:", d["error"]); sys.exit(1)
rating = (d.get("perfs", {}).get("puzzle", {}) or {}).get("rating")
print("  signed in as:", d.get("username"))
print("  puzzle rating:", rating)
'

echo
echo "== 2. Authenticated puzzle fetch (needs puzzle:read) =="
batch=$(curl -s -H "$AUTH" "$API/api/puzzle/batch/mix?nb=2&difficulty=normal")
puzzle_id=$(echo "$batch" | python3 -c '
import json, sys
d = json.load(sys.stdin)
pz = d.get("puzzles", [])
if not pz:
    print("  no puzzles returned:", str(d)[:200], file=sys.stderr); sys.exit(1)
print("  received %d puzzles" % len(pz), file=sys.stderr)
for e in pz:
    p, g = e["puzzle"], e["game"]
    plies = len(g["pgn"].split())
    ok = "ok" if plies == p["initialPly"] + 1 else "MISMATCH"
    print("    %s rating=%s plies=%d initialPly=%d %s"
          % (p["id"], p.get("rating"), plies, p["initialPly"], ok), file=sys.stderr)
print(pz[0]["puzzle"]["id"])
')

if [ "$2" != "--submit" ]; then
    echo
    echo "Read-only checks passed. Re-run with --submit to verify the"
    echo "submission path (sends one casual result, rating unaffected)."
    exit 0
fi

echo
echo "== 3. Submission (needs puzzle:write) =="
echo "  submitting puzzle $puzzle_id as a casual loss (rated=false)"
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"solutions\":[{\"id\":\"$puzzle_id\",\"win\":false,\"rated\":false}]}" \
    "$API/api/puzzle/batch/mix?nb=1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("error"):
    print("  error:", d["error"]); sys.exit(1)
rounds = d.get("rounds", [])
print("  rounds returned:", len(rounds))
for r in rounds:
    print("    %s win=%s ratingDiff=%s" % (r.get("id"), r.get("win"), r.get("ratingDiff")))
print("  refilled puzzles:", len(d.get("puzzles", [])))
print("  glicko:", d.get("glicko"))
print("\n  Submission path works.")
'
