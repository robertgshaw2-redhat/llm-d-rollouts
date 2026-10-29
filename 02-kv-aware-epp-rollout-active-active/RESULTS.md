# Results: KV-aware rollout of an active-active EPP

The full numbers behind the short results section of the [README](README.md).

## How the claims are checked

**Zero downtime.** `loadgen.py` keeps 16 chat sessions (20 turns, ~5 s apart) and 2 long streams
(12k tokens) in flight, so both EPPs are routing, and holding ext_proc streams, when they are
told to stop. One request in ten is a fixed greedy "capital of France" canary whose answer is
checked. `report.py` counts anything that is not a correct, full-length answer as bad, per phase.

**The new routers know the old prefixes.** The cold sessions are the test only a snapshot can
pass: their turn 1 is sent before the rollout, recording which vLLM pod served it; nothing
touches those prefixes during the rollout; their turn 2 is sent after both old EPP pods have
exited, so it is routed by EPPs that never saw their KV events. `report.py` counts how many went
back to the turn-1 pod and how many were prefix-cache hits (`usage.prompt_tokens_details.cached_tokens`
≥ half the prompt; vLLM runs with `--enable-prompt-tokens-details`). Without snapshots that is
chance, 1 in 4. The hot sessions' hit rate per phase shows the same thing for conversations that
are mid-flight during the rollout.

**Both routers route.** `rollout.sh` prints each EPP pod's `llm_d_epp_request_total` before and
after a roll; `results/envoy-hosts-*.tsv` shows Envoy's per-host request counts and health over
the rollout, including the draining pod going unhealthy.

## Run of 2026-10-29 (kermit)

One `demo.sh` run, `HOLD=120`: 2,746 requests over 27 minutes through three EPP rollouts.

| phase | requests | failed | p50 / p99 turn latency | turn ≥ 2 prefix-cache hits |
|---|---|---|---|---|
| 1 warm | 436 | 0 | 0.28 / 0.35 s | 382/382 (100%) |
| 2 rolling, snapshots | 431 | 0 | 0.25 / 0.37 s | 369/369 (100%) |
| 2 after | 508 | 0 | 0.28 / 0.36 s | 437/437 (100%) |
| 3 rolling, **no snapshots** (control) | 355 | 0 | 0.25 / 0.36 s | 280/302 (**93%**) |
| 3 after | 451 | 0 | 0.26 / 0.35 s | 378/378 (100%) |
| 4 rolling back to snapshots | 347 | 0 | 0.25 / 0.37 s | 296/296 (100%) |
| 4 after | 218 | 0 | 0.26 / 0.34 s | 192/192 (100%) |

Long streams: 38, none failed (the longest, 50 s, spanned an EPP's shutdown). Canaries: 241,
none wrong.

| cold sessions, turn 2 after the rollout | back on the turn-1 pod | prefix-cache hit |
|---|---|---|
| rolled **with** snapshots | **48/48 (100%)** | **48/48 (100%)** |
| rolled without snapshots (control) | 8/48 (17%) | 13/48 (27%) |
| chance (4 pods) | 25% | |

- **Snapshots work.** Each new EPP pod loaded all four vLLM pods' snapshots 0.3-0.9 s after its
  first log line, in 97-125 ms each (42-47 event batches per pod), well before its readiness
  probe started at 10 s. The cold sessions it had never heard about went back to the pod
  holding them, every one. Without snapshots they landed at chance.
- **Mid-flight sessions notice too.** While the EPPs rolled without snapshots, 22 of 302
  follow-up turns missed: a session whose prefix was stored before the new EPP started is
  invisible to it until its next turn stores more. With snapshots: 0 of 369.
- **Both EPPs route, and the handover is clean.** Envoy's host samples
  (`results/envoy-hosts-snapshot.tsv`) show the new pod healthy and taking requests 20 s into the
  rollout, the first old pod failing its health check at 47 s (its SIGTERM, after
  `minReadySeconds`), the second new pod at 61 s, the second old pod at 88 s. Request counters
  rose on every healthy host throughout. Nothing failed.

The first run of this demo had 54 failed long streams; they were a loadgen bug (a stream's
connection reused before its body was fully read), fixed in `loadgen.py`, not a rollout
failure: every one failed at 0.0 s with `ResponseNotReady` before reaching Envoy.
