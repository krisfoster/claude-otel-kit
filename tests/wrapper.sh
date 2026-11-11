#!/usr/bin/env bash
# Hermetic test of bin/claude-otel's decisions, using a fake `sbx` and a fake viewer.
# No sandboxes, no API calls, no real viewer. Needs python3 for a tiny OTLP-style responder.
set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
PORT_A=14777   # where the fake viewer listens
PORT_B=14778   # a port nothing listens on
SERVER_PID=""
SPAWNED=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  for p in $SPAWNED; do kill -9 "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
has() { grep -qF -- "$1" <<<"$2"; }
lacks() { ! grep -qF -- "$1" <<<"$2"; }

mkdir -p "$T/bin"
# Fake sbx. FAKE_SBX_EXISTING is "name:port" pairs; port "none" means created without the kit.
cat >"$T/bin/sbx" <<'EOF'
#!/usr/bin/env bash
echo "sbx $*" >>"$FAKE_SBX_LOG"
case "$1" in
  ls)   for e in $FAKE_SBX_EXISTING; do echo "${e%%:*}"; done ;;
  exec) for e in $FAKE_SBX_EXISTING; do
          if [ "${e%%:*}" = "$2" ] && [ "${e#*:}" != none ]; then echo "http://host.docker.internal:${e#*:}"; fi
        done ;;
  run)  : ;;
esac
EOF
# Fake viewer: `--help` lists `query`; started with --http it stays alive like a real one.
cat >"$T/bin/otel-desktop-viewer" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" --http "*)
    [ -n "${FAKE_IGNORE_TERM:-}" ] && trap '' TERM
    while :; do sleep 1; done ;;
esac
echo "  query    Run SQL"
EOF
chmod +x "$T/bin/sbx" "$T/bin/otel-desktop-viewer"

cat >"$T/server.py" <<'EOF'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
python3 "$T/server.py" "$PORT_A" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 20); do curl -sf -m1 -o /dev/null -X POST "http://localhost:$PORT_A/" && break; sleep 0.25; done

# run_wrapper "name:port ..." args...  ->  sets OUT (stderr+stdout) and CALLS (what sbx was asked)
run_wrapper() {
  local existing="$1"; shift
  : >"$T/calls"
  OUT="$(PATH="$T/bin:$PATH" FAKE_SBX_LOG="$T/calls" FAKE_SBX_EXISTING="$existing" "$ROOT/bin/claude-otel" "$@" 2>&1)"
  CALLS="$(cat "$T/calls")"
}

echo "== new sandbox: created with the kit"
run_wrapper "" --port $PORT_A --name fresh .
check "runs sbx run claude with --kit"            has "sbx run claude --kit $ROOT/kit" "$CALLS"
check "passes viewerPort"                         has "--kit-arg viewerPort=$PORT_A" "$CALLS"
check "passes the name and path through"          has "--name fresh ." "$CALLS"
check "does not look inside any sandbox"          lacks "sbx exec" "$CALLS"
check "no capture arg unless asked"               lacks "capture=" "$CALLS"
run_wrapper "" --port $PORT_A --capture full --name fresh
check "capture is passed when asked"              has "--kit-arg capture=full" "$CALLS"

echo "== existing sandbox: reattach, no --kit"
run_wrapper "old:$PORT_A" --name old --detach
check "reattaches with sbx run claude"            has "sbx run claude --name old --detach" "$CALLS"
check "does not pass --kit"                       lacks "--kit" "$CALLS"
check "tells the user it is reattaching"          has "sandbox 'old' exists; reattaching" "$OUT"
check "no warning when nothing conflicts"         lacks "warning" "$OUT"
run_wrapper "old:$PORT_A" --name=old .
check "--name=NAME form is recognised"            has "sbx run claude --name=old ." "$CALLS"
check "--name=NAME does not pass --kit"           lacks "--kit" "$CALLS"

echo "== existing sandbox: the viewer check uses the sandbox's own port"
run_wrapper "old:$PORT_A" --name old
check "checks the sandbox's port, not the default" has "viewer listening on localhost:$PORT_A" "$OUT"
run_wrapper "old:$PORT_A" --port $PORT_B --name old
check "warns when --port disagrees"               has "exports to port $PORT_A" "$OUT"
check "uses the sandbox's port anyway"            has "viewer listening on localhost:$PORT_A" "$OUT"
check "still passes no --kit"                     lacks "--kit" "$CALLS"

echo "== existing sandbox: kit settings cannot change"
run_wrapper "old:$PORT_A" --capture full --name old
check "warns that --capture is ignored"           has "--capture is fixed when a sandbox is created" "$OUT"
check "suggests sbx rm"                           has "sbx rm old" "$OUT"
check "passes no capture arg"                     lacks "capture=" "$CALLS"

echo "== existing sandbox made without the kit"
run_wrapper "plain:none" --port $PORT_A --name plain
check "warns it sends no telemetry"               has "was not created with the claude-otel kit" "$OUT"
check "still reattaches"                          has "sbx run claude --name plain" "$CALLS"

echo "== edge cases"
run_wrapper "old:$PORT_A" --port $PORT_A --name fresh2 .
check "a different name creates a new sandbox"    has "--kit $ROOT/kit" "$CALLS"
run_wrapper "old:$PORT_A" --port $PORT_A . -- --name old
check "--name after -- is the agent's, not ours"  has "--kit $ROOT/kit" "$CALLS"
run_wrapper "old:$PORT_A" --port $PORT_A
check "no name given: no sandbox lookup"          lacks "sbx ls" "$CALLS"
run_wrapper "old:$PORT_A" --check --port $PORT_A --name old
check "--check never calls sbx"                   test -z "$CALLS"
run_wrapper "oldish:$PORT_A" --port $PORT_A --name old
check "name match is exact, not a prefix"         has "--kit $ROOT/kit" "$CALLS"

echo "== --stop-viewer"
STATE="$T/state"
mkdir -p "$STATE/claude-otel"
alive() { kill -0 "$1" 2>/dev/null; }
# stop_run PORT [PATH]  ->  OUT, RC
stop_run() {
  OUT="$(PATH="${2:-$T/bin:$PATH}" XDG_STATE_HOME="$STATE" "$ROOT/bin/claude-otel" --stop-viewer --port "$1" 2>&1)"
  RC=$?
}
# spawn_viewer HTTP_ARG [ignore-term] -> VPID: a fake viewer that looks like `otel-desktop-viewer ... --http N ...`
spawn_viewer() {
  FAKE_IGNORE_TERM="${2:-}" "$T/bin/otel-desktop-viewer" --open-browser=false --http "$1" --grpc 1 --browser-port 2 \
    >/dev/null 2>&1 &
  VPID=$!
  SPAWNED="$SPAWNED $VPID"
  sleep 0.3
}

spawn_viewer 14790
echo "$VPID" >"$STATE/claude-otel/viewer-14790.pid"
check "fixture: the fake viewer is running"       alive "$VPID"
stop_run 14790
check "stops the viewer it started"               test "$RC" = 0
check "reports it"                                has "stopped the viewer (pid $VPID) on port 14790" "$OUT"
check "the process is gone"                       bash -c '! kill -0 "$0" 2>/dev/null' "$VPID"
check "the pid file is removed"                   test ! -f "$STATE/claude-otel/viewer-14790.pid"

sleep 300 &
OTHER=$!
SPAWNED="$SPAWNED $OTHER"
echo "$OTHER" >"$STATE/claude-otel/viewer-14791.pid"
stop_run 14791
check "stale pid file: exits 0"                   test "$RC" = 0
check "stale pid file: says it was stale"         has "is not the viewer claude-otel started on port 14791" "$OUT"
check "stale pid file: the other process survives" alive "$OTHER"
check "stale pid file: the pid file is removed"   test ! -f "$STATE/claude-otel/viewer-14791.pid"

spawn_viewer 147920
echo "$VPID" >"$STATE/claude-otel/viewer-14792.pid"
stop_run 14792
check "port 14792 does not match a viewer on 147920" has "is not the viewer claude-otel started" "$OUT"
check "the prefix-port viewer survives"           alive "$VPID"

true & DEAD=$!; wait "$DEAD" 2>/dev/null
echo "$DEAD" >"$STATE/claude-otel/viewer-14793.pid"
stop_run 14793
check "dead pid: says it is no longer running"    has "is no longer running" "$OUT"
check "dead pid: the pid file is removed"         test ! -f "$STATE/claude-otel/viewer-14793.pid"

echo "not-a-number" >"$STATE/claude-otel/viewer-14794.pid"
stop_run 14794
check "malformed pid file: removed, nothing stopped" has "pid file was malformed" "$OUT"
check "malformed pid file is gone"                test ! -f "$STATE/claude-otel/viewer-14794.pid"

stop_run $PORT_A
check "no pid file: exits 0"                      test "$RC" = 0
check "no pid file: says so"                      has "no viewer started by claude-otel" "$OUT"
check "a viewer someone else started is left alone" has "did not start it; leaving it alone" "$OUT"
check "that other viewer is still answering"      curl -sf -m2 -o /dev/null -X POST "http://localhost:$PORT_A/"

stop_run 14795 "/usr/bin:/bin"
check "works without sbx or the viewer installed" has "no viewer started by claude-otel" "$OUT"

OUT="$(XDG_STATE_HOME="$STATE" PATH="$T/bin:$PATH" "$ROOT/bin/claude-otel" --stop-viewer --name x 2>&1)"; RC=$?
check "extra arguments are rejected"              test "$RC" != 0
check "with a clear message"                      has "takes no other arguments" "$OUT"

spawn_viewer 14796 yes
echo "$VPID" >"$STATE/claude-otel/viewer-14796.pid"
stop_run 14796
check "a viewer ignoring SIGTERM: exits non-zero" test "$RC" != 0
check "it says it did not exit"                   has "did not exit after SIGTERM" "$OUT"
check "the pid file is kept so you can retry"     test -f "$STATE/claude-otel/viewer-14796.pid"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
