#!/usr/bin/env bash
# End-to-end test: two real sandboxes, a real viewer on private ports, a real Claude call.
# Needs: sbx (v0.45+), otel-desktop-viewer with `query`, a signed-in sbx, and a few cents of API usage.
# Uses ports 14318 (OTLP/HTTP) and 18000 (UI) so it never touches a viewer you already run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=14318
UI_PORT=18000
UI="http://localhost:$UI_PORT"
SUFFIX="$$"
S1="otel-e2e-a-$SUFFIX"
S2="otel-e2e-b-$SUFFIX"
S3="otel-e2e-c-$SUFFIX"
STATE="$(mktemp -d)"
export XDG_STATE_HOME="$STATE"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
quiet() { "$@" >/dev/null 2>&1; }

cleanup() {
  sbx rm --force "$S1" "$S2" "$S3" >/dev/null 2>&1
  if [ -f "$STATE/claude-otel/viewer-$PORT.pid" ]; then
    kill "$(cat "$STATE/claude-otel/viewer-$PORT.pid")" 2>/dev/null
  fi
  rm -rf "$STATE"
}
trap cleanup EXIT

q() { otel-desktop-viewer query "$1" --endpoint "$UI" --json --limit 1000 2>/dev/null; }
count_for() {  # table sandbox-name -> rows whose resource carries that sandbox.name
  q "SELECT count(*) FROM $1 WHERE resource.attributes.\"sandbox.name\"::VARCHAR = '$2'" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0][0])' 2>/dev/null || echo 0
}
in_sbx() { sbx exec "$1" bash -c "$2" 2>&1; }

echo "== host wrapper"
w="$("$ROOT/bin/claude-otel" --check --port "$PORT" --ui-port "$UI_PORT" 2>&1)"
check "wrapper warns when no viewer is listening" grep -q "nothing is listening" <<<"$w"
w="$(PATH=/usr/bin:/bin "$ROOT/bin/claude-otel" --check 2>&1; true)"
check "wrapper reports a missing viewer install" grep -q "not installed" <<<"$w"
check "wrapper rejects a bad --capture" bash -c '! "$0" --check --capture bogus >/dev/null 2>&1' "$ROOT/bin/claude-otel"
check "wrapper starts a viewer" quiet "$ROOT/bin/claude-otel" --check --start-viewer --port "$PORT" --ui-port "$UI_PORT"

echo "== kit validates"
check "sbx kit validate" sbx kit validate "$ROOT/kit"

echo "== create two sandboxes"
for n in "$S1" "$S2"; do
  check "create $n" quiet sbx create claude --kit "$ROOT/kit" --kit-arg "viewerPort=$PORT" --name "$n"
done

echo "== environment inside the sandbox"
env_out="$(in_sbx "$S1" 'env')"
check "OTEL_RESOURCE_ATTRIBUTES has sandbox.name" grep -q "sandbox.name=$S1," <<<"$env_out"
check "OTEL_RESOURCE_ATTRIBUTES appears once" test "$(grep -c '^OTEL_RESOURCE_ATTRIBUTES=' <<<"$env_out")" = 1
check "endpoint uses the configured port" grep -q "OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:$PORT" <<<"$env_out"
check "traces enabled" grep -q '^CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1' <<<"$env_out"
check "capture=tools default sets tool details" grep -q '^OTEL_LOG_TOOL_DETAILS=1' <<<"$env_out"
check "capture=tools does not log prompts" bash -c '! grep -q "^OTEL_LOG_USER_PROMPTS" <<<"$0"' "$env_out"

echo "== kit args: capture=full and extraResourceAttributes"
check "create $S3" quiet sbx create claude --kit "$ROOT/kit" --kit-arg "viewerPort=$PORT" --kit-arg capture=full \
  --kit-arg extraResourceAttributes=team.id=demo,env=test --name "$S3"
env3="$(in_sbx "$S3" 'env')"
check "capture=full logs prompts" grep -q '^OTEL_LOG_USER_PROMPTS=1' <<<"$env3"
check "capture=full logs tool content" grep -q '^OTEL_LOG_TOOL_CONTENT=1' <<<"$env3"
check "extra attributes are appended" grep -q "sandbox.name=$S3,.*,team.id=demo,env=test" <<<"$env3"

echo "== claude in each sandbox, viewer up"
for n in "$S1" "$S2"; do
  out="$(in_sbx "$n" 'claude -p "Reply with exactly: ok" 2>&1 | tail -1')"
  grep -qx 'ok' <<<"$out" && ok "claude answers in $n" || bad "claude answers in $n ($out)"
done
sleep 8

echo "== sandbox name on every signal"
for t in spans logs metric_records; do
  for n in "$S1" "$S2"; do
    c="$(count_for "$t" "$n")"
    [ "${c:-0}" -gt 0 ] && ok "$t carries sandbox.name=$n ($c rows)" || bad "$t carries sandbox.name=$n"
  done
done
ids="$(q "SELECT count(DISTINCT resource.attributes.\"sandbox.id\"::VARCHAR) FROM spans" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0][0])' 2>/dev/null || echo 0)"
[ "${ids:-0}" -ge 2 ] && ok "two distinct sandbox.id values" || bad "two distinct sandbox.id values ($ids)"

echo "== restart is idempotent"
sbx stop "$S1" >/dev/null 2>&1
m="$(in_sbx "$S1" 'echo $(grep -c claude-otel-kit /etc/sandbox-persistent.sh) $(grep -c claude-otel-kit /home/agent/.bashrc)' | tail -1)"
[ "$m" = "1 1" ] && ok "one marker line in each file after restart" || bad "marker lines after restart: '$m'"

echo "== claude's own Bash tool"
tool_out="$(in_sbx "$S2" 'claude -p --dangerously-skip-permissions "Run this exact shell command and print only its output: env | grep -c ^OTEL_" 2>&1 | tail -1')"
echo "  INFO  OTEL_ vars visible to Claude's Bash tool: ${tool_out:-?} (see README, Known behaviour)"

echo "== viewer down"
kill "$(cat "$STATE/claude-otel/viewer-$PORT.pid")" 2>/dev/null; sleep 1
out="$(in_sbx "$S2" 'claude -p "Reply with exactly: ok" 2>&1 | tail -1')"
grep -qx 'ok' <<<"$out" && ok "claude still works with the viewer down" || bad "claude with viewer down ($out)"
sbx stop "$S2" >/dev/null 2>&1
st="$(in_sbx "$S2" 'sleep 5; cat /home/agent/.local/share/claude-otel-kit/status' | tail -1)"
grep -q '^WARNING' <<<"$st" && ok "status file warns when the viewer is down" || bad "status file ($st)"

echo "== egress"
hosts="$(sbx policy log "$S1" 2>&1 | grep -c "localhost:$PORT")"
[ "${hosts:-0}" -gt 0 ] && ok "policy log shows localhost:$PORT" || bad "policy log shows localhost:$PORT"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
