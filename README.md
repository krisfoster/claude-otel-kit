# claude-otel: Claude Code OpenTelemetry for Docker Sandboxes

A v3 kit for [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`). It turns on Claude Code's [OpenTelemetry export](https://code.claude.com/docs/en/monitoring-usage) (traces, metrics and logs) inside a `claude` sandbox and sends it to [otel-desktop-viewer](https://github.com/CtrlSpice/otel-desktop-viewer) running on your machine. Every signal carries the sandbox name and id, so you can tell which sandboxed Claude produced a trace.

```
sandbox (claude)  --OTLP/HTTP-->  sbx proxy  -->  otel-desktop-viewer on your host (localhost:4318)
   resource attributes: sandbox.name, sandbox.id, service.name=claude-code
```

## Quick start

You need `sbx` (v0.51.0 or later, signed in) and [otel-desktop-viewer](https://github.com/CtrlSpice/otel-desktop-viewer) (`brew tap ctrlspice/otel-desktop-viewer && brew install --cask otel-desktop-viewer`).

```
# 1. Get it and put the claude-otel command on your PATH
git clone https://github.com/krisfoster/claude-otel-kit
cd claude-otel-kit
./install.sh

# 2. Start a Claude sandbox on this repo with the kit applied.
#    --start-viewer launches the viewer if it is not already running.
claude-otel --start-viewer --name otel-demo .
```

Claude opens in the sandbox. Send it a prompt, for example `list the files in this repo and summarise them`.

Run the same command again later to get back into that sandbox: when the name already exists, the wrapper reattaches instead of creating it. Pass `--name` so it knows which sandbox you mean.

```
# 3. Open the viewer in your browser (a second terminal is fine).
#    `open` is macOS; elsewhere just visit the URL.
open http://localhost:8000
```

Each prompt shows up as a trace (`claude_code.interaction`) with a span per model call and per tool call, plus matching logs and metrics. Every span, log and metric carries `sandbox.name=otel-demo` and a `sandbox.id`, which is how you match telemetry to the sandbox. To check from the terminal:

```
otel-desktop-viewer traces --since 10m
otel-desktop-viewer query 'SELECT DISTINCT resource.attributes."sandbox.name"::VARCHAR AS sandbox FROM spans'
```

When you are done:

```
sbx rm otel-demo                                      # remove the sandbox
claude-otel --stop-viewer                             # stop the viewer the wrapper started
```

The rest of this page covers installation options, the kit's arguments, and how it works.

## Prerequisites

- `sbx` v0.51.0 or later, signed in. That is the release where the built-in agents (including `claude`) became published v3 kits ([release notes](https://docs.docker.com/ai/sandboxes/release-notes/)); the sbx docs say v3 kits cannot compose with older, non-v3 agents, so earlier versions are not expected to work with this kit (no earlier version was tried). Tested on v0.51.0.
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

Wrapper options: `--port N`, `--ui-port N`, `--capture none|tools|full`, `--start-viewer`, `--db FILE`, `--stop-viewer`, `--check` (host checks only), `-h`.

**Stopping the viewer.** `--start-viewer` leaves the viewer running after the sandbox exits, so it can keep collecting. Stop it with `claude-otel --stop-viewer` (add `--port N` if you started it on another port). It only stops a viewer that claude-otel itself started: it reads the recorded pid, checks that the process is really an `otel-desktop-viewer` started on that port, and only then sends it SIGTERM. A leftover pid file from a reboot or crash, even one whose number now belongs to an unrelated process, is cleaned up without signalling anything, and a viewer you started yourself is never touched.

**If `--start-viewer` cannot start the viewer** (typically a port is already taken: the viewer uses the OTLP port, the next-lower port for gRPC, and a UI port, default 8000), the wrapper stops, prints the reason from the viewer's log, removes its pid file and does not leave a half-started viewer behind. Pass `--ui-port N` or `--port N` to move it. `CLAUDE_OTEL_START_WAIT=SECONDS` changes how long it waits for the viewer to answer (default 15).

**Existing sandboxes.** `sbx` only accepts `--kit` when it creates a sandbox, and the kit's settings are fixed at that point. So when `--name` matches a sandbox that already exists, the wrapper reattaches with plain `sbx run` and reads the sandbox's own viewer port to check the host. If you also pass `--port` or `--capture` it warns that they are ignored (to change them, `sbx rm NAME` and run again), and if the sandbox was created without this kit it warns that it sends no telemetry. If `--name` belongs to a sandbox of another agent (for example `shell`), the wrapper refuses before touching it, because this kit only sets up `claude` sandboxes.

## Kit arguments

Pass with `--kit-arg name=value` (the wrapper sets `viewerPort` and `capture` for you).

| Arg | Default | Meaning |
|---|---|---|
| `viewerPort` | `4318` | OTLP/HTTP port of the viewer on the host. Also the one egress allow rule (`localhost:<port>`). |
| `capture` | `tools` | `none`: metadata only (tool calls appear as spans, but no command text or file paths). `tools`: also the full text of Bash commands and file paths. `full`: also prompts, responses and tool output. |
| `metricIntervalMs` | `10000` | Metrics export interval (Claude's default is 60000). |
| `extraResourceAttributes` | empty | Extra resource attributes, `key=value,key=value`, no spaces. |
| `accountIds` | `false` | Include `user.account_uuid` and `user.account_id`. Claude Code sends them by default; the kit turns them off. |

`capture=full` puts your prompts and file contents into telemetry. It stays on your machine, but treat the viewer's data accordingly.

**Commands and secrets.** With the default `capture=tools`, the full text of every Bash command Claude runs is recorded. Claude Code masks values it recognises as secrets, but that is pattern matching, not a guarantee. In a test with made-up values (Claude Code 2.1.322, one command per shape), these were masked or absent from telemetry: `export DB_PASSWORD=...`, `API_TOKEN=...`, `AWS_SECRET_ACCESS_KEY=...`, an `Authorization: Bearer ...` header, and a GitHub `ghp_...` token. These were recorded in clear text: a password inside a URL (`postgres://user:password@host/db`), an `sk-ant-...`-style key passed as a bare argument, and a password written in ordinary words. So do not rely on masking. If commands may contain secrets, use `capture=none`: the same test found no command text anywhere in telemetry, while the tool spans were still recorded. `--db` writes whatever was captured to disk.

**Identifiers.** Claude Code attaches who you are to every span, log and metric. By default the kit removes `user.account_uuid` and `user.account_id` (`accountIds=false`), but `user.email`, `user.id` and `organization.id` are always sent and the kit cannot turn them off. They go to your local viewer only, but with `--db` they are written to disk, so treat that file as personal data.

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

1. A file, `/home/agent/.local/share/claude-otel-kit/env.sh`, written at create with the args expanded. It exports `CLAUDE_CODE_ENABLE_TELEMETRY`, `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` (this turns on traces), the three `OTEL_*_EXPORTER` variables, `http/protobuf` to `http://host.docker.internal:<port>`, the capture flags, `OTEL_METRICS_INCLUDE_ACCOUNT_UUID` (from `accountIds`), and `OTEL_RESOURCE_ATTRIBUTES` built from `$SANDBOX_NAME` and `$SANDBOX_ID` when the shell starts.
2. A startup hook (every boot, idempotent) that sources that file from `/etc/sandbox-persistent.sh` (the `BASH_ENV` file, which is how the agent launch gets it) and from `~/.bashrc` (so a `claude` you start from `sbx exec -it` gets it too).
3. A second, background startup hook that probes the viewer and writes `/home/agent/.local/share/claude-otel-kit/status`. Read it with `sbx exec my-sbx cat /home/agent/.local/share/claude-otel-kit/status`.

Why these choices:

- **Environment, not settings files.** The sandbox's `~/.claude/settings.json` is already populated, and Claude Code ignores OTEL exporter variables in project and local settings. A managed-settings drop-in would work but needs root, locks the endpoint, and a malformed file stops Claude starting.
- **`http/protobuf` on 4318, not gRPC.** The sandbox's egress is an HTTP proxy. HTTP works through it; gRPC was not tried.
- **`host.docker.internal` for the endpoint, `localhost` in the allow rule.** Inside the VM `localhost` is the VM itself, so the exporter must use `host.docker.internal`. The sbx proxy translates that to `localhost` before matching policy, and its log records `localhost:<port>`.
- **Resource attributes, not `service.name`.** `service.name` stays `claude-code` so one query covers every sandbox.

## Known behaviour

- **Other programs in the sandbox inherit the settings.** The env file is sourced by every non-interactive bash, so anything you run in the sandbox (including through Claude's Bash tool, which sees the `OTEL_*` variables) that uses an OpenTelemetry SDK will also send to the viewer, with the same `sandbox.*` attributes. `OTEL_SDK_DISABLED=true` in front of a command should opt it out (a standard OpenTelemetry variable; not tested here).
- **`OTEL_RESOURCE_ATTRIBUTES` is replaced, not extended.** Add attributes with `extraResourceAttributes`.
- **Viewer down is safe, but not free.** Claude runs normally and the export is dropped; nothing queues or errors. A one-shot `claude -p` was consistently about 2 seconds slower with the viewer down (mean 9.1s against 7.0s and 7.2s with it up, 5 runs each, 15 of 15 answered), most likely the exit-time flush waiting on the failed export. Interactive sessions and long runs were not measured.
- **Kit settings are fixed at create.** To change `viewerPort`, `capture`, `accountIds` and so on, remove the sandbox and create a new one. The wrapper will not change them for an existing sandbox.
- **Org policy.** If your organization governs sandbox network or filesystem policy, it can still block the allow rule or mounts. `sbx policy log my-sbx` shows what was blocked.
- **Only the `claude` agent was tested.** `claude-bedrock` should behave the same but is untested.

## Test

The tests need `bash`, `curl` and `python3`; `e2e.sh` also needs `sbx`, a viewer with `query`, and a signed-in sbx. `e2e.sh` refuses to run if its ports (14318 and 18000) are already in use.

```
tests/install.sh    # fast: installer and wrapper symlink handling, no sandboxes or API calls
tests/wrapper.sh    # fast: the wrapper's decisions (create vs reattach, ports, warnings) against a fake sbx
tests/e2e.sh        # full: real sandboxes and Claude calls
```

`e2e.sh` creates five sandboxes, starts its own viewer on ports 14318 and 18000 (it never touches one you already run), makes real Claude calls (a few cents), and checks the env, the sandbox name on spans, logs and metrics, restart behaviour, the wrapper reattaching or refusing a sandbox of another agent, a viewer port clash, identifiers, the viewer-down case, kit args (including rejection of bad values) and the policy log. It cleans up after itself.

See [PLAN.md](PLAN.md) for the design, decisions and spike results.
