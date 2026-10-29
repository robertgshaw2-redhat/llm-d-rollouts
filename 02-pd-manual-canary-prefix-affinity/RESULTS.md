# Results: Zero-downtime manual canary of llm-d P/D, with prefix affinity across revisions

The full numbers behind the short results section of the [README](README.md).

## How the claims are checked

**Zero downtime.** `loadgen.py` keeps 16 chat sessions and 2 long streams (6000 tokens, a few
minutes each) in flight at all times, so every scale-down lands on pods with work mid-generation.
One request in ten is a fixed greedy "capital of France" canary whose answer is checked: a
corrupted KV transfer returns 200 with garbage, and only the canary notices. `report.py` counts
anything that is not a correct, full-length answer as bad, per phase.

**Sessions stay on one revision.** Each session's first user message is 1500 unique words, so
each session has its own affinity key. Every response carries `x-llm-d-disagg-revision`;
`report.py` lists, per session, the version that served each turn, and counts the turns that
changed version (each of which recomputed the whole conversation). With affinity, a session
changes version at most once, from v0 to v1, at a step that moved its key; a change from v1 back
to v0 fails the run. The control router (affinity none) on the same pods shows the baseline.

**The cache follows.** `rollout.sh watch` reads every vLLM pod's `vllm:prefix_cache_queries` and
`vllm:prefix_cache_hits` counters every 10 s, and each `scale` snapshots them first, because a
deleted pod takes its counters with it. `report.py` prints the prefill pods' hit rate per phase.

## Run of 2026-10-29 (kermit)

One `./demo.sh` run (`HOLD=150`), EPP with #3456 (`affinity.mode: prefix`): 3,401 requests over
the seven steps, plus the control router (affinity none) on the same pods during step 4.

| phase | requests | failed | prefill prefix-cache hits | served by |
|---|---|---|---|---|
| 2 v0 2P2D | 487 | 0 | 90.7% | v0 100% |
| 3 v1 loading | 220 | 0 | 94.7% | v0 99%, v1 1% |
| 4 v0 2P2D + v1 1P1D | 679 | 0 | 89.5% | v0 67%, v1 33% |
| 5 v0 draining to 1P1D | 130 | 0 | 79.0% | v0 52%, v1 48% |
| 5 v0 1P1D + v1 1P1D | 500 | 0 | 93.2% | v0 40%, v1 60% |
| 6 v1 scaling to 2P2D | 230 | 0 | 89.8% | v0 42%, v1 58% |
| 6 v0 1P1D + v1 2P2D | 510 | 0 | 93.4% | v0 29%, v1 71% |
| 7 v0 draining to 0 | 140 | 0 | 85.1% | v0 1%, v1 99% |
| 7 v1 2P2D only | 505 | 0 | 92.7% | v1 100% |

Long streams: 45, canaries: 300, none failed.

| sessions | follow-up turns | version changes | moved once, v0 -> v1 | moved more than once | moved back v1 -> v0 |
|---|---|---|---|---|---|
| **prefix affinity** | 2,914 | **10 (0.3%)** | 10 | **0** | **0** |
| control, affinity none (step 4 only) | 213 | 91 (42.7%) | 1 | 14 | 15 |

- **Sessions stay put.** With affinity, 150 of 160 sessions were served by one version for their
  whole life; the other 10 moved exactly once, from v0 to v1, when a step moved their key. Without
  affinity, at 67/33, 43% of follow-up turns landed on the other revision and recomputed their
  whole conversation, and every session that spanned the step changed revision more than once.
- **Shares still follow the pods.** Requests split 67/33, ~50/50 and 29/71 as the Ready pods
  did; per session rather than per request, so the split is not exact (40/60 at 1P1D + 1P1D).
- **The cache follows.** The prefill hit rate stayed at the single-version level (89-93%) in
  the mixed phases; the dips are the scale-down windows (79%, 85%), where the sessions on the
  removed pods restart their prefix on the remaining ones.
- **Zero downtime**, as in the PoC: no failed request or wrong canary through two drains and a
  retirement.

Before the image was pushed, the same scripts ran with upstream v1.0.0 (no affinity) on both
routers: also zero failures, and 24% of follow-up turns changed revision, 59 of 111 sessions
moving back from v1 to v0.
