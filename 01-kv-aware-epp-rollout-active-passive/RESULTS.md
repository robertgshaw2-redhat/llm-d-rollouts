# Results: KV-aware rollout of an active-passive EPP

The full numbers behind the short results section of the [README](README.md).

## How the claims are checked

**Zero downtime.** `loadgen.py` keeps 16 chat sessions (20 turns, ~5 s apart) and 2 long streams
(12k tokens) in flight, so the leader is routing, and holding ext_proc streams, when it is told
to stop. One request in ten is a fixed greedy "capital of France" canary whose answer is
checked. `report.py` counts anything that is not a correct, full-length answer as bad, per phase.

**The new routers know the old prefixes.** The cold sessions are the test only a snapshot can
pass: their turn 1 is sent before the rollout, recording which vLLM pod served it; nothing
touches those prefixes during the rollout; their turn 2 is sent after both old EPP pods have
exited, so it is routed by EPPs that never saw their KV events. `report.py` counts how many went
back to the turn-1 pod and how many were prefix-cache hits (`usage.prompt_tokens_details.cached_tokens`
≥ half the prompt; vLLM runs with `--enable-prompt-tokens-details`). Without snapshots that is
chance, 1 in 4. The hot sessions' hit rate per phase shows the same thing for conversations that
are mid-flight during the rollout.

**Handovers are covered.** During each roll, `rollout.sh` samples the lease holder every second
(`results/leader-<roll>.tsv`) and Envoy's EPP hosts every ~2.7 s (`results/envoy-hosts-<roll>.tsv`).
`report.py` lists each leader change and every Envoy sample in which no EPP was healthy, which
is when Envoy's panic routing sends requests to the standbys. `rollout.sh` also prints each EPP
pod's `llm_d_epp_request_total` before and after a roll: the standby's count stays near 0
outside handovers.

## Run of 2026-10-29 (kermit)

One `demo.sh` run, `HOLD=120`: 2,710 requests through three EPP rollouts.

| phase | requests | failed | p50 / p99 turn latency | turn ≥ 2 prefix-cache hits |
|---|---|---|---|---|
| 1 warm | 452 | 0 | 0.26 / 0.36 s | 397/397 (100%) |
| 2 rolling, snapshots | 350 | 0 | 0.24 / 0.37 s | 299/299 (100%) |
| 2 after | 519 | 0 | 0.25 / 0.35 s | 449/449 (100%) |
| 3 rolling, **no snapshots** (control) | 363 | 0 | 0.27 / 0.34 s | 290/306 (**95%**) |
| 3 after | 460 | 0 | 0.26 / 0.36 s | 391/391 (100%) |
| 4 rolling back to snapshots | 353 | 0 | 0.27 / 0.34 s | 300/300 (100%) |
| 4 after | 213 | 0 | 0.24 / 0.35 s | 183/183 (100%) |

Long streams: 35, none failed (the longest, 50 s). Canaries: 239, none wrong.

| cold sessions, turn 2 after the rollout | back on the turn-1 pod | prefix-cache hit |
|---|---|---|
| rolled **with** snapshots | **48/48 (100%)** | **48/48 (100%)** |
| rolled without snapshots (control) | 15/48 (31%) | 15/48 (31%) |
| chance (4 pods) | 25% | |

### The handovers

Each roll had exactly one leader handover, when Kubernetes stopped the old leader.

| roll | old leader stopped | → new leader, its age when it took the lease | Envoy samples with no healthy EPP |
|---|---|---|---|
| 1 snapshots | second, after both new pods were up | `…c6c4f89d-qg47s`, ~40 s (a Ready standby) | 0 of 38 |
| 2 no snapshots | first, as the second new pod was created | `…56868bf454-hmvnh`, ~1.5 s | 3 of 38 (~8 s) |
| 3 snapshots | first, as the second new pod was created | `…f6d974d94-pnmfr`, ~0.3 s | 4 of 38 (~11 s) |

In rolls 2 and 3 the lease went to a pod that had started a second earlier, not to one of the
two standbys that had been warm for 40 s or more. Kubernetes stops an old pod and creates the
next new one at the same moment, and every candidate retries for the free lease every 2 s; the
fresh pod won the race twice. It then led for about 10 s before it was Ready
(`initialDelaySeconds: 10`), and until then it was not in the headless Service, so Envoy could
not reach it. For those ~8–11 s Envoy saw no healthy EPP, panicked, and spread requests over the
Ready pods, which were the two standbys. Their `rq_total` rose through the window (in roll 3,
from 0 to 17 and from 19 to 35) and no request failed. Once the new leader was Ready, Envoy
health-checked it and sent everything to it.

Two takeaways:

- **Panic routing is load-bearing.** Envoy's default `healthy_panic_threshold` (50%) would also
  panic with no healthy host, but with panic turned off (0) Envoy would have failed requests for
  ~10 s. Keep it at 1, and keep the standby's datastore populated (the v1.0.0
  default), so a standby that gets requests can route them.
- **The leader can be a pod that is seconds old.** Its index is warm only because it loaded
  the snapshots in the first 0.3 s of its life (`Snapshot loaded` at 13:11:46.03–.18; it took
  the lease at ~13:11:46). Without snapshots, that pod routes every older prefix as a miss,
  which is what the control shows: 16 hot-session misses during the roll and cold sessions at
  chance after it.

### Snapshot loads

Every EPP pod loaded all four vLLM pods' snapshots within 0.3–1 s of its first log line, standbys
included, 5–22 ms each (the vLLM caches were smaller than in example 02's run, 1–5 event batches
per pod). The two pods of the no-snapshot roll logged none, as intended.
