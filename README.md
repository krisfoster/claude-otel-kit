# claude-otel: Claude Code OpenTelemetry for Docker Sandboxes

A v3 kit for [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`). It turns on Claude Code's [OpenTelemetry export](https://code.claude.com/docs/en/monitoring-usage) (traces, metrics and logs) inside a `claude` sandbox and sends it to [otel-desktop-viewer](https://github.com/CtrlSpice/otel-desktop-viewer) running on your machine. Every signal carries the sandbox name and id, so you can tell which sandboxed Claude produced a trace. It runs on macOS and Linux hosts; Windows is not currently supported (see *Supported platforms*).

```
sandbox (claude)  --OTLP/HTTP-->  sbx proxy  -->  otel-desktop-viewer on your host (localhost:4318)
   resource attributes: sandbox.name, sandbox.id, service.name=claude-code
```

## Quick start

You need a macOS or Linux machine, `sbx` (v0.51.0 or later, signed in) and [otel-desktop-viewer](https://github.com/CtrlSpice/otel-desktop-viewer) (install commands for each OS are under *Prerequisites*).

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

By default the kit records metadata only: no prompts, no replies, no command text. To see more in your traces, pick a capture mode when you first create the sandbox: `--capture tools` adds the commands Claude runs and file paths, and `--capture full` adds your prompts, Claude's replies and tool output. For example:

```
claude-otel --start-viewer --capture full --name otel-demo .
```

See *Capturing prompts, commands and output* below for exactly what each mode records, where to read it in the viewer, and what it means for secrets.

Run the same command again later to get back into that sandbox: when the name already exists, the wrapper reattaches instead of creating it. Pass `--name` so it knows which sandbox you mean.

```
# 3. Open the viewer in your browser (a second terminal is fine).
open http://localhost:8000          # macOS
xdg-open http://localhost:8000      # Linux (or just visit the URL)
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

## Supported platforms

claude-otel is for **macOS and Linux** hosts. **Windows is not currently supported.**

| Host | Wrapper, installer and the fast tests | `sbx` and the kit, end to end |
|---|---|---|
| macOS (Apple Silicon) | Run here with the system bash 3.2 and with bash 5; also run in CI | Tested (sbx v0.51.0) |
| Linux | Run on Ubuntu 24.04 (bash 5.2) in a container and in CI | Not tested: I have not run `sbx` on a Linux host |
| Windows | Not supported | Not supported |

On Windows (Git Bash, MSYS or Cygwin, and WSL) `claude-otel` and `install.sh` print a warning that Windows is not currently supported and then carry on, so expect failures rather than a clean refusal. Nothing here has been run on Windows. The kit itself (`kit/`) contains no host-specific code, so `sbx create claude --kit ./kit` is the part most likely to work, but that is untested too, and you would also need a viewer running and reachable on the OTLP port.

The host scripts need `bash` 3.2 or newer, `curl`, a `ps` that supports `ps -p PID -o command=` (macOS, and procps on Linux), and the usual tools (`awk`, `grep`, `sed`, `seq`, `nohup`, `ln`, `readlink`). They are all present by default on macOS and mainstream Linux distributions; `claude-otel` checks for `curl` and `ps` and says so if one is missing. Minimal BusyBox-based systems such as Alpine are not supported.

## Prerequisites

- `sbx` v0.51.0 or later, signed in. That is the release where the built-in agents (including `claude`) became published v3 kits ([release notes](https://docs.docker.com/ai/sandboxes/release-notes/)); the sbx docs say v3 kits cannot compose with older, non-v3 agents, so earlier versions are not expected to work with this kit (no earlier version was tried). Tested on v0.51.0.
- otel-desktop-viewer on the host, with the `query` command (v0.7.0 has it). The kit cannot install it for you. Install it for your OS:
  - **macOS:** `brew tap ctrlspice/otel-desktop-viewer && brew install --cask otel-desktop-viewer`. The viewer's README lists a prebuilt binary for Apple Silicon only; on an Intel Mac you would build it with `go install` (Go 1.26, CGO).
  - **Linux:** apt (Debian, Ubuntu) and dnf (Fedora, RHEL) repositories and release binaries for x86_64 and arm64 are available. The release binaries need glibc 2.39 or newer (Ubuntu 24.04+, Debian 13+, Fedora 40+). The exact commands are in the [viewer's README](https://github.com/CtrlSpice/otel-desktop-viewer#getting-started); check them before running, since they add a package repository.

## Install

The kit itself needs no install: `--kit ./kit` is read when a sandbox is created. The host wrapper is optional; to put it on your PATH:

```
./install.sh                      # symlinks ~/.local/bin/claude-otel -> this repo's bin/claude-otel
./install.sh --bin-dir DIR        # somewhere else
./install.sh uninstall            # removes the link, only if it points at this repo
```

It prints a note if the bin directory is not on your PATH, or if `sbx` or `otel-desktop-viewer` is missing. It never replaces or removes a file or directory that is not one of its own links. A link left behind by a checkout you moved or deleted is detected (it points at a `.../bin/claude-otel` that no longer exists) and is replaced by `install.sh`, or removed by `install.sh uninstall`, without `--force`. A link to *another* checkout that still exists needs `--force` to switch or remove, so one working checkout cannot silently hijack another's. The link points back into this checkout, so keep the repo where it is; `git pull` updates the wrapper and the kit together. Without installing, run `bin/claude-otel` by path.

## Use

With the host checks (recommended):

```
claude-otel --start-viewer --name my-sbx .
```

The wrapper checks that `curl` and `ps` exist, that the viewer is installed (it prints how to install it for your OS and stops if not), and that something is listening on the OTLP port (it warns if not, or starts one with `--start-viewer`), then runs `sbx run claude --kit kit/ ...`. Everything after its own options goes to `sbx run`, so put the wrapper's options first (`claude-otel --port 4319 --name my-sbx .`). If one turns up after an sbx option, the wrapper says so instead of letting `sbx` fail with "unknown flag". Options that take a value are written `--port N`, not `--port=N`.

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
| `viewerPort` | `4318` | OTLP/HTTP port of the viewer on the host, 1025 to 65535. This is also the one egress allow rule (`localhost:<port>`): the sandbox can reach that port on your machine, so give it only the viewer's port. |
| `capture` | `none` | What content goes into telemetry: `none` (metadata only), `tools` (adds command text and file paths) or `full` (adds your prompts, Claude's replies and tool output). Details, and how to read it back, in *Capturing prompts, commands and output* below. |
| `metricIntervalMs` | `10000` | Metrics export interval (Claude's default is 60000). |
| `extraResourceAttributes` | empty | Extra resource attributes, `key=value,key=value`, no spaces. |
| `accountIds` | `false` | Include `user.account_uuid` and `user.account_id`. Claude Code sends them by default; the kit turns them off. |

**Identifiers.** Claude Code attaches who you are to every span, log and metric. By default the kit removes `user.account_uuid` and `user.account_id` (`accountIds=false`), but `user.email`, `user.id` and `organization.id` are always sent and the kit cannot turn them off. They go to your local viewer only, but with `--db` they are written to disk, so treat that file as personal data.

## Capturing prompts, commands and output

By default (`capture=none`) the kit records metadata only: every model call and tool call is a span with its name, timing, token counts and cost, but no text. To record more, choose a mode when you create the sandbox:

```
claude-otel --start-viewer --capture tools --name my-sbx .   # adds commands and file paths
claude-otel --start-viewer --capture full  --name my-sbx .   # adds prompts, replies and tool output

# without the wrapper
sbx create claude --kit ./kit --kit-arg capture=full --name my-sbx .
```

The mode is fixed when the sandbox is created. To change it, `sbx rm my-sbx` and create it again (if you pass `--capture` for a sandbox that already exists, the wrapper warns that it is ignored). The modes are bundles of Claude Code's own switches: `tools` sets `OTEL_LOG_TOOL_DETAILS=1`, and `full` also sets `OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_ASSISTANT_RESPONSES` and `OTEL_LOG_TOOL_CONTENT`. The kit does not offer the switches one at a time, and never turns on raw API request and response bodies (`OTEL_LOG_RAW_API_BODIES`).

**What each mode records.** Tested with Claude Code 2.1.322 by running the same prompt in each mode and searching the viewer for text that could only have come from one source:

| | `none` | `tools` | `full` |
|---|---|---|---|
| Model calls and tool calls as spans (names, timing, tokens, cost) | yes | yes | yes |
| Text of Bash commands | no | yes | yes |
| File paths (Read, Edit, Write) | no | yes | yes |
| Your prompts | no | no | yes |
| Claude's replies | no | no | yes |
| Tool output (what a command printed, the text of a file Claude read) | no | no | yes |

Under `none` and `tools` the prompt and reply fields still exist but hold the literal text `<REDACTED>` next to a length (`prompt_length`, `response_length`), so a `<REDACTED>` in the viewer means capture is off, not that something went wrong.

**Where to read it in the viewer.**

- Your prompts: the `claude_code.user_prompt` log, attributes `prompt` and `prompt_text`; also the `claude_code.interaction` span, attribute `user_prompt`.
- Claude's replies: the `claude_code.assistant_response` log, attribute `response`.
- Commands: the `claude_code.tool` span, attribute `full_command` (also the `tool_input` and `tool_parameters` log attributes). File paths: the same span, attribute `file_path`.
- Tool output: the `tool.output` event on the `claude_code.tool` span, attribute `output` for commands and `content` for files read.

The log's event name is in its `body` column (in viewer v0.7.0 the `event_name` column is empty). These queries were run against a `capture=full` sandbox; to restrict any of them to one sandbox, add `AND resource.attributes."sandbox.name"::VARCHAR = 'my-sbx'` to its `WHERE` clause (before the `ORDER BY`):

```
# your prompts and Claude's replies, in order
otel-desktop-viewer query "SELECT timestamp, CAST(body AS VARCHAR) AS event, attributes.\"prompt\"::VARCHAR AS prompt, attributes.\"response\"::VARCHAR AS response FROM logs WHERE CAST(body AS VARCHAR) IN ('claude_code.user_prompt', 'claude_code.assistant_response') ORDER BY timestamp"

# the commands Claude ran
otel-desktop-viewer query "SELECT start_time, attributes.\"full_command\"::VARCHAR AS command FROM spans WHERE name = 'claude_code.tool' ORDER BY start_time"

# tool output, as the JSON events attached to each tool span
otel-desktop-viewer query "SELECT start_time, to_json(events) AS events FROM spans WHERE name = 'claude_code.tool' ORDER BY start_time"
```

**Secrets.** With `tools` the full text of every Bash command is recorded. Claude Code masks values it recognises as secrets, but that is pattern matching, not a guarantee. In a test with made-up values (one command per shape), these were masked or absent from telemetry: `export DB_PASSWORD=...`, `API_TOKEN=...`, `AWS_SECRET_ACCESS_KEY=...`, an `Authorization: Bearer ...` header, and a GitHub `ghp_...` token. These were recorded in clear text: a password inside a URL (`postgres://user:password@host/db`), an `sk-ant-...`-style key passed as a bare argument, and a password written in ordinary words. So do not rely on masking. `full` records everything above, including the contents of any file Claude reads, with no masking tested at all. The data goes to your local viewer only, but `--db` writes it to disk; keep `tools` and `full` for sandboxes whose work is safe to keep.

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
- **Viewer down is safe, but not free.** Claude runs normally and the export is dropped; nothing queues or errors. A one-shot `claude -p` was consistently about 2 seconds slower with the viewer down (mean 9.1s against 7.0s and 7.2s with it up, 5 runs each, 15 of 15 answered). The cause is Claude Code retrying: against a test receiver that refused every export, Claude made about three attempts per signal per run and the run took about 2 seconds longer. That cost is paid once, at exit; I measured it for one-shot runs only.
- **Kit settings are fixed at create.** To change `viewerPort`, `capture`, `accountIds` and so on, remove the sandbox and create a new one. The wrapper will not change them for an existing sandbox.
- **Names are labels, not proof.** Anything running in the sandbox can change `sandbox.name` and `sandbox.id`. In a test, putting `OTEL_RESOURCE_ATTRIBUTES="sandbox.name=some-other-sandbox,..."` in front of one `claude -p` command made all of that run's spans, logs and metrics arrive under the other name. Code in a sandbox can also send OTLP straight to the viewer claiming any name, and the viewer does not authenticate. Use the names to find your own telemetry, not for audit or security decisions.
- **What the kit opens on your machine.** One allow rule, for `localhost:<viewerPort>`, which is the viewer's OTLP receiver. That is a write path: a sandbox can add (or flood) telemetry. The viewer's query UI is on a different port that the kit does not open. Your own sbx policy can allow more than the kit asks for: on a machine with an allow-all policy, a sandbox could also reach the UI port (seen in testing).
- **A one-shot run can lose its trace.** For a `claude -p` run, the trace (spans) can be missing while the logs and metrics are present. The cause is inside Claude Code, not the kit: its telemetry waits for a remote managed-settings fetch before it starts, and when that fetch is not instant (about 0.25 s when it is not cached) the first turn can begin before telemetry is ready. A span created before that point is never recorded, and no error is shown. In a one-hour soak (`tests/soak.py`, 228 runs, the fast conditions the loss needs) 226 runs lost their trace (200 entirely, 26 keeping only the model-call span), and in all 226 the debug log shows telemetry initialising after the first turn started (by 0.15 s on average, at most 0.41 s); the runs that kept their trace had telemetry ready about 1.4 s before the turn. How often it happens depends on how quickly Claude Code's start-up goes, which varies with the API and what it has cached, so in slower conditions (runs of about 7 seconds) I saw almost no losses. Nothing in the kit can fix it: raising the flush and shutdown timeouts (`CLAUDE_CODE_OTEL_SHUTDOWN_TIMEOUT_MS`, `CLAUDE_CODE_OTEL_FLUSH_TIMEOUT_MS`), `CLAUDE_CODE_EAGER_FLUSH=1` and a span batch size of 1 each left 0 or 1 of 57 runs with a trace, and the only lever I found is bypassing remote managed settings, which a kit should not do. An interactive session (`sbx run`) should not be affected, because a person types the first prompt seconds after start-up (inferred from the mechanism; I could not test an interactive session while the fast conditions lasted), and a trace for any later prompt is not at risk. If you rely on one-shot runs, the logs and metrics for the session are always there (filter by `session.id`). To check a lost run, look in its `claude --debug-file` for `[engine] turn 1 start` appearing before `initializing telemetry`.
- **Org policy.** If your organization governs sandbox network or filesystem policy, it can still block the allow rule or mounts. `sbx policy log my-sbx` shows what was blocked.
- **Only the `claude` agent was tested.** `claude-bedrock` should behave the same but is untested.

## Test

The tests need `bash`, `curl` and `python3` on macOS or Linux; `e2e.sh` also needs `sbx`, a viewer with `query`, and a signed-in sbx. They use no `lsof` or other OS-specific tools. `e2e.sh` refuses to run if its ports (14318 and 18000) are already in use.

```
tests/install.sh    # fast: installer (links, stale and foreign files), wrapper symlinks, platform warnings and install hints
tests/wrapper.sh    # fast: the wrapper's decisions (create vs reattach, ports, stop, warnings, platforms, required tools) against a fake sbx
tests/kit.sh        # fast: the kit's argument patterns, checked exhaustively and against real `sbx kit validate`
tests/e2e.sh        # full: real sandboxes and Claude calls
tests/soak.py       # manual, not in CI: long runs with a recording relay, to study the occasional missing spans
```

`e2e.sh` creates five sandboxes, starts its own viewer on ports 14318 and 18000 (it never touches one you already run), makes real Claude calls (a few cents), and checks the env, the sandbox name on spans, logs and metrics, restart behaviour, the wrapper reattaching or refusing a sandbox of another agent, a viewer port clash, identifiers, what each capture mode records (every cell of the table above), the viewer-down case, kit args (including rejection of bad values) and the policy log. It cleans up after itself.

**CI.** `.github/workflows/ci.yml` runs on pushes to `main` and on pull requests, but only when `bin/`, `kit/`, `install.sh`, `tests/` or the workflow itself change (a README-only push does not run it). Two small jobs run side by side: Ubuntu runs `shellcheck` and the three fast suites, and macOS runs the same suites under the system bash 3.2, so both supported hosts are checked on every change. It is built to be cheap: nothing to install or cache, a 3-minute cap per job, and a run that a newer push has made pointless is cancelled. Measured on GitHub, a whole run takes about 30 seconds (the Ubuntu job about 30, the macOS job about 20). GitHub documents standard runners as free for public repositories; if this repo ever goes private, macOS minutes are billed at ten times the Linux rate, so delete the `macos` job to go back to Ubuntu only. `e2e.sh` is not in CI because it needs a real `sbx` and a Claude account, so run it by hand before a release.

See [PLAN.md](PLAN.md) for the design, decisions and spike results.

## License

Apache-2.0; see [LICENSE](LICENSE).
