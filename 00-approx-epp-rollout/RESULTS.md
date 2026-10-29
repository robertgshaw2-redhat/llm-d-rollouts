# Results: Basic EPP rollout with approximate prefix-cache routing

The full numbers behind the short results section of the [README](README.md).

## How the claims are checked

**Zero downtime.** `loadgen.py` keeps 16 chat sessions (20 turns, ~5 s apart) and 2 long streams
(12k tokens) in flight, so the EPP is routing, and holding ext_proc streams, when it is told to
stop. One request in ten is a fixed greedy "capital of France" canary whose answer is checked.
`report.py` counts anything that is not a correct, full-length answer as bad, per phase.

**What the index remembers.** Cold sessions send turn 1, go idle, and send turn 2 later,
recording which vLLM pod served each. Two batches of 48:

- **baseline**: turn 2 ~75 s after turn 1, the same EPP throughout. This is what approximate
  routing does when nothing restarts.
- **rollout**: turn 1 before `rollout.sh roll`, turn 2 after the old EPP has exited, so turn 2
  is routed by an EPP that never routed turn 1.

`report.py` counts how many went back to the turn-1 pod and how many were prefix-cache hits
(`usage.prompt_tokens_details.cached_tokens` ≥ half the prompt; vLLM runs with
`--enable-prompt-tokens-details`). The hot sessions' hit rate per phase shows the same thing for
conversations mid-flight during the rollout.

**The overlap.** `rollout.sh roll` samples Envoy's EPP hosts every ~2.5 s
(`results/envoy-hosts-<HHMMSS>.tsv`): health and requests per EPP.

## Run of 2026-10-29 (kermit)

One `demo.sh` run, `HOLD=120`, `WAIT=75`: 1,518 requests, one EPP rollout.

| phase | requests | failed | p50 / p99 turn latency | turn ≥ 2 prefix-cache hits |
|---|---|---|---|---|
| 1 warm | 442 | 0 | 0.27 / 0.36 s | 388/388 (100%) |
| 2 baseline (cold sessions idle, no rollout) | 357 | 0 | 0.24 / 0.37 s | 305/305 (100%) |
| 3 rolling | 263 | 0 | 0.26 / 0.37 s | 212/223 (**95%**) |
| 3 after | 456 | 0 | 0.26 / 0.36 s | 390/390 (100%) |

Long streams: 20, none failed (the longest, 50 s). Canaries: 130, none wrong.

| cold sessions, turn 2 | back on the turn-1 pod | prefix-cache hit |
|---|---|---|
| baseline, no rollout | **48/48 (100%)** | **48/48 (100%)** |
| across the EPP rollout | 14/48 (29%) | 14/48 (29%) |
| chance (4 pods) | 25% | |

The rollout as Envoy saw it (seconds from the start of `roll`):

| t | old EPP (`…6c95c44dfd-tj25h`) | new EPP (`…7b499d9b4c-mk9nv`) |
|---|---|---|
| 0 | healthy, 971 requests routed | not started |
| ~10–13 | healthy | Ready, healthy, starts taking requests |
| ~13–32 | healthy, 1001 → 1035 | healthy, 9 → 41 |
| ~35 | stopped (`minReadySeconds`), fails the health check, last count 1040 | healthy |
| 74 | exited after its open streams finished | healthy, 180 requests routed |

- Approximate routing is reliable in steady state: all 48 baseline sessions went back to their
  pod after 75 s idle, and hot sessions hit 100% outside the roll.
- Across one restart the idle sessions fell to chance. The new EPP had never routed them.
- Mid-flight sessions lost a turn each, at most: 11 misses in the rolling phase, none after.
- During the ~25 s overlap both EPPs took requests, about half each, each with its own index.
- The result matches example 01's control (precise routing rolled without snapshots: 15/48 back,
  16 hot misses), since both indexes start empty in a new pod. Precise routing is only better
  across a rollout once vLLM can hand over its state (snapshots).
