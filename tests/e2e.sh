#!/usr/bin/env bash
# End-to-end test: two real sandboxes, a real viewer on private ports, a real Claude call.
# Needs: sbx (v0.51+), otel-desktop-viewer with `query`, a signed-in sbx, and a few cents of API usage.
# Uses ports 14318 (OTLP/HTTP) and 18000 (UI) so it never touches a viewer you already run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=14318
UI_PORT=18000
UI="http://localhost:$UI_PORT"
if curl -sf -m 1 -o /dev/null -X POST -H 'content-type: application/x-protobuf' --data-binary '' "http://localhost:$PORT/v1/traces" ||
   curl -sf -m 1 -o /dev/null "$UI/"; then
  echo "e2e: ports $PORT and $UI_PORT must be free; stop whatever is listening on them and rerun" >&2
  exit 2
fi
SUFFIX="$$"
S1="otel-e2e-a-$SUFFIX"
S2="otel-e2e-b-$SUFFIX"
S3="otel-e2e-c-$SUFFIX"
S4="otel-e2e-d-$SUFFIX"
S5="otel-e2e-e-$SUFFIX"
STATE="$(mktemp -d)"
export XDG_STATE_HOME="$STATE"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
quiet() { "$@" >/dev/null 2>&1; }

cleanup() {
  sbx rm --force "$S1" "$S2" "$S3" "$S4" "$S5" >/dev/null 2>&1
  "$ROOT/bin/claude-otel" --stop-viewer --port "$PORT" >/dev/null 2>&1
  rm -rf "$STATE"
}
trap cleanup EXIT

q() { otel-desktop-viewer query "$1" --endpoint "$UI" --json --limit 1000 2>/dev/null; }
count_for() {  # table sandbox-name -> rows whose resource carries that sandbox.name
  q "SELECT count(*) FROM $1 WHERE resource.attributes.\"sandbox.name\"::VARCHAR = '$2'" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0][0])' 2>/dev/null || echo 0
}
attr_rows() {  # table sandbox key -> rows for that sandbox whose attributes mention key
  local filter="resource.attributes.\"sandbox.name\"::VARCHAR = '$2'"
  [ "$1" = metric_series ] && filter="CAST(attributes AS VARCHAR) LIKE '%$2%'"
  q "SELECT count(*) FROM $1 WHERE $filter AND CAST(attributes AS VARCHAR) LIKE '%$3%'" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0][0])' 2>/dev/null || echo 0
}
qn() {  # run a count(*) query, print the number (0 on any failure)
  q "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0][0])' 2>/dev/null || echo 0
}
mark_rows() {  # sandbox -> span and log rows whose attributes, events or body contain $mark
  local a b
  a="$(qn "SELECT count(*) FROM spans WHERE resource.attributes.\"sandbox.name\"::VARCHAR = '$1' AND (CAST(attributes AS VARCHAR) LIKE '%$mark%' OR CAST(events AS VARCHAR) LIKE '%$mark%')")"
  b="$(qn "SELECT count(*) FROM logs WHERE CAST(resource AS VARCHAR) LIKE '%$1%' AND (CAST(attributes AS VARCHAR) LIKE '%$mark%' OR CAST(body AS VARCHAR) LIKE '%$mark%')")"
  echo $((a + b))
}
in_sbx() { sbx exec "$1" bash -c "$2" 2>&1; }

# Poll once a second until a command succeeds, for at most LIMIT seconds; returns its last result.
wait_for() {
  local limit="$1" i; shift
  for ((i = 0; i < limit; i++)); do "$@" && return 0; sleep 1; done
  "$@"
}
telemetry_arrived() {  # every signal from each of S1, S2, S4 is in the viewer
  local n t
  for n in "$S1" "$S2" "$S4"; do
    for t in spans logs metric_records; do [ "$(count_for "$t" "$n")" -gt 0 ] || return 1; done
  done
}
mark_seen() { [ "$(mark_rows "$1")" -gt 0 ]; }
tool_span_seen() {
  [ "$(qn "SELECT count(*) FROM spans WHERE name = 'claude_code.tool' AND resource.attributes.\"sandbox.name\"::VARCHAR = '$1'")" -gt 0 ]
}

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
check "create $S1 (capture=tools)" quiet sbx create claude --kit "$ROOT/kit" --kit-arg "viewerPort=$PORT" --kit-arg capture=tools --name "$S1"
check "create $S2 (default capture)" quiet sbx create claude --kit "$ROOT/kit" --kit-arg "viewerPort=$PORT" --name "$S2"

echo "== environment inside the sandbox"
env_out="$(in_sbx "$S1" 'env')"
check "OTEL_RESOURCE_ATTRIBUTES has sandbox.name" grep -q "sandbox.name=$S1," <<<"$env_out"
check "OTEL_RESOURCE_ATTRIBUTES appears once" test "$(grep -c '^OTEL_RESOURCE_ATTRIBUTES=' <<<"$env_out")" = 1
check "endpoint uses the configured port" grep -q "OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:$PORT" <<<"$env_out"
check "traces enabled" grep -q '^CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1' <<<"$env_out"
check "account ids are off by default" grep -q '^OTEL_METRICS_INCLUDE_ACCOUNT_UUID=false' <<<"$env_out"
check "capture=tools sets tool details" grep -q '^OTEL_LOG_TOOL_DETAILS=1' <<<"$env_out"
check "capture=tools does not log prompts" bash -c '! grep -q "^OTEL_LOG_USER_PROMPTS" <<<"$0"' "$env_out"
env2="$(in_sbx "$S2" 'env')"
check "the default capture sets no OTEL_LOG_* content flags" bash -c '! grep -q "^OTEL_LOG_" <<<"$0"' "$env2"

echo "== kit args: capture=full and extraResourceAttributes"
check "create $S3" quiet sbx create claude --kit "$ROOT/kit" --kit-arg "viewerPort=$PORT" --kit-arg capture=full \
  --kit-arg extraResourceAttributes=team.id=demo,env=test --name "$S3"
env3="$(in_sbx "$S3" 'env')"
check "capture=full logs prompts" grep -q '^OTEL_LOG_USER_PROMPTS=1' <<<"$env3"
check "capture=full logs tool content" grep -q '^OTEL_LOG_TOOL_CONTENT=1' <<<"$env3"
check "extra attributes are appended" grep -q "sandbox.name=$S3,.*,team.id=demo,env=test" <<<"$env3"

echo "== kit args: accountIds=true (and the default capture again)"
check "create $S4" quiet sbx create claude --kit "$ROOT/kit" --kit-arg "viewerPort=$PORT" \
  --kit-arg accountIds=true --name "$S4"
env4="$(in_sbx "$S4" 'env')"
check "the default capture sets no OTEL_LOG_* content flags (second sandbox)" bash -c '! grep -q "^OTEL_LOG_" <<<"$0"' "$env4"
check "accountIds=true is passed on" grep -q '^OTEL_METRICS_INCLUDE_ACCOUNT_UUID=true' <<<"$env4"
check "an invalid accountIds is rejected" bash -c '! sbx kit validate "$0" --kit-arg accountIds=maybe >/dev/null 2>&1' "$ROOT/kit"
check "an injected extraResourceAttributes is rejected" bash -c '! sbx kit validate "$0" --kit-arg "extraResourceAttributes=a=b\";id;\"" >/dev/null 2>&1' "$ROOT/kit"
check "a non-numeric viewerPort is rejected" bash -c '! sbx kit validate "$0" --kit-arg viewerPort=4318\;id >/dev/null 2>&1' "$ROOT/kit"

echo "== claude in each sandbox, viewer up"
for n in "$S1" "$S2"; do
  out="$(in_sbx "$n" 'claude -p "Reply with exactly: ok" 2>&1 | tail -1')"
  grep -qx 'ok' <<<"$out" && ok "claude answers in $n" || bad "claude answers in $n ($out)"
done
out="$(in_sbx "$S4" 'claude -p "Reply with exactly: ok" 2>&1 | tail -1')"
grep -qx 'ok' <<<"$out" && ok "claude answers in $S4" || bad "claude answers in $S4 ($out)"
wait_for 45 telemetry_arrived   # a miss is reported by the checks below

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

echo "== identifiers"
for t in logs metric_series; do
  check "$t: user.account_uuid absent by default" test "$(attr_rows "$t" "$S1" user.account_uuid)" = 0
  check "$t: user.account_uuid present with accountIds=true" test "$(attr_rows "$t" "$S4" user.account_uuid)" -gt 0
  check "$t: user.email still sent (cannot be turned off)" test "$(attr_rows "$t" "$S1" user.email)" -gt 0
done

echo "== what each capture mode records (the table in the README)"
# S1 = tools, S3 = full, S4 = default (none). The command is lower case and its output upper case, so the two
# can be told apart; the prompt contains only the lower-case form, never the output.
mark="cmdmark_$SUFFIX"
outmark="$(tr a-z A-Z <<<"$mark")"
for n in "$S1" "$S3" "$S4"; do
  in_sbx "$n" "claude -p --dangerously-skip-permissions 'Use the Bash tool to run exactly this command and nothing else: echo $mark | tr a-z A-Z' 2>&1 | tail -1" >/dev/null
done
prompt_rows() { qn "SELECT count(*) FROM logs WHERE CAST(resource AS VARCHAR) LIKE '%$1%' AND attributes.\"prompt\"::VARCHAR LIKE '%$mark%'"; }
redacted_prompts() { qn "SELECT count(*) FROM logs WHERE CAST(resource AS VARCHAR) LIKE '%$1%' AND attributes.\"prompt\"::VARCHAR = '<REDACTED>'"; }
reply_rows() { qn "SELECT count(*) FROM logs WHERE CAST(resource AS VARCHAR) LIKE '%$1%' AND CAST(body AS VARCHAR) = 'claude_code.assistant_response' AND attributes.\"response\"::VARCHAR NOT LIKE '%REDACTED%'"; }
redacted_replies() { qn "SELECT count(*) FROM logs WHERE CAST(resource AS VARCHAR) LIKE '%$1%' AND attributes.\"response\"::VARCHAR = '<REDACTED>'"; }
out_rows() { qn "SELECT count(*) FROM spans WHERE name = 'claude_code.tool' AND resource.attributes.\"sandbox.name\"::VARCHAR = '$1' AND CAST(to_json(events) AS VARCHAR) LIKE '%$outmark%'"; }
reply_seen() { [ "$(reply_rows "$1")" -gt 0 ]; }
# A claude process flushes everything before it exits, so once the positive evidence is in, the
# absence checks below are not racing a late export.
wait_for 45 mark_seen "$S1"
wait_for 45 mark_seen "$S3"
wait_for 45 reply_seen "$S3"
wait_for 45 tool_span_seen "$S4"
wait_for 45 tool_span_seen "$S1"

check "tools: the command text is recorded"            test "$(mark_rows "$S1")" -gt 0
check "tools: your prompt is not recorded"             test "$(prompt_rows "$S1")" = 0
check "tools: Claude's reply is not recorded"          test "$(reply_rows "$S1")" = 0
check "tools: tool output is not recorded"             test "$(out_rows "$S1")" = 0
check "tools: the prompt field says <REDACTED>"        test "$(redacted_prompts "$S1")" -gt 0

check "full: the command text is recorded"             test "$(mark_rows "$S3")" -gt 0
check "full: your prompt is recorded"                  test "$(prompt_rows "$S3")" -gt 0
check "full: Claude's reply is recorded"               test "$(reply_rows "$S3")" -gt 0
check "full: tool output is recorded"                  test "$(out_rows "$S3")" -gt 0
check "full: no <REDACTED> prompts or replies"         test "$(redacted_prompts "$S3")$(redacted_replies "$S3")" = 00

check "default: the command text is nowhere"           test "$(mark_rows "$S4")" = 0
check "default: your prompt is not recorded"           test "$(prompt_rows "$S4")" = 0
check "default: Claude's reply is not recorded"        test "$(reply_rows "$S4")" = 0
check "default: tool output is not recorded"           test "$(out_rows "$S4")" = 0
check "default: prompt and reply fields say <REDACTED>" test "$(redacted_prompts "$S4")" -gt 0 -a "$(redacted_replies "$S4")" -gt 0
check "default: tool spans are still recorded"         tool_span_seen "$S4"

echo "== wrapper reattaches to an existing sandbox"
w="$("$ROOT/bin/claude-otel" --name "$S1" --detach 2>&1)"; rc=$?
check "re-running the wrapper on an existing name succeeds" test "$rc" = 0
check "it says it is reattaching" grep -q "exists; reattaching" <<<"$w"
check "it does not hit sbx's --kit error" bash -c '! grep -q "already exists" <<<"$0"' "$w"
check "it uses the sandbox's own port" grep -q "viewer listening on localhost:$PORT" <<<"$w"
w="$("$ROOT/bin/claude-otel" --port 14999 --capture full --name "$S1" --detach 2>&1)"
check "conflicting --port and --capture only warn" grep -q "ignoring --port 14999" <<<"$w"
check "the capture change is called out" grep -q "capture is fixed when a sandbox is created" <<<"$w"

echo "== wrapper refuses a sandbox of another agent"
check "create $S5 (shell agent)" quiet sbx create shell --name "$S5"
w="$("$ROOT/bin/claude-otel" --name "$S5" --detach 2>&1)"; rc=$?
check "refused with a non-zero exit" test "$rc" != 0
check "names the agent it found" grep -q "runs the 'shell' agent" <<<"$w"
check "does not claim to reattach" bash -c '! grep -q "reattaching" <<<"$0"' "$w"

echo "== --start-viewer explains a port clash"
sd="$(mktemp -d)"
w="$(XDG_STATE_HOME="$sd" "$ROOT/bin/claude-otel" --check --start-viewer --port 14400 --ui-port "$UI_PORT" 2>&1)"; rc=$?
check "a clash makes the start fail" test "$rc" != 0
check "the viewer's real reason is shown" grep -q "address already in use" <<<"$w"
check "it hints at --ui-port" grep -q -- "--ui-port" <<<"$w"
check "no pid file is left behind" test ! -f "$sd/claude-otel/viewer-14400.pid"
check "nothing is left listening on the clashing port" bash -c '! lsof -nP -iTCP:14400 -sTCP:LISTEN >/dev/null 2>&1'
rm -rf "$sd"

echo "== restart is idempotent"
sbx stop "$S1" >/dev/null 2>&1
m="$(in_sbx "$S1" 'echo $(grep -c claude-otel-kit /etc/sandbox-persistent.sh) $(grep -c claude-otel-kit /home/agent/.bashrc)' | tail -1)"
[ "$m" = "1 1" ] && ok "one marker line in each file after restart" || bad "marker lines after restart: '$m'"

echo "== claude's own Bash tool"
tool_out="$(in_sbx "$S2" 'claude -p --dangerously-skip-permissions "Run this exact shell command and print only its output: env | grep -c ^OTEL_" 2>&1 | tail -1' | tail -1)"
echo "  INFO  OTEL_ vars visible to Claude's Bash tool: ${tool_out:-?} (see README, Known behaviour)"

echo "== viewer down"
pidf="$STATE/claude-otel/viewer-$PORT.pid"
vpid="$(cat "$pidf" 2>/dev/null)"
check "--stop-viewer stops the viewer the wrapper started" quiet "$ROOT/bin/claude-otel" --stop-viewer --port "$PORT"
check "the viewer process is gone" bash -c '! kill -0 "$0" 2>/dev/null' "$vpid"
check "the pid file is gone" test ! -f "$pidf"
check "nothing listens on the port any more" bash -c '! curl -sf -m2 -o /dev/null -X POST "http://localhost:$0/v1/traces"' "$PORT"
out="$(in_sbx "$S2" 'claude -p "Reply with exactly: ok" 2>&1 | tail -1')"
grep -qx 'ok' <<<"$out" && ok "claude still works with the viewer down" || bad "claude with viewer down ($out)"
sbx stop "$S2" >/dev/null 2>&1
status_warns() { in_sbx "$S2" 'cat /home/agent/.local/share/claude-otel-kit/status' | tail -1 | grep -q '^WARNING'; }
wait_for 30 status_warns
st="$(in_sbx "$S2" 'cat /home/agent/.local/share/claude-otel-kit/status' | tail -1)"
grep -q '^WARNING' <<<"$st" && ok "status file warns when the viewer is down" || bad "status file ($st)"

echo "== egress"
hosts="$(sbx policy log "$S1" 2>&1 | grep -c "localhost:$PORT")"
[ "${hosts:-0}" -gt 0 ] && ok "policy log shows localhost:$PORT" || bad "policy log shows localhost:$PORT"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
