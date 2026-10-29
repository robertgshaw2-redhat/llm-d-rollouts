#!/usr/bin/env python3
"""Verdict of a P/D rollout run, from results/ (probe.sh flush and rollout.sh watch).

    ./report.py               the run in results/ (and results/control/, if the control ran)
    ./report.py --out FILE    also write the report to FILE

Per phase (timeline.tsv marks): requests, failures, turn latency, the share of requests each
version served (x-llm-d-disagg-revision), and the prefill pods' prefix-cache hit rate (token
counters from rollout.sh watch, differenced per pod over the phase).

Per session: the version each turn was served by. With prefix affinity a session should change
version at most once, and only from the old version to the new one. Every change lands the
turn on pods that do not hold the session's KV cache, so it is recomputed.

Exits 1 if any request failed, or if a session moved from a newer version back to an older one.
"""
import argparse
import bisect
import collections
import json
import os
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


def read_marks(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [(float(t), label) for t, label in (l.rstrip("\n").split("\t", 1) for l in f if l.strip())]


def read_cache(path):
    """{pod: (role, version, revision, [(ts, queries, hits)])} from rollout.sh watch."""
    pods = {}
    if not os.path.exists(path):
        return pods
    with open(path) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 7:
                continue
            ts, pod, role, ver, rev, q, h = parts
            pods.setdefault(pod, (role, ver, rev, []))[3].append((float(ts), int(q), int(h)))
    for _, _, _, samples in pods.values():
        samples.sort()
    return pods


def counter_at(samples, t):
    """The counters at time t: the last sample at or before t; (0, 0) before the pod's first."""
    i = bisect.bisect_right([s[0] for s in samples], t)
    return samples[i - 1][1:] if i else (0, 0)


def prefill_hit_rate(cache, t0, t1):
    q = h = 0
    for role, _, _, samples in cache.values():
        if role != "prefill" or not samples or samples[0][0] > t1 or samples[-1][0] < t0:
            continue
        q0, h0 = counter_at(samples, t0)
        q1, h1 = counter_at(samples, t1)
        q += q1 - q0
        h += h1 - h0
    return (h / q, q) if q > 0 else (None, 0)


def session_moves(reqs, version_of):
    """Per session, the versions its successful turns were served by, in turn order."""
    by_sess = collections.defaultdict(list)
    for r in reqs:
        if r["kind"] == "turn" and r.get("ok") and r.get("rev"):
            by_sess[r["sess"]].append((r["turn"], version_of.get(r["rev"], r["rev"])))
    out = {}
    for sess, turns in by_sess.items():
        seq = [v for _, v in sorted(turns)]
        moves = [(a, b) for a, b in zip(seq, seq[1:]) if a != b]
        out[sess] = (seq, moves)
    return out


def summarize_sessions(say, title, reqs, version_of):
    moves = session_moves(reqs, version_of)
    if not moves:
        say(f"{title}: no sessions")
        return 0
    n = len(moves)
    total = sum(len(m) for _, m in moves.values())
    turns = sum(len(seq) - 1 for seq, _ in moves.values())
    zero = sum(1 for _, m in moves.values() if not m)
    one_fwd = sum(1 for _, m in moves.values() if len(m) == 1 and m[0][0] < m[0][1])
    back = sum(1 for _, m in moves.values() if any(a > b for a, b in m))
    many = sum(1 for _, m in moves.values() if len(m) > 1)
    say(f"{title}: {n} sessions, {turns} follow-up turns, {total} version changes "
        f"({100 * total / max(1, turns):.1f}% of follow-up turns recomputed their prefix)")
    say(f"    stayed on one version {zero}, moved once old->new {one_fwd}, moved more than once {many}, "
        f"moved back new->old {back}")
    return back


def report(say, results, title=""):
    reqs = load(os.path.join(results, "requests.jsonl"))
    marks = read_marks(os.path.join(results, "timeline.tsv"))
    cache = read_cache(os.path.join(results, "prefix-cache.tsv"))
    version_of = {rev: ver for _, ver, rev, _ in cache.values() if rev}
    if not reqs:
        say(f"{title}no requests in {results}")
        return 0, 0

    bounds = marks + [(max(r["t0"] for r in reqs) + 1, "end")]
    say(f"{title}{'phase':<26} {'reqs':>6} {'bad':>4} {'p50 s':>6} {'p99 s':>6}  {'prefill hits':>13}  served by")
    bad_total = 0
    for (t0, label), (t1, _) in zip(bounds, bounds[1:]):
        rs = [r for r in reqs if t0 <= r["t0"] < t1]
        bad = sum(1 for r in rs if not r.get("ok"))
        bad_total += bad
        durs = [r["dur"] for r in rs if r["kind"] == "turn" and r.get("ok")]
        served = collections.Counter(version_of.get(r.get("rev"), r.get("rev") or "?") for r in rs if r.get("ok"))
        tot = sum(served.values()) or 1
        rate, q = prefill_hit_rate(cache, t0, t1)
        hits = f"{100 * rate:5.1f}% of {q // 1000}k" if rate is not None else "-"
        say(f"{title}{label:<26} {len(rs):>6} {bad:>4} {pct(durs, 50):>6.2f} {pct(durs, 99):>6.2f}  {hits:>13}  "
            + " ".join(f"{v}={100 * c / tot:.0f}%" for v, c in sorted(served.items())))
    longs = [r for r in reqs if r["kind"] == "long"]
    canaries = [r for r in reqs if r["kind"] == "canary"]
    say(f"{title}long streams: {len(longs)} finished, {sum(1 for r in longs if not r.get('ok'))} failed; "
        f"canaries: {len(canaries)}, {sum(1 for r in canaries if not r.get('ok'))} wrong or failed")
    for r in [r for r in reqs if not r.get("ok")][:10]:
        say(f"{title}  bad: t0={r['t0']} kind={r['kind']} code={r.get('code')} err={str(r.get('err'))[:160]}")
    back = summarize_sessions(say, f"{title}sessions", reqs, version_of)
    return bad_total, back


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out")
    args = ap.parse_args()
    lines = []
    say = lines.append

    bad, back = report(say, R)
    control = os.path.join(R, "control")
    if os.path.exists(os.path.join(control, "requests.jsonl")):
        say("")
        say("control router (affinity none), same pods, its own sessions:")
        # The control's revision -> version map comes from the main run's watch.
        cache = read_cache(os.path.join(R, "prefix-cache.tsv"))
        version_of = {rev: ver for _, ver, rev, _ in cache.values() if rev}
        creqs = load(os.path.join(control, "requests.jsonl"))
        cbad = sum(1 for r in creqs if not r.get("ok"))
        say(f"    {len(creqs)} requests, {cbad} failed")
        summarize_sessions(say, "    sessions", creqs, version_of)

    text = "\n".join(lines)
    print(text)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")
    sys.exit(1 if bad or back else 0)


if __name__ == "__main__":
    main()
