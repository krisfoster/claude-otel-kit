# Plan: Claude Code OpenTelemetry kit (v3) for Docker Sandboxes

Status: built and verified. `kit/kit.yaml`, `bin/claude-otel`, `install.sh`, `tests/install.sh` (16 checks), `tests/e2e.sh` (30 checks) and `README.md` are done. Decisions below were approved on 2026-11-10 (all recommendations accepted).

## Goal

A v3 mixin kit for the built-in `claude` sandbox agent. It turns on Claude Code's OpenTelemetry export (traces, metrics, logs) and sends it to the user's local otel-desktop-viewer. Every signal carries the sandbox name so a trace can be matched to a sandboxed Claude. Use:

    sbx create claude --kit ./kit --name my-sbx .
    # or, with host preflight checks:
    bin/claude-otel --name my-sbx .

## What was verified (2026-11-10, sbx v0.51.0, Claude Code 2.1.322 in sandbox, viewer v0.7.0)

- v3 source kits need the kit builder (`sbx kit validate ./kit` without `--offline`). A skeleton mixin with `network-policy@1` + `lifecycle@1` validated.
- The built-in `claude` sandbox exports `SANDBOX_NAME`, `SANDBOX_ID`, `IS_SANDBOX`, `WORKSPACE_DIR`.
- From inside a sandbox, `host.docker.internal:4318` and `:8000` reach the host viewer (HTTP 200). `localhost:4318` inside the VM does not (`NO_PROXY` makes it hit the VM itself).
- `sbx policy log` records the host as `localhost:4318`, so allow rules use `localhost:<port>`.
- All egress goes through `HTTPS_PROXY=http://gateway.docker.internal:3128`.
- Claude launches under bash with `BASH_ENV=/etc/sandbox-persistent.sh` (empty, writable by `agent`).
- `~/.claude/settings.json` in the sandbox is already populated, so the kit must not write it. Claude Code ignores OTEL exporter variables from project and local settings.
- The viewer's HTTP receiver is protobuf only (no `http/json`).

## Design

One mixin, `kit/kit.yaml`, declaration only (no Dockerfile).

1. `lifecycle@1` file `/home/agent/.local/share/claude-otel-kit/env.sh`, written at create with kit args expanded. It exports:
   - `CLAUDE_CODE_ENABLE_TELEMETRY=1`, `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` (traces)
   - `OTEL_TRACES_EXPORTER`, `OTEL_METRICS_EXPORTER`, `OTEL_LOGS_EXPORTER` = `otlp`
   - `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:<port>`
   - short export intervals so the viewer feels live
   - content capture per the `capture` arg
   - `OTEL_RESOURCE_ATTRIBUTES="sandbox.name=$SANDBOX_NAME,sandbox.id=$SANDBOX_ID[,extra]"`, evaluated by the shell at launch so a rename stays correct (composed fresh each time; an existing value is replaced)
2. `lifecycle@1` startup hook: idempotently adds a `source` line for env.sh to `/etc/sandbox-persistent.sh` (BASH_ENV, covers the agent launch) and `~/.bashrc` (covers a manual `claude` from `sbx exec -it`). A second background hook probes the viewer and writes a status file.
3. `network-policy@1` runtime allow: `localhost:<port>` only.

Args: `viewerPort` (default 4318), `capture` (`none|tools|full`, default `tools`), `metricIntervalMs`, `extraResourceAttributes`.

Capture mapping: `none` = nothing; `tools` = `OTEL_LOG_TOOL_DETAILS=1`; `full` = also `OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_ASSISTANT_RESPONSES`, `OTEL_LOG_TOOL_CONTENT`.

Host wrapper `bin/claude-otel` (kits cannot run host code): checks `otel-desktop-viewer` is installed (prints the brew install command and exits if not), checks the port is listening (warns, `--start-viewer` starts one the wrapper owns, optional `--db FILE` for persistence), then `exec sbx run claude --kit kit/ ...`.

Install: `install.sh` symlinks `bin/claude-otel` into `~/.local/bin` (or `--bin-dir`), refuses to overwrite foreign files without `--force`, and `uninstall` only removes its own link. The wrapper resolves symlinks to find `kit/`. The kit needs no install.

Layout:

    kit/kit.yaml
    bin/claude-otel
    install.sh
    tests/e2e.sh
    tests/install.sh
    README.md
    PLAN.md

## Decisions (approved)

| # | Decision | Choice |
|---|---|---|
| 1 | Env delivery | BASH_ENV file (not managed-settings drop-in: that runs as root, locks the endpoint, and a malformed file stops Claude starting) |
| 2 | Transport | `http/protobuf` on 4318 (not gRPC) |
| 3 | Content capture default | `tools`; `full` is opt-in |
| 4 | Identity | Resource attributes `sandbox.name` and `sandbox.id`; keep `service.name=claude-code`. Revisit if the viewer UI does not show resource attributes in trace lists. |
| 5 | Viewer-missing warning | Host wrapper plus best-effort in-sandbox probe |
| 6 | Kit location | `kit/` subdirectory |
| 7 | Viewer persistence | `--db` flag on the wrapper, default off |

Assumed: `claude` agent only (`claude-bedrock` untested), local directory use, no registry publishing yet.

## Risks

- Whether Claude's OTLP exporter honours `HTTPS_PROXY` (Claude docs are silent). Fallback: `NODE_USE_ENV_PROXY=1`. Gate for everything else, hence spike 1.
- Allow-rule form and necessity cannot be proven on an Allow_All org policy.
- Startup hook must finish before Claude launches.
- gRPC through the sandbox proxy is unproven; not used.

## Verification

1. Spike 1 (gate): fresh sandbox + viewer running, `claude -p "say ok"`; viewer `services`, `traces`, `logs`, `metrics` show `sandbox.name`.
2. Two sandboxes show different names.
3. Stop/start does not duplicate the `source` line.
4. Viewer down: Claude does not hang or error.
5. `sbx policy log` shows only `localhost:<port>`.
6. Automate as `tests/e2e.sh`.

## Spike log

### Spike 1 (2026-11-10): PASSED

Setup: `sbx create claude --kit ./kit --name otel-spike1` (no workspace; the org filesystem policy denies mounts outside `~/repos`), viewer running on the host, `sbx exec otel-spike1 bash -c 'claude -p "Reply with exactly: ok"'`.

- Traces, logs and metrics all reached the viewer through the sandbox's `HTTPS_PROXY`, so the proxy risk is closed. `NODE_USE_ENV_PROXY` was not needed.
- `sandbox.name` and `sandbox.id` are in the resource attributes of every span (2/2) and log (34/34), and in the resource and series attributes of the metrics. `service.name` stays `claude-code`.
- Two sandboxes produce distinct names on all three signals.
- Query by sandbox in the viewer, for example: `otel-desktop-viewer query "SELECT resource.attributes.\"sandbox.name\"::VARCHAR AS sandbox, count(*) FROM spans GROUP BY 1"` (same for `logs`, `metric_records`).

### Checks 2 to 5: PASSED

- Stop/start: one marker line in `/etc/sandbox-persistent.sh` and in `~/.bashrc` after a restart (idempotent).
- Viewer down: `claude -p` still answers, 4.8s versus about 4.0s with the viewer up. No hang, no error.
- Policy log shows `localhost:4318` as the only kit-related egress. The other hosts are the Claude agent's own (api.anthropic.com, mcp-proxy, datadog intake) and the image's apt mirrors. Still unproven: that the allow rule is required, because this org policy is Allow_All.

### Bugs found and fixed

- `OTEL_RESOURCE_ATTRIBUTES` repeated per nested bash because env.sh appended to the inherited value. Fixed: it is now composed fresh each time. Consequence: an `OTEL_RESOURCE_ATTRIBUTES` set elsewhere in the sandbox is replaced; use the `extraResourceAttributes` arg instead.
- Viewer probe reported "reachable" while the viewer was down: `curl -s` exits 0 on the proxy's 502. Fixed with `curl -sf`. Verified both states.

### Findings to carry forward

- The built-in `claude` agent is itself a v3 kit (`docker.io/sbx/claude`), which is why a v3 mixin composes with it.
- Sandbox names can be reused after deletion (`otel-spike1` was removed and recreated), so `sandbox.id` is what separates two sandboxes with the same name.
- Side effect to document: the env file is sourced by every non-interactive bash in the sandbox (BASH_ENV), so other OpenTelemetry-instrumented programs run in the sandbox inherit the endpoint and exporter settings and would send to the viewer too, carrying the same `sandbox.*` attributes. Confirmed for Claude's own Bash tool (it sees all 10 `OTEL_*` variables). If this is unwanted, scope the vars to the `claude` process with a launcher wrapper (future option).
- `sbx kit validate ./kit` created the shared `sbx-kit-builder` sandbox on first use.

## Remaining work

Done 2026-11-10: wrapper, e2e test, README, and the Bash-tool check (Claude's Bash tool sees all 10 `OTEL_*` variables, documented in the README under Known behaviour).

Open, optional:
- Prove the `localhost:<port>` allow rule is required, on a machine with a restrictive (non-Allow_All) policy.
- Scope the variables to the `claude` process only (launcher wrapper) if the inheritance by other programs proves unwanted.
- Try `claude-bedrock`.
- Publish the kit to a registry (`docker buildx build -f kit/kit.yaml`).
