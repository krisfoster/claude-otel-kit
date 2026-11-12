#!/usr/bin/env bash
# Fast test of install.sh and the wrapper's symlink handling. No sandboxes, no API calls.
set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Physical path: macOS mktemp returns /var/..., a link to /private/var/..., and install.sh records the real one.
T="$(cd -P "$(mktemp -d)" && pwd)"
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
# The wrapper insists on an installed otel-desktop-viewer; a stub keeps these tests independent of the host.
mkdir -p "$T/fakebin"
printf '#!/bin/sh\necho "  query    Run SQL"\n' >"$T/fakebin/otel-desktop-viewer"
chmod +x "$T/fakebin/otel-desktop-viewer"
PATH="$T/fakebin:$PATH"

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

echo "== a moved or deleted checkout (stale link), and other checkouts"
copy_repo() { mkdir -p "$1" && cp -R "$ROOT/bin" "$ROOT/kit" "$ROOT/install.sh" "$1/"; }
L="$T/lnk/claude-otel"

copy_repo "$T/a"
quiet "$T/a/install.sh" --bin-dir "$T/lnk"
mv "$T/a" "$T/b"
check "fixture: moving the checkout leaves a dangling link" bash -c '[ -L "$0" ] && [ ! -e "$0" ]' "$L"
out="$("$T/b/install.sh" --bin-dir "$T/lnk" 2>&1)"
check "install replaces a stale link without --force" grep -q "replaced a stale link" <<<"$out"
check "the link now points at the moved checkout"    test "$(readlink "$L")" = "$T/b/bin/claude-otel"
out="$("$L" --check --port 14999 2>&1)"
check "and works through the link"                   grep -q "nothing is listening" <<<"$out"

mv "$T/b" "$T/c"
out="$("$T/c/install.sh" uninstall --bin-dir "$T/lnk" 2>&1)"
check "uninstall removes a stale link without --force" grep -q "removed a stale link" <<<"$out"
check "the link is gone"                             test ! -e "$L" -a ! -L "$L"

copy_repo "$T/d"
quiet "$T/d/install.sh" --bin-dir "$T/lnk"
rm -rf "$T/d"
out="$("$ROOT/install.sh" uninstall --bin-dir "$T/lnk" 2>&1)"
check "a deleted checkout's link can be uninstalled from another one" grep -q "removed a stale link" <<<"$out"

mkdir -p "$T/rel/bin"
(cd "$T/rel/bin" && ln -s ../gone/bin/claude-otel claude-otel)
out="$("$ROOT/install.sh" --bin-dir "$T/rel/bin" 2>&1)"
check "a relative dangling link is also treated as stale" grep -q "replaced a stale link" <<<"$out"

copy_repo "$T/live"
rm -rf "$T/lnk2"; quiet "$T/live/install.sh" --bin-dir "$T/lnk2"
check "install refuses to take over a live checkout's link" fails "$ROOT/install.sh" --bin-dir "$T/lnk2"
out="$("$ROOT/install.sh" --bin-dir "$T/lnk2" 2>&1)"
check "and says which checkout owns it"              grep -q "points at another checkout ($T/live/bin/claude-otel)" <<<"$out"
check "the link was left alone"                      test "$(readlink "$T/lnk2/claude-otel")" = "$T/live/bin/claude-otel"
check "uninstall refuses another checkout's link"    fails "$ROOT/install.sh" uninstall --bin-dir "$T/lnk2"
check "--force switches it to this checkout"         quiet "$ROOT/install.sh" --bin-dir "$T/lnk2" --force
check "now it points here"                           test "$(readlink "$T/lnk2/claude-otel")" = "$ROOT/bin/claude-otel"
quiet "$T/live/install.sh" --bin-dir "$T/lnk2" --force
check "uninstall --force removes another checkout's link" quiet "$ROOT/install.sh" uninstall --bin-dir "$T/lnk2" --force
check "it is gone"                                   test ! -L "$T/lnk2/claude-otel"

mkdir -p "$T/lnk3"
ln -s /bin/echo "$T/lnk3/claude-otel"
check "a link to something unrelated: install refuses" fails "$ROOT/install.sh" --bin-dir "$T/lnk3"
check "uninstall --force still refuses it"           fails "$ROOT/install.sh" uninstall --bin-dir "$T/lnk3" --force
check "the unrelated link survives"                  test "$(readlink "$T/lnk3/claude-otel")" = /bin/echo
check "install --force replaces it"                  quiet "$ROOT/install.sh" --bin-dir "$T/lnk3" --force

mkdir -p "$T/lnk4/claude-otel"
echo precious >"$T/lnk4/claude-otel/data"
check "a real directory: install refuses"            fails "$ROOT/install.sh" --bin-dir "$T/lnk4"
check "a real directory: even with --force"          fails "$ROOT/install.sh" --bin-dir "$T/lnk4" --force
check "a real directory: uninstall --force refuses"  fails "$ROOT/install.sh" uninstall --bin-dir "$T/lnk4" --force
check "the directory and its contents survive"       test "$(cat "$T/lnk4/claude-otel/data")" = precious

echo "== host platform"
mkdir -p "$T/plat"
cat >"$T/plat/uname" <<'EOF'
#!/bin/sh
case "$1" in
  -r) echo "${FAKE_UNAME_R:-5.15.0-generic}" ;;
  *)  echo "${FAKE_UNAME_S:?}" ;;
esac
EOF
chmod +x "$T/plat/uname"
n=0
inst() {  # SYSNAME [RELEASE] -> OUT, RC: install into a fresh dir with the viewer present
  n=$((n + 1))
  OUT="$(PATH="$T/plat:$PATH" FAKE_UNAME_S="$1" FAKE_UNAME_R="${2:-5.15.0-generic}" "$ROOT/install.sh" --bin-dir "$T/plat-bin-$n" 2>&1)"
  RC=$?
}
for os in Darwin Linux; do
  inst "$os"
  check "$os: installs without a platform warning" bash -c '! grep -q "not currently supported\|unrecognised host" <<<"$0"' "$OUT"
done
inst Linux "5.15.153.1-microsoft-standard-WSL2"
check "WSL: warns Windows is not supported"        grep -q "WSL detected. Windows is not currently supported" <<<"$OUT"
check "WSL: installs anyway"                       test "$RC" = 0 -a -L "$T/plat-bin-$n/claude-otel"
for os in MINGW64_NT-10.0-19045 MSYS_NT-10.0-22631 CYGWIN_NT-10.0-19045; do
  inst "$os"
  check "$os: warns Windows is not supported"      grep -q "Windows is not currently supported ($os)" <<<"$OUT"
  check "$os: installs anyway"                     test "$RC" = 0 -a -L "$T/plat-bin-$n/claude-otel"
done
inst FreeBSD
check "an unknown OS is warned about"              grep -q "unrecognised host 'FreeBSD'" <<<"$OUT"
check "uninstall warns too"                        grep -q "Windows is not currently supported" <<<"$(PATH="$T/plat:$PATH" FAKE_UNAME_S=MINGW64_NT-10.0 "$ROOT/install.sh" uninstall --bin-dir "$T/plat-bin-1" 2>&1)"

hint() {  # SYSNAME -> OUT: no viewer on PATH
  n=$((n + 1))
  OUT="$(PATH="$T/plat:/usr/bin:/bin" FAKE_UNAME_S="$1" "$ROOT/install.sh" --bin-dir "$T/plat-bin-$n" 2>&1)"
}
hint Darwin
check "macOS: the note suggests Homebrew"          grep -q "brew tap ctrlspice/otel-desktop-viewer" <<<"$OUT"
hint Linux
check "Linux: no Homebrew, mentions apt, dnf and glibc" bash -c '! grep -q brew <<<"$0" && grep -q "apt and dnf" <<<"$0" && grep -q "glibc 2.39" <<<"$0"' "$OUT"
check "Linux: links the viewer's README"           grep -q "otel-desktop-viewer#getting-started" <<<"$OUT"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
