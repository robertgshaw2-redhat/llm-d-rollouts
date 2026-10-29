#!/usr/bin/env python3
"""Verdict of a KV-aware EPP rollout run, from results/ (probe.sh flush and rollout.sh roll).

    ./report.py               all scenarios found in results/
    ./report.py --out FILE    also write the report to FILE

Per phase (timeline.tsv marks): requests, failures, latency, and the prefix-cache hit rate of
turns >= 2 of the hot sessions (a hit = at least half the prompt served from cache).

Per cold-session tag: how many turn-2 probes went back to the vLLM pod that served turn 1, and
how many were prefix-cache hits. The cold sessions are seeded before the rollout and probed
after both old EPP pods have exited, so the routers that probe them never saw their KV events.

From the EPP logs: when each EPP pod loaded each vLLM pod's snapshot, and how long it took.

Exits 1 if any request failed.
"""
import argparse
import collections
import glob
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
R = os.path.join(HERE, "results")


def load(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def pct(xs, p):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p / 100 * len(xs)))]


def is_hit(r):
    return r.get("ptok") and (r.get("ctok") or 0) >= 0.5 * r["ptok"]


def phases(reqs, marks):
    bounds = marks + [(float("inf"), "end")]
    out = collections.OrderedDict((label, []) for _, label in marks)
    for r in reqs:
        for (t, label), (t_next, _) in zip(bounds, bounds[1:]):
            if t <= r["t0"] < t_next:
                out[label].append(r)
                break
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out")
    args = ap.parse_args()
    lines = []
    say = lines.append

    reqs = load(os.path.join(R, "requests.jsonl"))
    marks = []
    if os.path.exists(os.path.join(R, "timeline.tsv")):
        with open(os.path.join(R, "timeline.tsv")) as f:
            marks = [(float(t), label) for t, label in (l.rstrip("\n").split("\t", 1) for l in f if l.strip())]

    say(f"{'phase':<28} {'reqs':>6} {'bad':>4} {'p50 s':>7} {'p99 s':>7} {'turn>=2 hits':>14}  pods")
    bad_total = 0
    for label, rs in phases(reqs, marks).items():
        bad = [r for r in rs if not r.get("ok")]
        bad_total += len(bad)
        turns = [r for r in rs if r["kind"] == "turn" and r["turn"] >= 2 and r.get("ok")]
        hits = sum(1 for r in turns if is_hit(r))
        durs = [r["dur"] for r in rs if r["kind"] == "turn" and r.get("ok")]
        pods = collections.Counter(r.get("up", "") for r in rs if r.get("ok"))
        hit = f"{hits}/{len(turns)} {100 * hits / len(turns):.0f}%" if turns else "-"
        say(f"{label:<28} {len(rs):>6} {len(bad):>4} {pct(durs, 50):>7.2f} {pct(durs, 99):>7.2f} {hit:>14}  "
            + " ".join(f"{p.split(':')[0]}={n}" for p, n in sorted(pods.items()) if p))
    longs = [r for r in reqs if r["kind"] == "long"]
    say(f"long streams: {len(longs)} finished, {sum(1 for r in longs if not r.get('ok'))} failed, "
        f"longest {max((r['dur'] for r in longs), default=0):.0f} s")
    canaries = [r for r in reqs if r["kind"] == "canary"]
    say(f"canaries: {len(canaries)}, {sum(1 for r in canaries if not r.get('ok'))} wrong or failed")
    for r in [r for r in reqs if not r.get("ok")][:10]:
        say(f"  bad: t0={r['t0']} kind={r['kind']} code={r.get('code')} err={str(r.get('err'))[:160]}")

    say("")
    for seed_path in sorted(glob.glob(os.path.join(R, "cold-seed-*.jsonl"))):
        tag = seed_path.rsplit("cold-seed-", 1)[1][:-len(".jsonl")]
        probe = load(os.path.join(R, f"cold-probe-{tag}.jsonl"))
        seeds = load(seed_path)
        if not probe:
            say(f"cold sessions [{tag}]: seeded {len(seeds)}, not probed yet")
            continue
        ok = [r for r in probe if r.get("ok")]
        same = sum(1 for r in ok if r.get("up") and r["up"] == r.get("seed_up"))
        hits = sum(1 for r in ok if is_hit(r))
        pods = len({r.get("up") for r in seeds if r.get("up")})
        bad_total += len(probe) - len(ok) + sum(1 for r in seeds if not r.get("ok"))
        say(f"cold sessions [{tag}]: {len(probe)} probed, {len(probe) - len(ok)} failed; "
            f"back on the turn-1 pod {same}/{len(ok)} ({100 * same / max(1, len(ok)):.0f}%), "
            f"prefix-cache hits {hits}/{len(ok)} ({100 * hits / max(1, len(ok)):.0f}%); "
            f"chance would be ~{100 / max(1, pods):.0f}%")

    say("")
    for path in sorted(glob.glob(os.path.join(R, "epp-*.log"))):
        pod = os.path.basename(path)[4:-4]
        loads = []
        first = None
        with open(path) as f:
            for line in f:
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                first = first or j.get("timestamp")
                if j.get("body") == "Snapshot loaded":
                    loads.append((j.get("timestamp", "")[11:23], j.get("snapshotEndpoint"),
                                  f"{1000 * float(j.get('duration', 0)):.1f} ms", j.get("batches")))
        if not loads:
            say(f"EPP {pod}: no snapshot loads logged")
            continue
        say(f"EPP {pod} (first log {first[11:23] if first else '?'}): {len(loads)} snapshot loads")
        for ts, ep, dur, batches in loads:
            say(f"    {ts}  {ep}  {dur}  batches={batches}")

    text = "\n".join(lines)
    print(text)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")
    sys.exit(1 if bad_total else 0)


if __name__ == "__main__":
    main()
