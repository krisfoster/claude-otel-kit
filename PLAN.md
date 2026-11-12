# Plan: Claude Code OpenTelemetry kit (v3) for Docker Sandboxes

Status: built, verified and documented. Current suites: `tests/install.sh` (55 checks), `tests/kit.sh` (30), `tests/wrapper.sh` (149) and `tests/e2e.sh` (about 80, real sandboxes), plus a fast GitHub Actions workflow on Ubuntu and macOS. Decisions below were approved on 2026-11-10 (all recommendations accepted); decision 3 was later changed to `none` (2026-11-12).

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

Args: `viewerPort` (default 4318), `capture` (`none|tools|full`, default `none`), `metricIntervalMs`, `extraResourceAttributes`, `accountIds` (default `false`, added after the 2026-11-10 review).

Capture mapping: `none` = nothing (the default); `tools` = `OTEL_LOG_TOOL_DETAILS=1`; `full` = also `OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_ASSISTANT_RESPONSES`, `OTEL_LOG_TOOL_CONTENT`. What each mode actually records, and where it appears, was measured (2026-11-12) and is tabulated in the README; `tests/e2e.sh` checks every cell of that table.

Host wrapper `bin/claude-otel` (kits cannot run host code): checks that `curl` and `ps` exist and that `otel-desktop-viewer` is installed (it prints an OS-specific install hint and exits if not), checks the port is listening (warns, `--start-viewer` starts one the wrapper owns, optional `--db FILE` for persistence), then `exec sbx run claude --kit kit/ ...`. For a sandbox that already exists (`--name` matches `sbx ls`) it reattaches with plain `sbx run`, because sbx only accepts `--kit` at create; the sandbox's own port is read from its env.

Install: `install.sh` symlinks `bin/claude-otel` into `~/.local/bin` (or `--bin-dir`), refuses to overwrite foreign files without `--force`, and `uninstall` only removes its own link. The wrapper resolves symlinks to find `kit/`. The kit needs no install.

Layout:

    kit/kit.yaml
    bin/claude-otel
    install.sh
    .github/workflows/ci.yml   fast checks only: Ubuntu (shellcheck + the three suites) and macOS (the suites, system bash 3.2); 3 minute cap per job
    tests/install.sh           installer and wrapper symlink handling (hermetic)
    tests/kit.sh               kit argument patterns (exhaustive for the port; real `sbx kit validate` if available)
    tests/wrapper.sh           the wrapper's decisions against a fake sbx and a fake viewer (hermetic)
    tests/e2e.sh               real sandboxes and Claude calls, run by hand
    README.md                  usage, capture modes and how to read captured text, known behaviour
    PLAN.md                    this file

## Decisions (approved)

| # | Decision | Choice |
|---|---|---|
| 1 | Env delivery | BASH_ENV file (not managed-settings drop-in: that runs as root, locks the endpoint, and a malformed file stops Claude starting) |
| 2 | Transport | `http/protobuf` on 4318 (not gRPC) |
| 3 | Content capture default | `none` (changed 2026-11-12 from `tools`, after measuring that `tools` records unmasked secrets); `tools` and `full` are opt-in |
| 4 | Identity | Resource attributes `sandbox.name` and `sandbox.id`; keep `service.name=claude-code`. Revisit if the viewer UI does not show resource attributes in trace lists. |
| 5 | Viewer-missing warning | Host wrapper plus best-effort in-sandbox probe |
| 6 | Kit location | `kit/` subdirectory |
| 7 | Viewer persistence | `--db` flag on the wrapper, default off |

Assumed: `claude` agent only (`claude-bedrock` untested), local directory use, no registry publishing yet.

## Risks

Original risks, and how they turned out:

- Whether Claude's OTLP exporter honours `HTTPS_PROXY`: **resolved**, it works (spike 1); `NODE_USE_ENV_PROXY` was not needed.
- Startup hook must finish before Claude launches: **resolved**, the env reached the agent in every run.
- Allow-rule form and necessity cannot be proven on an Allow_All org policy: **still open** (the form `localhost:<port>` matches what the sbx policy log records).
- gRPC through the sandbox proxy is unproven; not used: **still true**.

## Verification

(All six checks below were done; they are automated in `tests/e2e.sh`, and the hermetic suites cover the wrapper and installer.)

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
- Side effect to document: the env file is sourced by every non-interactive bash in the sandbox (BASH_ENV), so other OpenTelemetry-instrumented programs run in the sandbox inherit the endpoint and exporter settings and would send to the viewer too, carrying the same `sandbox.*` attributes. Confirmed for Claude's own Bash tool (it sees the `OTEL_*` variables (10 at the time of this spike; the count has since changed)). If this is unwanted, scope the vars to the `claude` process with a launcher wrapper (future option).
- `sbx kit validate ./kit` created the shared `sbx-kit-builder` sandbox on first use.

## Review follow-up (2026-11-11 and 2026-11-12)

An adversarial review of the repo (it attacked the code by running it: argument injection, old bash, re-runs, other env injection, whether the README's claims held) produced the fixes below. The review notes themselves are kept outside the repository; everything that matters is recorded here and in the README.

**Wrapper.**
- It reattaches to an existing sandbox instead of failing on `--kit`, reading that sandbox's own viewer port and warning when `--port` or `--capture` cannot apply (kit settings are fixed at create).
- It refuses a sandbox that belongs to another agent before running anything in it, and explains a failed `--start-viewer` (shows the viewer's own error, kills what it started, removes the pid file).
- `--stop-viewer` only signals a process that is verifiably an `otel-desktop-viewer` started with that exact port; a stale pid file is cleaned up without signalling anything.
- `claude-otel` options placed after sbx options now get a clear message instead of an sbx "unknown flag".
- It checks that `curl` and `ps` exist, and gives OS-specific viewer install hints.

**Kit and installer.**
- `accountIds` defaults to off, so `user.account_uuid` and `user.account_id` are not sent (`user.email`, `user.id` and `organization.id` always are; Claude Code does not allow turning them off).
- `viewerPort` is exactly 1025 to 65535 in both the kit and the wrapper (the floor is 1025 because `--start-viewer` uses the port below for gRPC).
- The installer replaces or removes a link left by a moved or deleted checkout without `--force`, needs `--force` for another live checkout's link, and never touches a foreign file or a real directory.

**Defaults and docs.**
- The default `capture` is now `none` (decision 3, changed 2026-11-12 at the owner's request): a measurement showed `tools` records some secret shapes in clear text. `tools` and `full` stay available per sandbox, and the README documents what each records, where to read it, and example queries that were run as written.
- The sbx floor is documented as v0.51.0 (the release where built-in agents became v3 kits), the viewer-down cost as measured (Claude Code's own exit-time retries add about 2 seconds to a one-shot `claude -p`), and sandbox names as forgeable labels (demonstrated).

**Platforms.** The host side targets macOS and Linux. Windows is not supported and gets a warning, not a refusal (native shells and WSL are detected through `uname`). Verified on macOS (bash 3.2 and 5) and Ubuntu 24.04. Not verified: `sbx` and the kit on a Linux host, and anything on Windows.

**Tests and CI.** `tests/wrapper.sh` (149 checks), `tests/install.sh` (55) and `tests/kit.sh` (30) are hermetic; the new checks were mutation-tested (each deliberately broken change was caught). `tests/e2e.sh` (80 checks, real sandboxes) polls instead of sleeping and checks every cell of the README's capture table. A GitHub Actions workflow runs shellcheck and the three fast suites on Ubuntu, and the suites on macOS under the system bash 3.2, only when code or tests change (no installs, 3 minute cap per job, superseded runs cancelled, actions pinned by SHA, linted with actionlint). First real runs (2026-11-11): the Ubuntu job took 29 seconds and the macOS job 20, 32 seconds in all; the macOS log confirms GNU bash 3.2.57; both jobs passed 55, 2 (plus 1 skipped: no `sbx` on the runners) and 149 checks. Running the suites on Ubuntu found and fixed a hidden dependence on an installed viewer.

**One unexplained observation: a run's spans occasionally missing.** In three early experiments, spans from some one-shot `claude -p` runs did not reach the viewer although the same runs' logs and metrics did. About 150 later runs produced a trace every time, so the cause is unknown. Ruled out by testing with a recording fake receiver and fault injection: repeated and back-to-back runs, piped output, idle gaps, a slow receiver (trace requests read up to 8 seconds late, logs and metrics answered up to 6 seconds late), a single failed export (Claude Code retries each failed export about three times), and parallel runs from one and two sandboxes (24 of 24 traces stored, no rejections). In a long-lived session spans are exported while it runs, and nothing more arrived at exit. If it recurs, capture the run's `claude --debug-file` log, the viewer's `ingest_rejections` table and `sbx policy log` for the sandbox at once.

## Remaining work

Decisions taken (2026-11-12): no Linux sandbox-side testing and no restrictive-policy testing for now (no environment available); the clean-first-run test is paused (it needs the shared `sbx-kit-builder` removed, which drops its build cache); Windows stays unsupported; the missing-spans observation gets one hour of soak testing (`tests/soak.py`).

Missing spans, current understanding: in short one-shot runs (about 3 seconds in all) the trace export can be lost entirely, or partly, while logs and metrics survive; in slower runs (about 7 seconds) it has not been seen. The recording relay in `tests/soak.py` showed the trace POST never leaving the sandbox in those runs. The speed of a run depends on factors outside the kit (API latency and what Claude Code's start-up has cached), which is why the loss came and went. Claude Code has undocumented settings that may bear on this (`CLAUDE_CODE_OTEL_SHUTDOWN_TIMEOUT_MS`, `CLAUDE_CODE_OTEL_FLUSH_TIMEOUT_MS`, `CLAUDE_CODE_EAGER_FLUSH`); they are being compared under identical conditions in the soak.

Open, optional:
- Prove the `localhost:<port>` allow rule is required, on a machine with a restrictive (non-allow-all) policy.
- A clean first run of the Quick start (paused).
- `sbx` and the kit on a Linux host (only the host scripts have been run on Linux); Windows is unsupported and untested.
- Scope the telemetry variables to the `claude` process only, if other programs in the sandbox inheriting them proves unwanted.
- Whether a different OTLP timeout shortens the roughly 2 second exit delay when the viewer is down (that delay is Claude Code's own retrying).
- `claude-bedrock` is untested.
- Publish the kit to a registry (`docker buildx build -f kit/kit.yaml`).
