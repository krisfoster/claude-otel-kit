#!/usr/bin/env bash
# Tests of the kit's argument validation. No sandboxes and no API calls.
# Part 1 needs only python3: it reads the viewerPort pattern out of kit/kit.yaml and checks it against
# every integer from 0 to 99999. Part 2 asks the real `sbx kit validate` about sample values; it is
# skipped (not failed) when sbx is not installed or cannot validate the kit at all.
set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
skip() { SKIP=$((SKIP + 1)); echo "  SKIP  $*"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
accepted() { sbx kit validate "$ROOT/kit" --kit-arg "$1" >/dev/null 2>&1; }
rejected() { ! sbx kit validate "$ROOT/kit" --kit-arg "$1" >/dev/null 2>&1; }

echo "== viewerPort pattern, exhaustively"
result="$(python3 - "$ROOT/kit/kit.yaml" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(text) if l.strip() == "viewerPort:")
line = next(l for l in text[start:] if l.strip().startswith("pattern:"))
pat = line.split("pattern:", 1)[1].strip()
assert pat[0] == pat[-1] == "'", "expected a single-quoted pattern"
pat = pat[1:-1]
wrong = [n for n in range(100000) if (re.fullmatch(pat, str(n)) is not None) != (1025 <= n <= 65535)]
odd = [s for s in ["", "00", "01025", "0443", "+4318", " 4318", "4318 ", "4318;id", "abc", "4318\n", "١٢٣٤٥"]
       if re.fullmatch(pat, s)]
print(f"wrong={len(wrong)} first={wrong[:5]} odd_accepted={odd}")
PYEOF
)"
echo "  $result"
check "every integer 0..99999 is classified as 1025..65535 would be" grep -q "wrong=0 " <<<"$result"
check "malformed strings (padding, spaces, signs, injection) are all rejected" grep -q "odd_accepted=\[\]" <<<"$result"

echo "== real sbx kit validate"
if ! command -v sbx >/dev/null 2>&1; then
  skip "sbx is not installed"
elif ! sbx kit validate "$ROOT/kit" >/dev/null 2>&1; then
  skip "sbx cannot validate the kit with default arguments here (daemon or builder unavailable)"
else
  for p in 1025 4318 65535; do check "viewerPort=$p is accepted" accepted "viewerPort=$p"; done
  for p in 0 00 80 1024 65536 99999 01025 abc "4318;id" ""; do
    check "viewerPort='$p' is rejected" rejected "viewerPort=$p"
  done
  for c in none tools full; do check "capture=$c is accepted" accepted "capture=$c"; done
  for c in bogus "full;id" ""; do check "capture='$c' is rejected" rejected "capture=$c"; done
  for a in true false; do check "accountIds=$a is accepted" accepted "accountIds=$a"; done
  check "accountIds=maybe is rejected" rejected "accountIds=maybe"
  check "metricIntervalMs=10000 is accepted" accepted "metricIntervalMs=10000"
  check "metricIntervalMs=50 is rejected" rejected "metricIntervalMs=50"
  check "metricIntervalMs='1;id' is rejected" rejected "metricIntervalMs=1;id"
  check "extraResourceAttributes=team=a,env=b is accepted" accepted "extraResourceAttributes=team=a,env=b"
  check "extraResourceAttributes with a quote and command is rejected" rejected 'extraResourceAttributes=a=b";id;"'
  check "extraResourceAttributes with \$(...) is rejected" rejected 'extraResourceAttributes=a=$(id)'
fi

echo
echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"
[ "$FAIL" = 0 ]
