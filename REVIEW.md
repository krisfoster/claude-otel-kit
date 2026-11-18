# Adversarial review

Reviewed 2026-11-10 at commit `c6707b3`, on macOS with sbx v0.51.0, Claude Code 2.1.322 in the sandbox and otel-desktop-viewer v0.7.0. The review attacked the repo by running it: argument injection, old-bash compatibility, behaviour on re-runs, coexistence with other env injection, and whether the README's claims hold. Throwaway sandboxes were used and removed.

No critical issues were found. Findings 1 to 3 were the ones worth fixing before promoting the repo; they were fixed on 2026-11-11 (see the **Fixed** note under each). Findings 4 and 5 were fixed the same day, and so were 6 to 8 (see the **Fixed** notes). Finding 9 was fixed on 2026-11-12 (polling instead of sleeps; the remaining caveats are noted there), 10 is partly addressed (Linux host scripts now tested; sbx on Linux, a clean first run and a restrictive org policy are not), 11 went away incidentally, 12 to 16 were found and fixed in later passes, and 17 is explained (a Claude Code start-up race) but not fixable by the kit. "Verified" means reproduced; "reasoned" means argued from the code but not run.

## Findings

### 1. Medium: the wrapper cannot reattach to its own sandbox (verified)

Running `claude-otel --name otel-demo .` a second time fails:

    error: sandbox 'adv-1' already exists; --kit can only be used when creating a new sandbox

The Quick start is therefore not re-runnable. Passing a different `--capture` or `--port` to an existing sandbox cannot work either, because kit args are fixed at create. The wrapper's host check also runs against the new `--port`, so it can pass while the existing sandbox points at a different one.

Fix: parse `--name`, check `sbx ls`, and when the sandbox exists run `sbx run NAME` without the kit args, warning that they are ignored. Add a test for it.

**Fixed 2026-11-11.** `bin/claude-otel` now reattaches when `--name` matches an existing sandbox. It reads that sandbox's own viewer port (from `OTEL_EXPORTER_OTLP_ENDPOINT` inside it) for the host check, warns when `--port` or `--capture` are ignored, and warns when the sandbox was made without the kit. Verified against real `sbx`. While testing, a second bug appeared and was fixed: for an existing sandbox without the kit, `grep` found no endpoint and `set -e -o pipefail` made the wrapper exit silently. Tests: `tests/wrapper.sh` (26 hermetic checks against a fake `sbx`) and a reattach section in `tests/e2e.sh`. Not handled: re-running without `--name`, where `sbx` decides.

### 2. Medium: identifiers are in every signal and the README does not say so (verified)

With default settings the metrics carry `user.email`, `user.id`, `user.account_uuid` and `organization.id`, alongside `session.id`. This is Claude Code's default behaviour (`OTEL_METRICS_INCLUDE_ACCOUNT_UUID` defaults to true), not something the kit adds, but the kit makes it flow to the viewer. With `--db` it is written to disk.

Fix: document it in the README, and consider setting `OTEL_METRICS_INCLUDE_ACCOUNT_UUID=false` by default.

**Fixed 2026-11-11.** New kit arg `accountIds` (default `false`) sets `OTEL_METRICS_INCLUDE_ACCOUNT_UUID`. Verified on spans, logs and metrics: by default `user.account_uuid` and `user.account_id` are gone; with `accountIds=true` they return. `user.email`, `user.id` and `organization.id` are sent either way and the kit cannot remove them; the README now says so, and that `--db` writes them to disk. e2e checks both settings and that `user.email` is still present.

### 3. Medium: two README claims are stronger than the evidence

- "No measurable slowdown" with the viewer down. Measured 4.8s with the viewer down against about 4.0s with it up, one run each. That is inconclusive, and long sessions were not tried.
- "sbx v0.45 or later". Only v0.51 was tested. sbx v0.51 reports that `claude` "now ships as a kit", so on an earlier version the built-in agent may not be a v3 kit and a v3 mixin may not compose with it.

Fix: reword to what was measured ("tested on sbx v0.51"; "Claude kept working with the viewer down") and test an older sbx if the floor matters.

**Fixed 2026-11-11, and the first claim was worse than inconclusive.** A proper measurement (`claude -p` in one sandbox, 5 runs per condition after a warm-up) showed the viewer being down costs about 2 seconds: up 6.97s mean (6.66 to 7.35), down 9.06s (8.49 to 10.15), up again 7.24s (6.58 to 7.65). The ranges do not overlap, and all 15 runs answered correctly. The README now states this. It is most likely the exit-time flush waiting on the failed export; interactive sessions and long runs were not measured. For the version floor, the sbx release notes show v0.51.0 (2026-11-03) is where built-in agents became published v3 kits, so the README now says v0.51.0 or later (tested on v0.51.0) and explains why; earlier versions were not run.

### 4. Low to medium: a stale pid file can point `kill` at the wrong process (reasoned)

The README tells users to run `kill $(cat ~/.local/state/claude-otel/viewer-4318.pid)`. The wrapper never removes the file. After a reboot or a viewer crash, a reused PID could belong to an unrelated process.

Fix: add `claude-otel --stop-viewer` that checks the process is `otel-desktop-viewer` before killing, and remove the pid file when the viewer is gone.

**Fixed 2026-11-11.** `claude-otel --stop-viewer [--port N]` reads the pid file and only signals the process if its command line contains `otel-desktop-viewer` and `--http <port>` followed by a space (so port 4318 does not match a viewer on 43180). Otherwise it removes the stale file, says why, and kills nothing. It also handles a dead pid, a malformed file, no file (and notes when something else is listening, which it leaves alone), a process that ignores SIGTERM (exits 1, keeps the file), and works without `sbx` or the viewer installed. The README and the start-up message now use it instead of `kill $(cat ...)`. Tests: 25 hermetic cases with live fake processes in `tests/wrapper.sh`, including a stale pid pointing at an unrelated live process (it survives), and the real-viewer case in `tests/e2e.sh`.

### 5. Low: `capture=tools` records full commands, and secret redaction is heuristic (verified)

Tool spans carry `full_command`. In a test, `echo API_TOKEN=hunter2-not-a-real-secret` was recorded as `echo API**** && ls /etc | head -3`, and the secret value appeared nowhere in spans or logs. That redaction is Claude Code's own and pattern-based, so other secret shapes may pass through.

Fix: say in the README that `tools` can capture secrets typed into commands, and that `capture=none` avoids it.

**Fixed 2026-11-11, with a broader measurement than the original single case.** Nine fake commands, run in a `tools` and a `none` sandbox (Claude Code 2.1.322, one command per shape), then searched for the secret value across spans and logs. Masked or absent under `tools`: `export DB_PASSWORD=...`, `API_TOKEN=...`, `AWS_SECRET_ACCESS_KEY=...`, a `Bearer` header, a `ghp_...` token. Recorded in clear text under `tools`: a password in a URL (`postgres://admin:s3cretpw@...`), an `sk-ant-api03-...`-style key as a bare argument, a password in plain words, and a control marker. Under `none`: no command text in any row, but all nine tool spans still exist. So the original observation was real but understated: masking misses common shapes. The README now lists both groups and recommends `capture=none` when commands may contain secrets. `tests/e2e.sh` checks the two documented behaviours (command text present under `tools`, absent under `none`, tool spans still recorded) without asserting on Claude Code's own masking, which could change. **Resolved 2026-11-12:** the owner chose to change the default `capture` to `none`; `tools` is opt-in. The README, the kit, the wrapper help and the e2e (the default is checked to set no content flags and to record no command text) were updated.

### 6. Low: `uninstall` cannot clean up after a moved repo (verified)

If the checkout is moved or renamed, the installed link dangles. Both `install.sh` and `install.sh uninstall` then refuse to touch it ("not a link to this repo") unless `--force` is used, and uninstall has no `--force`, so the user has to `rm` it by hand.

Fix: treat a dangling link whose target path ends in `/bin/claude-otel` as removable, or let `uninstall` accept `--force`.

**Fixed 2026-11-11.** `install.sh` now classifies what is at the link: ours, stale (dangling, pointing at a `.../bin/claude-otel` that no longer exists), another live checkout, a real directory, or foreign. A stale link is replaced by `install` and removed by `uninstall` without `--force`; this covers a moved checkout, a deleted one (uninstall from any other checkout), and relative links. A link to another live checkout needs `--force` to switch or remove; a foreign file or link is never removed (and install needs `--force` to replace it); a real directory is never touched, even with `--force`. `tests/install.sh` grew from 16 to 40 checks, mutation-checked by reverting to the old behaviour.

### 7. Low: the port argument is loose (verified)

`viewerPort` has pattern `^[0-9]{2,5}$`, which accepts `00` and `99999`. Any valid value also opens that host loopback port to the sandbox, so `5432` would expose a local database. This is by design, since the user chooses the port, but nothing bounds it.

Fix: restrict to 1024 to 65535 with a tighter pattern, and say in the README that the port is opened to the sandbox.

**Fixed 2026-11-11.** The kit's `viewerPort` pattern is now exactly 1025 to 65535 (verified against every integer from 0 to 99999 and against malformed strings; also accepted and rejected correctly by the real `sbx kit validate`). The floor is 1025, not 1024, because `--start-viewer` puts gRPC on the port below and 1023 is privileged. The wrapper's `--port` enforces the same range and rejects leading zeros. The README states that the sandbox can reach the chosen port on the host. New `tests/kit.sh` (30 checks) and 26 more wrapper checks; reverting to the old pattern fails them.

### 8. Low: attribution is self-asserted (reasoned)

`sandbox.name` and `sandbox.id` are set by a process inside the sandbox. Code running in sandbox A can send OTLP to the allowed port claiming to be sandbox B, or overwrite its own attributes. The viewer has no authentication. This is a labelling aid, not a security boundary.

Fix: state this in the README.

**Fixed 2026-11-11 (documented), after demonstrating it.** In a real sandbox, setting `OTEL_RESOURCE_ATTRIBUTES="sandbox.name=some-other-sandbox,sandbox.id=forged"` on one `claude -p` command made all of that run's logs (34), metrics (4) and spans (2) arrive under `some-other-sandbox`; the honest run in the same sandbox arrived under its real name. The README now has two notes: names are labels not proof, and what the kit opens on the host (one OTLP write path; a more permissive sbx policy can allow more, which was seen with an allow-all policy). Nothing in the kit can prevent forgery, so no code change.

### 9. Low: test gaps

- `tests/e2e.sh` waits a fixed `sleep 8` for telemetry instead of polling.
- The Claude Bash tool check is informational only, because the model's output is not deterministic.
- Nothing tested `capture=none`, the pattern rejections, re-running on an existing sandbox, or tool spans. **Now covered** in `tests/e2e.sh` and `tests/wrapper.sh` (tool spans are checked under `capture=none`).
- The e2e suite needs a live Claude account (a few cents) and depends on org policy.
- shellcheck reports only style notes (SC2015, SC2016) in `tests/e2e.sh`.

**Updated 2026-11-12.** The fixed `sleep`s in `tests/e2e.sh` (8 s, 8 s and 5 s) are now polling: it waits up to 45 seconds for each signal from each sandbox to arrive, for the positive evidence before each absence check, and for the status file to change, and the short fixture waits in `tests/wrapper.sh` poll too (they would have been the first things to flake on a slow CI runner). The e2e passes 66 of 66 in 57 seconds. `tests/e2e.sh` also refuses to run if its ports are busy. Still true: the e2e needs a live Claude account, and the Bash-tool check is informational.

### 10. Low: untested conditions

- Linux hosts.
- A clean first run on a machine that has never built a v3 source kit (the kit builder sandbox needs network and was already cached here).
- A restrictive org network or filesystem policy. The review machine's policy is Allow_All, so whether the `localhost:<port>` allow rule is required is still unproven.
- gRPC transport (deliberately not used).

**Partly addressed 2026-11-12.** Linux: the host-side scripts (`bin/claude-otel`, `install.sh`) and the three fast suites were run on a fresh Ubuntu 24.04 container (bash 5.2, python 3.12, shellcheck 0.9): shellcheck clean, 40, 2 (plus 1 skipped, needing `sbx`) and 116 checks pass, about 7 seconds. That run found a real defect in the tests: four installer checks assumed `otel-desktop-viewer` was installed on the machine, so they would have failed on any CI runner; they now use a stub. What Linux evidence still lacks is the sandbox side (`sbx` and the kit itself on a Linux host), a clean first run (the kit builder) and a restrictive org policy.

**Further 2026-11-12.** Host-side portability was then tightened: OS-specific viewer install hints (the old hint was Homebrew only), a `curl`/`ps` check, no `lsof` in the e2e, a README "Supported platforms" section, and a warning (not a refusal) on Windows and WSL, all covered by hermetic tests that fake `uname`. CI now also runs the fast suites on macOS under bash 3.2, so both supported hosts are checked on every change; its first real run (2026-11-11) passed: the Ubuntu job in 29 seconds and the macOS job in 20, on GNU bash 3.2.57, 32 seconds in all.

### 11. Info

The README said Claude's Bash tool sees "the 10 `OTEL_*` variables". The count depends on `capture` and kit version. **Fixed 2026-11-11:** the README no longer states a number (it is 11 now that `accountIds` adds a variable).

## What held up

- Argument injection: `extraResourceAttributes` with `";touch /tmp/pwned;"`, `$(id)` and a space, `viewerPort=4318;id` and `abc`, `metricIntervalMs=1;id`, and `capture=full;id` or `bogus` were all rejected by sbx at validation, before any value reached the generated shell file. No `/tmp/pwned` appeared.
- Old bash: the wrapper, `install.sh` and `tests/install.sh` all work on macOS's bash 3.2.57.
- Other env injection: a sandbox created with `-e FOO=bar` kept `FOO` and the kit's variables, and restarts did not duplicate the `source` lines.
- `capture=none` sets no `OTEL_LOG_*` variables.
- Tool-using prompts produce the expected spans: `claude_code.interaction`, two `claude_code.llm_request`, `claude_code.tool`, `claude_code.tool.execution` and `claude_code.tool.blocked_on_user`.
- The repo itself contains no personal paths, emails, tokens or org-specific names.

## Suggested order

1. ~~Fix finding 1 (reattach) and add a test.~~ Done.
2. Fix the README for findings 7 and 8 (2, 3 and 5 are done).
3. ~~Add `--stop-viewer` (finding 4).~~ Done. The uninstall fix (finding 6) is still open.
4. Close the remaining test gaps (finding 9; `capture=none`, the argument rejections and reattach are now covered).
5. New, from the timing work: consider whether the roughly 2 second exit delay with the viewer down can be cut (for example with a shorter `OTEL_EXPORTER_OTLP_TIMEOUT`); not investigated.

## Second pass (2026-11-11, after the fixes for findings 1 to 5)

A fresh look at the code as it stands, attacking the parts added since the first review. Findings continue the numbering.

### 12. Low to medium: the wrapper pokes at, then fails on, a sandbox of a different agent (verified)

`claude-otel --name rev-shell --detach`, where `rev-shell` is an existing `shell`-agent sandbox, does this in order: runs `sbx exec` inside it to read the port (which would start it if it were stopped), warns "was not created with the claude-otel kit, so it sends no telemetry", prints "reattaching", and then `sbx` refuses: `sandbox "rev-shell" already exists and runs the "shell" agent, not "claude"`. The side effect and the misleading warning come before the real error.

Fix: look up the sandbox's agent first (`sbx ls --json`) and stop with one clear message if it is not `claude`, before executing anything inside it. Add a hermetic test with a fake `ls --json`.

**Fixed 2026-11-11.** The wrapper now reads the sandbox's agent from `sbx ls` (a plain awk on the table, no extra host dependency) before running anything in it, and stops with one message if it is not exactly `claude`. Verified with real sandboxes (`shell`) and a fake `sbx` (`shell`, `claude-desktop-poc`, and a normal `claude` one that still reattaches).

### 13. Low: a failed viewer start leaves a stale pid file and hides the cause (verified)

`--start-viewer --ui-port 8000` while another viewer already holds port 8000 exits 1 with "started a viewer but it is not answering", leaves `viewer-14400.pid` pointing at a dead process, and the real reason ("listen tcp 127.0.0.1:8000: bind: address already in use") is only in the log file. `--stop-viewer` does clean the leftover, but the wrapper should not leave it.

Fix: on failure remove the pid file, print the last line of the viewer log, and hint at `--ui-port` when it is a bind error.

**Fixed 2026-11-11.** On failure the wrapper kills the process it started, removes the pid file, prints the last relevant line of the viewer's log and, for a bind error, hints at `--ui-port`/`--port`. It also notices a viewer that dies early instead of waiting out the full 15 seconds; `CLAUDE_OTEL_START_WAIT` sets the wait. Verified against the real failure (UI port 8000 held by a running viewer): exit 1, reason shown, no pid file, no stray process.

### 14. Low: the README states an inference as fact

The prerequisite line says earlier sbx versions "will not work with this kit". The release notes show built-in agents became v3 kits in v0.51.0 and the docs say v3 kits cannot compose with v1/v2 kits, but no earlier version was run. Fix: "are not expected to work".

**Fixed 2026-11-11.** The prerequisite now says earlier versions "are not expected to work" and that none was tried.

### 15. Low: test portability

- `tests/wrapper.sh` and `tests/e2e.sh` need `python3`; the README does not say so.
- `tests/wrapper.sh` uses fixed ports 14777 and 14778 for its fake viewer, which can collide with something already listening. Use an ephemeral port.

**Fixed 2026-11-11.** The README lists the test prerequisites (`bash`, `curl`, `python3`; `sbx` for e2e). `tests/wrapper.sh` picks free ports at run time. `tests/e2e.sh` now refuses to run (exit 2) if ports 14318 or 18000 are in use.

### Checked and fine this pass

- `shellcheck -S warning` is clean on all scripts.
- The kit's boot-time probe (an empty POST to the viewer) leaves nothing behind: the viewer's `ingest_rejections` table stays empty.
- Reattaching to a stopped sandbox works (it is started; about 1.5 seconds) and the port is still read correctly.
- `sbx run --name` has no short form, so the wrapper's `--name` and `--name=` parsing covers it.

### Testing the tests

The new hermetic checks were mutation-tested in a scratch copy: skipping the agent check, keeping the pid file on a failed start, not killing a hung viewer, and hiding the failure reason were each caught. That exercise also exposed a flaky check of my own (`pgrep -f` matching the shell running the check) and leftover fake viewers when the wrapper was deliberately broken; the check now uses a recorded pid and the test's cleanup kills it. 12 consecutive runs after the fix passed.

### 16. Low: claude-otel options after sbx options gave a confusing error (found while testing, fixed)

`claude-otel --name x --port 14320` stopped parsing at `--name` and passed `--port` to sbx, which failed with "unknown flag: --port". The README said options must come first, but the error did not. **Fixed 2026-11-11:** the wrapper now notices its own options (`--port`, `--ui-port`, `--capture`, `--start-viewer`, `--db`, `--check`, `--stop-viewer`, and the `--opt=value` forms) after the first sbx argument, stops before calling sbx, and says to put them first. An agent's own `--port` after `--` is left alone. 26 hermetic checks.

### 17. Explained: a run's spans were occasionally missing (cause is inside Claude Code)

**Cause.** Claude Code initialises its telemetry only after a remote managed-settings fetch settles. When that fetch is not instant (about 0.25 s) and the first turn starts immediately (one-shot `claude -p`), the turn's spans are created before the tracer exists and are never recorded. Logs and metrics are unaffected (they are exported at exit), and no error appears because nothing was ever queued.

**Evidence (2026-11-12, `tests/soak.py`, a recording relay between the sandbox and a private viewer).**
- One-hour soak, four variants rotating under identical conditions, idle, CPU-loaded and stop/start phases: 228 runs, 2 kept a full trace, 226 lost it (200 never sent a trace POST at all; 26 sent a partial trace of one span, the model-call span without its root span, 1,759 bytes; by phase: idle 2 full, 48 never sent, 7 partial; load 0, 90, 5; stop/start 0, 62, 14). Logs 228 of 228.
- In all 226 debug logs telemetry initialised after `[engine] turn 1 start` (median 0.15 s later, maximum 0.41 s); in the 4 earlier runs that kept their trace it initialised first (median 1.49 s before). The remote-settings wait was 0.25 s median in lost runs and 0.00 s in kept ones.
- Variants made no difference: baseline 1 of 57 runs with a trace, raised shutdown and flush timeouts 0 of 57, `CLAUDE_CODE_EAGER_FLUSH=1` 1 of 57, span batch size 1 0 of 57.
- The export interval is irrelevant (600,000 ms and 250 ms both lost 13 of 15 fast runs), and tiny timeouts (1 ms) did not break slow-regime runs, because spans leave on the timer there.
- Earlier, in slower conditions (runs of about 7 seconds), about 150 runs lost nothing, which is why the loss looked intermittent: run speed depends on the API and caches, outside the kit.

**Not done, on purpose.** Bypassing remote managed settings would likely avoid it but would defeat an organisation's server-managed policy; a kit should not do that.

**Caveats.** Interactive sessions should be unaffected (the first prompt is typed seconds after start) but that was inferred, not tested in the fast conditions. A delayed-stdin experiment to confirm the mechanism directly was invalid (those runs made no model call) and proved nothing.

**Follow-ups.** Raise it with the Claude Code team. `tests/e2e.sh` is regime-dependent for the same reason (it uses one-shot runs and checks spans); a retry or a streaming session with a late first prompt would make it robust.

## Where things stand (2026-11-12)

**Fixed:** 1 to 9, 11 to 16. **Partly addressed:** 10. **Explained:** 17 (a run's spans occasionally missing: a start-up race inside Claude Code; see its section).

Done since the first pass: the wrapper reattaches, refuses other agents' sandboxes and cleans up a failed viewer start; `--stop-viewer`; the installer handles stale and foreign links; the port is exactly 1025 to 65535; options in the wrong place get a clear error; `accountIds` defaults to off; the default `capture` is `none` (changed at the owner's request after the secrets measurement); the e2e polls instead of sleeping; a fast GitHub Actions workflow runs `shellcheck` and three suites; and the README documents how to enable capturing prompts, replies, commands and tool output, what each mode records (checked cell by cell by the e2e), and where to read it.

**Still open, all optional:**

- A restrictive org policy: whether the `localhost:<port>` allow rule is required has never been proven (this machine's policy is allow-all).
- A clean first run: removing the shared `sbx-kit-builder` would exercise the cold path but also drops the build cache, so it needs the owner's go-ahead.
- The sandbox side on Linux (`sbx` and the kit on a Linux host); only the host scripts have been run there. Windows is unsupported and untested.
- The roughly 2 second delay at exit when the viewer is down is Claude Code's own retry behaviour; whether a different OTLP timeout shortens it was not tried.
- Scoping the telemetry variables to the `claude` process only, if other programs in the sandbox inheriting them proves unwanted.
- `claude-bedrock` is untested.
- Publishing the kit to a registry.
