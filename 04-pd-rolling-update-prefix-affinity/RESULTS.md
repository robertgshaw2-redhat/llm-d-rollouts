# Results: Zero-downtime rolling update of llm-d P/D, with prefix affinity across revisions

The full numbers behind the short results section of the [README](README.md).

## How the claims are checked

**Zero downtime.** `loadgen.py` keeps 16 chat sessions and 2 long streams (6000 tokens, a few
minutes each) in flight at all times, so every step of the roll removes pods with work
mid-generation. One request in ten is a fixed greedy "capital of France" canary whose answer is
checked: a corrupted KV transfer returns 200 with garbage, and only the canary notices.
`report.py` counts anything that is not a correct, full-length answer as bad, per phase.

**Sessions stay on one revision.** Each session's first user message is 1500 unique words, so
each session has its own affinity key. Every response carries `x-llm-d-disagg-revision`;
`report.py` lists, per session, the version that served each turn and counts the turns that
changed version (each of which recomputed the whole conversation). With affinity, a session
changes version at most once, from v0 to v1; a change from v1 back to v0 fails the run. The
control router (affinity none) on the same pods, through the same roll, shows the baseline.

**The cache follows.** `rollout.sh watch` reads every vLLM pod's `vllm:prefix_cache_queries` and
`vllm:prefix_cache_hits` counters every 5 s (the controller removes old pods on its own
schedule, and a pod's counters go with it). `report.py` prints the prefill pods' hit rate per
phase.

## Run of 2026-10-29 (kermit)

One `./demo.sh` run (`HOLD=150`), EPP with #3456 (`affinity.mode: prefix`), with the control router
(affinity none) and its own probe running on the same pods through the whole roll.

| phase | requests | failed | prefill prefix-cache hits | served by |
|---|---|---|---|---|
| 2 v0 | 507 | 0 | 92.9% | v0 100% |
| 3 rolling to v1 (275 s) | 914 | 0 | 89.3% | v0 45%, v1 55% |
| 4 v1 | 605 | 0 | 93.0% | v1 100% |

Long streams: 23, canaries: 178, none failed; the control router's 984 requests, none failed.
The controller's steps, as `rollout.sh update` printed them (Ready pods):

```
[   1s] v0 decode 2 prefill 2 | v1 decode 0(+1 starting) prefill 0(+1 starting)
[  60s] v0 decode 1(+1 draining) prefill 1(+1 draining) | v1 decode 1(+1 starting) prefill 1(+1 starting)
[ 108s] v0 decode 1 prefill 1 | v1 decode 1(+1 starting) prefill 1(+1 starting)
[ 138s] v0 decode 1 prefill 1 | v1 decode 2 prefill 1(+1 starting)
[ 239s] v0 decode 0(+1 draining) prefill 0(+1 draining) | v1 decode 2 prefill 2
[ 275s] v1 decode 2 prefill 2
```

| sessions | follow-up turns | version changes | moved once, v0 -> v1 | moved more than once | moved back v1 -> v0 |
|---|---|---|---|---|---|
| **prefix affinity** | 1,775 | **15 (0.8%)** | 15 | **0** | **0** |
| control, affinity none | 830 | 119 (14.3%) | 1 | 17 | 17 |

- **Sessions stay put through the roll.** With affinity, 82 of 97 sessions never changed
  version; the other 15 moved exactly once, from v0 to v1. Without affinity, on the same pods at
  the same moments, 17 of 48 sessions changed revision more than once and 17 went back from v1 to
  v0.
- **The cache follows.** The prefill hit rate during the roll (89%) stayed close to the
  single-version level (93%).
- **Zero downtime**: no failed request, long stream or canary while the controller replaced
  every pod.
