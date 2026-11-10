# claude-otel: Claude Code OpenTelemetry for Docker Sandboxes

A v3 kit for [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`). It turns on Claude Code's [OpenTelemetry export](https://code.claude.com/docs/en/monitoring-usage) (traces, metrics and logs) inside a `claude` sandbox and sends it to [otel-desktop-viewer](https://github.com/CtrlSpice/otel-desktop-viewer) running on your machine. Every signal carries the sandbox name and id, so you can tell which sandboxed Claude produced a trace.

```
sandbox (claude)  --OTLP/HTTP-->  sbx proxy  -->  otel-desktop-viewer on your host (localhost:4318)
   resource attributes: sandbox.name, sandbox.id, service.name=claude-code
```

## Prerequisites

- `sbx` v0.45 or later (v3 kits), signed in.
- otel-desktop-viewer on the host, with the `query` command (v0.7.0 has it). The kit cannot install it for you.
  ```
  brew tap ctrlspice/otel-desktop-viewer && brew install --cask otel-desktop-viewer
  ```
  Other install methods are in the [viewer README](https://github.com/CtrlSpice/otel-desktop-viewer#installation).

## Install

The kit itself needs no install: `--kit ./kit` is read when a sandbox is created. The host wrapper is optional; to put it on your PATH:

```
./install.sh                      # symlinks ~/.local/bin/claude-otel -> this repo's bin/claude-otel
./install.sh --bin-dir DIR        # somewhere else
./install.sh uninstall            # removes the link, only if it points at this repo
```

It prints a note if the bin directory is not on your PATH, or if `sbx` or `otel-desktop-viewer` is missing. It never overwrites a file it did not create unless you pass `--force`. The link points back into this checkout, so keep the repo where it is; `git pull` updates the wrapper and the kit together. Without installing, run `bin/claude-otel` by path.

## Use

With the host checks (recommended):

```
claude-otel --start-viewer --name my-sbx .
```

The wrapper checks the viewer is installed (prints the install command and stops if not), checks something is listening on the OTLP port (warns if not, or starts one with `--start-viewer`), then runs `sbx run claude --kit kit/ ...`. Everything after its own options goes to `sbx run`.

Or use the kit directly:

```
sbx create claude --kit ./kit --name my-sbx .
sbx run my-sbx
```

Start the viewer yourself with `otel-desktop-viewer` (UI on http://localhost:8000). It stores data in memory by default; pass `--db FILE` to the viewer (or to the wrapper with `--start-viewer`) to keep it between runs.

Wrapper options: `--port N`, `--ui-port N`, `--capture none|tools|full`, `--start-viewer`, `--db FILE`, `--check` (host checks only), `-h`.

## Kit arguments

Pass with `--kit-arg name=value` (the wrapper sets `viewerPort` and `capture` for you).

| Arg | Default | Meaning |
|---|---|---|
| `viewerPort` | `4318` | OTLP/HTTP port of the viewer on the host. Also the one egress allow rule (`localhost:<port>`). |
| `capture` | `tools` | `none`: metadata only. `tools`: also tool names, commands and file paths. `full`: also prompts, responses and tool output. |
| `metricIntervalMs` | `10000` | Metrics export interval (Claude's default is 60000). |
| `extraResourceAttributes` | empty | Extra resource attributes, `key=value,key=value`, no spaces. |

`capture=full` puts your prompts and file contents into telemetry. It stays on your machine, but treat the viewer's data accordingly.

## Finding one sandbox's telemetry

Each signal's resource carries `sandbox.name` (the name you gave `sbx`) and `sandbox.id`. Names can be reused after a sandbox is deleted, so use `sandbox.id` to separate two sandboxes with the same name.

```
otel-desktop-viewer query 'SELECT resource.attributes."sandbox.name"::VARCHAR AS sandbox, count(*) AS spans FROM spans GROUP BY 1'
otel-desktop-viewer query 'SELECT name, start_time, end_time FROM spans WHERE resource.attributes."sandbox.name"::VARCHAR = '"'my-sbx'"' ORDER BY start_time DESC' --limit 20
otel-desktop-viewer query 'SELECT count(*) FROM logs WHERE resource.attributes."sandbox.name"::VARCHAR = '"'my-sbx'"
otel-desktop-viewer query 'SELECT count(*) FROM metric_records WHERE resource.attributes."sandbox.name"::VARCHAR = '"'my-sbx'"
```

Metrics also carry `sandbox.name` and `sandbox.id` on each series (`metric_series.attributes`). `otel-desktop-viewer attributes values sandbox.name` lists the names seen so far.

To let a coding agent on the host inspect the data read-only, install the viewer's skill: `npx skills add CtrlSpice/otel-desktop-viewer --skill otel-desktop-viewer`, or print its guide with `otel-desktop-viewer skills`.

## How it works

`kit/kit.yaml` is a declaration-only v3 mixin on the built-in `claude` agent. It declares three things:

1. A file, `/home/agent/.local/share/claude-otel-kit/env.sh`, written at create with the args expanded. It exports `CLAUDE_CODE_ENABLE_TELEMETRY`, `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` (this turns on traces), the three `OTEL_*_EXPORTER` variables, `http/protobuf` to `http://host.docker.internal:<port>`, the capture flags, and `OTEL_RESOURCE_ATTRIBUTES` built from `$SANDBOX_NAME` and `$SANDBOX_ID` when the shell starts.
2. A startup hook (every boot, idempotent) that sources that file from `/etc/sandbox-persistent.sh` (the `BASH_ENV` file, which is how the agent launch gets it) and from `~/.bashrc` (so a `claude` you start from `sbx exec -it` gets it too).
3. A second, background startup hook that probes the viewer and writes `/home/agent/.local/share/claude-otel-kit/status`. Read it with `sbx exec my-sbx cat /home/agent/.local/share/claude-otel-kit/status`.

Why these choices:

- **Environment, not settings files.** The sandbox's `~/.claude/settings.json` is already populated, and Claude Code ignores OTEL exporter variables in project and local settings. A managed-settings drop-in would work but needs root, locks the endpoint, and a malformed file stops Claude starting.
- **`http/protobuf` on 4318, not gRPC.** The sandbox's egress is an HTTP proxy. HTTP works through it; gRPC was not tried.
- **`host.docker.internal` for the endpoint, `localhost` in the allow rule.** Inside the VM `localhost` is the VM itself, so the exporter must use `host.docker.internal`. The sbx proxy translates that to `localhost` before matching policy, and its log records `localhost:<port>`.
- **Resource attributes, not `service.name`.** `service.name` stays `claude-code` so one query covers every sandbox.

## Known behaviour

- **Other programs in the sandbox inherit the settings.** The env file is sourced by every non-interactive bash, so anything you run in the sandbox (including through Claude's Bash tool, which sees the 10 `OTEL_*` variables) that uses an OpenTelemetry SDK will also send to the viewer, with the same `sandbox.*` attributes. `OTEL_SDK_DISABLED=true` in front of a command should opt it out (a standard OpenTelemetry variable; not tested here).
- **`OTEL_RESOURCE_ATTRIBUTES` is replaced, not extended.** Add attributes with `extraResourceAttributes`.
- **Viewer down is safe.** Claude runs normally and the export is dropped; there is no measurable slowdown.
- **Kit settings are fixed at create.** To change `viewerPort`, `capture` and so on, create a new sandbox.
- **Org policy.** If your organization governs sandbox network or filesystem policy, it can still block the allow rule or mounts. `sbx policy log my-sbx` shows what was blocked.
- **Only the `claude` agent was tested.** `claude-bedrock` should behave the same but is untested.

## Test

```
tests/install.sh    # fast: installer and wrapper symlink handling, no sandboxes or API calls
tests/e2e.sh        # full: real sandboxes and Claude calls
```

`e2e.sh` creates three sandboxes, starts its own viewer on ports 14318 and 18000 (it never touches one you already run), makes real Claude calls (a few cents), and checks the env, the sandbox name on spans, logs and metrics, restart behaviour, the viewer-down case, kit args and the policy log. It cleans up after itself.

See [PLAN.md](PLAN.md) for the design, decisions and spike results.
