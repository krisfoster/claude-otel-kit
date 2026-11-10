#!/usr/bin/env bash
# Fast test of install.sh and the wrapper's symlink handling. No sandboxes, no API calls.
set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
quiet() { "$@" >/dev/null 2>&1; }
fails() { ! "$@" >/dev/null 2>&1; }
# A port nothing listens on, so --check reaches the "nothing is listening" branch.
P=14999

check "install creates the link"        quiet "$ROOT/install.sh" --bin-dir "$T/bin"
check "link points at the repo wrapper" test "$(readlink "$T/bin/claude-otel")" = "$ROOT/bin/claude-otel"
out="$("$ROOT/install.sh" --bin-dir "$T/bin" 2>&1)"
check "second install is a no-op"       grep -q "already installed" <<<"$out"
out="$("$ROOT/install.sh" --bin-dir "$T/fresh" 2>&1)"
check "warns when bin dir not on PATH"  grep -q "not on your PATH" <<<"$out"

out="$("$T/bin/claude-otel" --check --port $P 2>&1)"
check "wrapper finds the kit via the link"   grep -q "nothing is listening" <<<"$out"
mkdir -p "$T/other"
ln -s "$T/bin/claude-otel" "$T/other/chained"
out="$("$T/other/chained" --check --port $P 2>&1)"
check "wrapper follows a chained link"       grep -q "nothing is listening" <<<"$out"
(cd "$T/other" && ln -s ../bin/claude-otel rel)
out="$(cd "$T/other" && ./rel --check --port $P 2>&1)"
check "wrapper follows a relative link"      grep -q "nothing is listening" <<<"$out"
cp -R "$ROOT/bin" "$T/lonely"
out="$("$T/lonely/claude-otel" --check 2>&1)"
check "wrapper reports a missing kit"        grep -q "kit not found" <<<"$out"

mkdir -p "$T/foreign"
echo keep > "$T/foreign/claude-otel"
check "install refuses to clobber a file"    fails "$ROOT/install.sh" --bin-dir "$T/foreign"
check "the file was left alone"              test "$(cat "$T/foreign/claude-otel")" = keep
check "uninstall refuses a foreign file"     fails "$ROOT/install.sh" uninstall --bin-dir "$T/foreign"
check "--force replaces it"                  quiet "$ROOT/install.sh" --bin-dir "$T/foreign" --force
check "uninstall removes our link"           quiet "$ROOT/install.sh" uninstall --bin-dir "$T/foreign"
check "link is gone"                         test ! -e "$T/foreign/claude-otel"
out="$("$ROOT/install.sh" uninstall --bin-dir "$T/foreign" 2>&1)"
check "uninstall when absent is harmless"    grep -q "nothing to remove" <<<"$out"
check "unknown argument is rejected"         fails "$ROOT/install.sh" --bogus

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
