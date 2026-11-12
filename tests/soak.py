#!/usr/bin/env python3
"""Soak test for one open question: why a one-shot `claude -p` run's spans occasionally did not
reach the viewer while its logs and metrics did. Manual only, never run in CI: it makes real
Claude calls (a few cents each) and takes as long as you ask.

What it does
  * starts a private otel-desktop-viewer and, in front of it, a recording relay (every OTLP POST
    from the sandbox is logged, then forwarded to the viewer and the viewer's answer is logged);
  * creates one sandbox with the kit (default capture, so no content is recorded) pointed at the relay;
  * runs one-shot `claude -p` calls in three conditions, each for a third of the time: an idle host,
    a host under CPU load, and with the sandbox stopped and restarted every few runs;
  * tags every run invisibly: the prompt LENGTH is unique per run, and Claude records
    `prompt_length` on its logs and `user_prompt_length` on its spans even with capture off, so each
    run can be matched exactly without recording any text;
  * afterwards matches every run against what the relay saw and what the viewer stored, and for any
    run with logs but no spans (or the reverse) says which of three things happened: the trace POST
    never arrived, it arrived and the viewer refused it, or the viewer accepted it but did not store it.

Usage:  tests/soak.py [--duration SECONDS] [--runs N] [--phases idle,load,cycle] [--out DIR] [--keep]
Quick check of the harness:  tests/soak.py --duration 120 --runs 4 --phases idle
"""
import argparse, http.client, json, os, random, signal, socket, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIT_PORT, VIEWER_PORT, GRPC_PORT, UI_PORT = 14340, 14341, 14339, 18040   # kit/relay, viewer OTLP, viewer gRPC, viewer UI
BASE_LEN = 200            # run i sends a prompt of exactly BASE_LEN + i characters
GAPS = [0, 0, 3, 8, 12, 20, 40]   # seconds between runs; includes the short gaps of the early failures

ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
ap.add_argument("--duration", type=int, default=3600, help="total seconds of runs (default 3600)")
ap.add_argument("--runs", type=int, default=0, help="stop after this many runs (0 = no limit)")
ap.add_argument("--phases", default="idle,load,cycle", help="comma list of idle, load, cycle")
ap.add_argument("--out", default="", help="directory for results (default: a new temp dir)")
ap.add_argument("--keep", action="store_true", help="leave the sandbox in place afterwards")
ap.add_argument("--seed", type=int, default=0)
ap.add_argument("--gap", type=int, default=-1, help="fixed gap in seconds between runs (default: random)")
ap.add_argument("--claude-args", default="", help="extra arguments for claude, e.g. '--model haiku'")
ap.add_argument("--env", default="", help="extra environment for the claude command, e.g. 'OTEL_TRACES_EXPORT_INTERVAL=250'")
ap.add_argument("--env-b", default="", help="more variants, separated by |: runs rotate through --env (A), then these (B, C, ...), so every variant sees identical conditions")
ap.add_argument("--direct", action="store_true", help="no relay: the sandbox talks to the viewer directly (cannot tell 'never sent' from 'sent')")
args = ap.parse_args()
random.seed(args.seed or int(time.time()))
OUT = args.out or tempfile.mkdtemp(prefix="claude-otel-soak-")
os.makedirs(OUT, exist_ok=True)
NAME = f"soak-{os.getpid()}"
RELAY_LOG, RELAY_LOCK = [], threading.Lock()


def say(msg):
    print(msg, flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def port_free(p):
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", p)) != 0


class Relay(BaseHTTPRequestHandler):
    """Records each POST, forwards it to the viewer, records the viewer's answer, returns it."""
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        t0 = time.time()
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n)
        status = err = ctype = data = None
        try:
            c = http.client.HTTPConnection("127.0.0.1", VIEWER_PORT, timeout=30)
            hdrs = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection", "content-length")}
            hdrs["Content-Length"] = str(n)
            c.request("POST", self.path, body=body, headers=hdrs)
            r = c.getresponse(); data = r.read(); status = r.status; ctype = r.getheader("content-type")
            c.close()
        except Exception as e:  # the viewer did not answer
            err = repr(e)
        rec = {"t": t0, "path": self.path, "bytes": n, "viewer_status": status, "error": err, "ms": round((time.time() - t0) * 1000)}
        with RELAY_LOCK:
            RELAY_LOG.append(rec)
        try:
            if status is None:
                self.send_response(502); self.send_header("content-length", "0"); self.end_headers()
            else:
                self.send_response(status)
                if ctype: self.send_header("content-type", ctype)
                self.send_header("content-length", str(len(data))); self.end_headers(); self.wfile.write(data)
        except Exception:
            pass

    def log_message(self, *a):
        pass


def viewer_query(sql):
    r = run(["otel-desktop-viewer", "query", sql, "--endpoint", f"http://localhost:{UI_PORT}", "--json", "--limit", "20000"])
    try:
        return json.loads(r.stdout)["rows"]
    except Exception:
        sys.exit(f"viewer query failed: {sql}\n{r.stdout[:300]}{r.stderr[:300]}")


def prompt_for(i):
    head = "Reply with exactly the word ok and nothing else. Ignore this filler: "
    return head + "x" * (BASE_LEN + i - len(head))


def main():
    for p in (KIT_PORT, VIEWER_PORT, GRPC_PORT, UI_PORT):
        if not port_free(p):
            sys.exit(f"port {p} is in use; free it and rerun")
    if run(["sbx", "kit", "validate", f"{ROOT}/kit"]).returncode != 0:
        sys.exit("sbx cannot validate the kit here (is sbx installed and signed in?)")
    phases = [p for p in args.phases.split(",") if p]
    if any(p not in ("idle", "load", "cycle") for p in phases):
        sys.exit("--phases takes idle, load and cycle")

    say(f"results in {OUT}")
    viewer = subprocess.Popen(
        ["otel-desktop-viewer", "--open-browser=false", "--http", str(VIEWER_PORT), "--grpc", str(GRPC_PORT), "--browser-port", str(UI_PORT)],
        stdout=open(f"{OUT}/viewer.log", "w"), stderr=subprocess.STDOUT)
    relay = ThreadingHTTPServer(("127.0.0.1", KIT_PORT), Relay)
    threading.Thread(target=relay.serve_forever, daemon=True).start()
    busy = []
    runs = []
    try:
        for _ in range(60):
            if run(["curl", "-sf", "-m", "2", "-o", "/dev/null", "-X", "POST", "-H", "content-type: application/x-protobuf",
                    "--data-binary", "", f"http://localhost:{VIEWER_PORT}/v1/traces"]).returncode == 0:
                break
            time.sleep(0.5)
        else:
            sys.exit("the viewer did not start; see viewer.log")
        r = run(["sbx", "create", "claude", "--kit", f"{ROOT}/kit", "--kit-arg", f"viewerPort={VIEWER_PORT if args.direct else KIT_PORT}", "--name", NAME])
        if r.returncode != 0:
            sys.exit("sbx create failed:\n" + r.stdout[-400:] + r.stderr[-400:])
        say(f"sandbox {NAME} created; {len(phases)} phase(s) of {args.duration // len(phases)}s")

        i = 0
        t_end_all = time.time() + args.duration
        for pi, phase in enumerate(phases):
            phase_end = min(t_end_all, time.time() + args.duration / len(phases)) if pi < len(phases) - 1 else t_end_all
            if phase == "load":
                n = max(1, (os.cpu_count() or 2) // 2)
                busy = [subprocess.Popen(["nice", "-n", "19", "sh", "-c", "while :; do :; done"]) for _ in range(n)]
                say(f"[load] {n} niced busy loops started")
            while time.time() < phase_end and not (args.runs and i >= args.runs):
                i += 1
                t0 = time.time()
                variants = [args.env] + (args.env_b.split("|") if args.env_b else [])
                vi = (i - 1) % len(variants)
                variant = "ABCDEFGH"[vi]
                env_str = variants[vi]
                cmd = f"{env_str + ' ' if env_str else ''}claude -p {args.claude_args} --debug-file /tmp/dbg-{i}.log '{prompt_for(i)}' >/dev/null 2>/tmp/err-{i}.log"
                r = run(["sbx", "exec", NAME, "bash", "-c", cmd])
                t1 = time.time()
                gap = args.gap if args.gap >= 0 else random.choice(GAPS)
                rec = {"i": i, "variant": variant, "phase": phase, "len": BASE_LEN + i, "t0": t0, "t1": t1, "rc": r.returncode, "load1": round(os.getloadavg()[0], 1), "gap_after": gap}
                runs.append(rec)
                say(f"run {i:3d} [{phase:5s}] rc={r.returncode} {t1 - t0:4.1f}s load={rec['load1']:5.1f} next gap {gap}s")
                if phase == "cycle" and i % 3 == 0:
                    run(["sbx", "stop", NAME]); rec["stopped_after"] = True
                if args.runs and i >= args.runs:
                    break
                time.sleep(gap)
            if busy:
                for b in busy: b.terminate()
                busy = []
                say("[load] busy loops stopped")
            if args.runs and i >= args.runs:
                break

        say("settling for 40 s, then analysing")
        time.sleep(40)
        analyse(runs)
    finally:
        for b in busy: b.terminate()
        relay.shutdown()
        viewer.terminate()
        try:
            viewer.wait(timeout=10)
        except Exception:
            viewer.kill()
        if not args.keep:
            run(["sbx", "rm", "--force", NAME])


def analyse(runs):
    # Each run is one Claude session. The user_prompt log carries session.id and prompt_length (unique per
    # run); spans carry gen_ai.conversation.id, which is the session id, so a trace missing its root span
    # (and so its user_prompt_length) can still be linked to its run.
    sess_len = {str(r[0]): str(r[1]) for r in viewer_query(
        "SELECT attributes.\"session.id\"::VARCHAR, attributes.\"prompt_length\"::VARCHAR FROM logs WHERE CAST(body AS VARCHAR) = 'claude_code.user_prompt'")}
    log_n = {}
    for L in sess_len.values(): log_n[L] = log_n.get(L, 0) + 1
    span_rows = viewer_query("SELECT attributes.\"gen_ai.conversation.id\"::VARCHAR, name, count(*) FROM spans GROUP BY 1, 2")
    by_len = {}
    unlinked = 0
    for sid, name, n in span_rows:
        L = sess_len.get(str(sid))
        if L is None: unlinked += n; continue
        by_len.setdefault(L, {})[name] = by_len.get(L, {}).get(name, 0) + n
    cost = viewer_query("SELECT coalesce(sum(attributes.\"cost_usd\"::DOUBLE), 0) FROM logs WHERE CAST(body AS VARCHAR) = 'claude_code.api_request'")[0][0]
    sessions = viewer_query("SELECT count(*) FROM metric_records WHERE name = 'claude_code.session.count'")[0][0]
    with open(f"{OUT}/spans.json", "w") as f:
        json.dump(viewer_query("SELECT trace_id, name, start_time, end_time, to_json(attributes) FROM spans ORDER BY start_time"), f)
    with open(f"{OUT}/relay.jsonl", "w") as f:
        for rec in RELAY_LOG: f.write(json.dumps(rec) + "\n")

    starts = [r["t0"] for r in runs]
    for r in runs:
        L = str(r["len"])
        r["span_names"] = by_len.get(L, {})
        r["spans"] = sum(r["span_names"].values())
        r["root"] = r["span_names"].get("claude_code.interaction", 0)
        r["logs"] = log_n.get(L, 0)
        # a POST belongs to the run that had most recently started
        mine = [x for x in RELAY_LOG if x["bytes"] > 0 and x["t"] >= r["t0"] - 0.5 and
                (r["i"] == len(runs) or x["t"] < starts[r["i"]] - 0.5)]
        r["posts"] = {p: [(x["viewer_status"], x["bytes"]) for x in mine if x["path"] == p] for p in ("/v1/traces", "/v1/logs", "/v1/metrics")}
        r["odd"] = r["rc"] != 0 or r["root"] != 1 or r["spans"] < 2 or r["logs"] != 1
    anomalies = [r for r in runs if r["odd"]]
    with open(f"{OUT}/runs.jsonl", "w") as f:
        for r in runs: f.write(json.dumps(r) + "\n")

    lines = [f"soak report: {len(runs)} runs ({'direct, no relay' if args.direct else 'via relay'}), results in {OUT}", ""]
    lines.append(f"{'phase':6s} {'runs':>5s} {'full trace':>11s} {'partial':>8s} {'no spans':>9s} {'logs ok':>8s} {'exec fail':>10s} {'avg load':>9s}")
    for ph in dict.fromkeys(r["phase"] for r in runs):
        rs = [r for r in runs if r["phase"] == ph]
        lines.append(f"{ph:6s} {len(rs):5d} {sum(r['root'] == 1 and r['spans'] >= 2 for r in rs):11d} "
                     f"{sum(0 < r['spans'] < 2 or (r['spans'] > 0 and r['root'] != 1) for r in rs):8d} {sum(r['spans'] == 0 for r in rs):9d} "
                     f"{sum(r['logs'] == 1 for r in rs):8d} {sum(r['rc'] != 0 for r in rs):10d} {sum(r['load1'] for r in rs) / len(rs):9.1f}")
    if args.env_b:
        lines.append("A/B comparison (runs alternate, so conditions are identical):")
        for vi, label in enumerate([args.env] + args.env_b.split("|")):
            v = "ABCDEFGH"[vi]
            rs = [r for r in runs if r["variant"] == v]
            full = sum(r["root"] == 1 and r["spans"] >= 2 for r in rs)
            lines.append(f"  {v}: {len(rs):3d} runs, full trace {full:3d} ({100 * full // max(1, len(rs))}%), mean {sum(r['t1'] - r['t0'] for r in rs) / max(1, len(rs)):.1f}s   [{label}]")
        lines.append("")
    ok_d = [r["t1"] - r["t0"] for r in runs if not r["odd"]]
    bad_d = [r["t1"] - r["t0"] for r in runs if r["odd"]]
    lines += ["", f"mean run time: {sum(ok_d) / len(ok_d):.1f}s for runs with a full trace" if ok_d else "no run had a full trace",
              f"mean run time: {sum(bad_d) / len(bad_d):.1f}s for anomalous runs" if bad_d else ""]
    if len(runs) <= 40:
        lines += ["", f"{'run':>3s} {'var':>3s} {'secs':>5s} {'gap before':>10s} {'root':>4s} {'spans':>5s} {'trace POST bytes':>17s}"]
        prev = 0
        for r in runs:
            lines.append(f"{r['i']:3d} {r['variant']:>3s} {r['t1'] - r['t0']:5.1f} {prev:9d}s {r['root']:4d} {r['spans']:5d} {str([b for _, b in r['posts']['/v1/traces']]):>17s}" + ("   <-- odd" if r["odd"] else ""))
            prev = r["gap_after"]
    lines += ["", f"totals: runs with a full trace {sum(r['root'] == 1 and r['spans'] >= 2 for r in runs)}/{len(runs)}, logs ok {sum(r['logs'] == 1 for r in runs)}/{len(runs)}, "
                  f"session.count rows {sessions}, spans not linkable to a run: {unlinked}, approx cost ${cost:.2f}"]
    if not args.direct:
        answers = {}
        for x in RELAY_LOG: answers[str(x["viewer_status"])] = answers.get(str(x["viewer_status"]), 0) + 1
        lines.append(f"relay saw {len(RELAY_LOG)} POSTs; viewer answers: {answers}")
    lines.append("")
    if not anomalies:
        lines.append("NO ANOMALIES: every run produced a root span, at least 2 spans and exactly one user_prompt log.")
    for r in anomalies:
        t = r["posts"]["/v1/traces"]
        if r["rc"] != 0: why = "the sbx exec itself failed"
        elif args.direct: why = f"spans={r['span_names']} logs={r['logs']} (direct mode: cannot tell whether a POST was sent)"
        elif r["spans"] == 0 and not t: why = "NO SPANS: no trace POST ever reached the relay (never sent)"
        elif r["spans"] == 0: why = f"NO SPANS although trace POST(s) reached the relay: {t}"
        else: why = f"PARTIAL TRACE: spans={r['span_names']} ; trace POSTs (viewer status, bytes) = {t}"
        lines.append(f"run {r['i']} [{r['phase']}] load={r['load1']}: {why}")
        d = run(["sbx", "exec", NAME, "bash", "-c", f"cat /tmp/dbg-{r['i']}.log"])
        with open(f"{OUT}/debug-run-{r['i']}.log", "w") as f: f.write(d.stdout)
        e = run(["sbx", "exec", NAME, "bash", "-c", f"cat /tmp/err-{r['i']}.log"])
        with open(f"{OUT}/stderr-run-{r['i']}.log", "w") as f: f.write(e.stdout)
    report = "\n".join(lines)
    open(f"{OUT}/report.txt", "w").write(report + "\n")
    say("\n" + report)


def stop(*_):
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop)
    main()
