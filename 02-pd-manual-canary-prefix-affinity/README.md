# 02: Zero-downtime manual canary of llm-d P/D, with prefix affinity across revisions

**What you'll learn:** how to replace one version of a prefill/decode-disaggregated stack with
another, by hand and one step at a time, under live multi-turn chat traffic, so that:

- no request fails and no prefill is ever paired with a decode of the other version, and
- every chat session stays on the version that holds its KV cache, moving at most once, from
  old to new.

Background: [P/D, the rollout screener and prefix affinity in the concepts doc](../docs/concepts.md#pd-disaggregation).
The hands-off version of the same rollout is [example 03](../03-pd-rolling-update-prefix-affinity/).

- [Design](#design)
- [How to run it](#how-to-run-it)
- [Results](#results)
- [Files](#files)

## Design

### The rollout

| step | action | fleet | v0 / v1 share |
|---|---|---|---|
| 1 | deploy the router + **v0** | v0 2P+2D | 100 / 0 |
| 2 | traffic | | |
| 3 | admit **v1** (the canary) | v0 2P+2D, v1 1P+1D | 67 / 33 |
| 4 | traffic, with a control router without affinity alongside | | |
| 5 | scale v0 down to 1P+1D, draining | v0 1P+1D, v1 1P+1D | 50 / 50 |
| 6 | scale v1 up to 2P+2D | v0 1P+1D, v1 2P+2D | 33 / 67 |
| 7 | retire v0, draining | v1 2P+2D | 0 / 100 |

You can stop at any step, hold the canary as long as you like, or go back. The model is
`deepseek-ai/DeepSeek-V2-Lite-Chat`, and every replica is one pod with 1 H200 (TP=1). The peak is
6 GPUs.

### The stack

```
 probe pod (loadgen.py): 16 chat sessions x 20 turns, 2 long streams, canaries
   |
   v
 pdcanary-router :80 (Envoy) --ext_proc--> EPP: rollout screener -> prefill profile + decode profile
   |
   |  to the chosen decode pod, with the chosen prefill pod in a header
   v
 +----------------- revision A (pdcanary-v0) ---+   +----------------- revision B (pdcanary-v1) ---+
 | decode: sidecar :8000 -> vLLM :8200          |   | decode: sidecar :8000 -> vLLM :8200          |
 |            |  1. prompt                      |   |            |                                 |
 |            v                                 |   |            v                                 |
 | prefill: vLLM :8000  --2. KV over NIXL-->    |   | prefill: vLLM :8000  --KV over NIXL-->       |
 +----------------------------------------------+   +----------------------------------------------+
            never paired across the line: the screener hides the other revision's pods
```

**Two DisaggregatedSet objects, one per version.** `pdcanary-v0` and `pdcanary-v1` are stamped
from one base by the `manifests/v0` and `manifests/v1` overlays. They differ in the version's
knob (`--max-num-seqs` 64 vs 128, standing in for "a new image" or "new flags") and a version
label, so their pods carry different `disaggregatedset.x-k8s.io/revision` labels. Each step is a
patch of one object's replica counts. Nothing ever changes a live object's pod template, so the
controller never starts a rollout of its own: you drive it.

**One InferencePool, one EPP, one screener over both objects.** The pool selects every pod of
every version (`llm-d.ai/guide: pdcanary`), and so does the screener's scope. Because there are
two sets, the scope can't be the set name:

```yaml
- type: disaggregatedset-rollout-screener
  parameters:
    scope:
      labelSelector: "llm-d.ai/guide=pdcanary"
    revisionGating:
      mode: max-role                  # share = share of Ready pods of the most numerous role
      requiredRoles: [prefill, decode]
      disableCoordination: true       # one EPP, sequential P/D
      affinity:
        mode: prefix                  # llm-d/llm-d-router#3456
```

For every request the screener picks one revision and hides the other revision's pods from
both profiles. That is what makes the canary safe:

- **Admitting v1 needs no traffic gate.** A revision is offered only once it has a Ready pod of
  *every* required role, so v1 gets nothing while its pods load.
- **Shares follow capacity.** 2P2D next to 1P1D is 67/33, and each step moves the split.
- **No cross-version pairs.** A v0 prefill is never paired with a v1 decode.

**Prefix affinity keeps sessions in place.** Without it, the screener draws the revision at random
per request. At 67/33, a third of a session's turns land on the other revision and recompute
the whole conversation, back and forth, for the whole rollout. With `affinity.mode: prefix` the
draw is a hash of the conversation up to its first user message, so every turn of a session gets
the same revision. When a step moves the shares, only the sessions in the moved slice switch, to
v1, once:

```
 step 4  67/33   [============ v0 ============|====== v1 ======]
 step 5  50/50   [======== v0 ========|========== v1 ==========]
                                      ^^^^^^^^  these sessions move to v1
 step 6  33/67   [==== v0 ====|============== v1 ==============]
                              ^^^^^^^^  then these
 step 7   0/100  [============================ v1 =============]
```

**Within a revision**, both profiles score with the approximate prefix-cache scorer (weight 3,
plus a load scorer at weight 1), so a session also returns to the same prefill and decode pods.

**Draining** is covered in
[the concepts doc](../docs/concepts.md#draining-without-dropping-requests): `preStop: sleep 20`,
`--shutdown-timeout 90`, the routing sidecar as a native sidecar, and
`kv_load_failure_policy: fail` so a lost KV transfer can't hide as a silent recompute.

### Why not just `kubectl apply` a new template?

You can. That is [example 03](../03-pd-rolling-update-prefix-affinity/), and the router config is
identical. Two objects buy you control: hold a 1P1D canary for a day, compare it against v0 on
real traffic, and roll back by deleting one object. The cost is that you drive every step.

### Images

| | |
|---|---|
| vLLM | `vllm/vllm-openai` nightly 2026-09-18, by digest; `nixl` installed at start if missing |
| routing sidecar | `ghcr.io/llm-d/llm-d-router-disagg-sidecar:v1.0.0`, by digest |
| EPP | `ghcr.io/robertgshaw2-redhat/llm-d-router-endpoint-picker:cb-v1.0.0-68c5e10`, public, by digest. This is llm-d-router v1.0.0 plus #3456, which is not in a release yet; see [the top-level README](../README.md#unreleased-pieces) for how it was built |

## How to run it

**Needs:** `kubectl`, `jq` and `python3` locally. On the cluster: LWS v0.10+ with the
DisaggregatedSet CRD, the Gateway API Inference Extension CRDs (InferencePool), a
`llm-d-hf-token` secret (key `HF_TOKEN`) in the namespace, and 6 free GPUs with RDMA (`rdma/ib`)
for NIXL. The scripts default to `KUBECONFIG=~/.kube/kermit.yaml` and `NS=robshaw-dev`; set both
for your cluster, and see
[Running on your own cluster](../README.md#running-on-your-own-cluster).

### In one go

```console
$ export KUBECONFIG=~/.kube/<cluster>.yaml NS=<namespace>
$ cd 02-pd-manual-canary-prefix-affinity
$ ./demo.sh                    # all seven steps, ~25 min plus model loading
$ ./probe.sh stop && ./rollout.sh clean
```

The verdict is printed at the end and saved to `results/report.txt`. `HOLD=60` shortens the
traffic windows (default 150 s), and `CONTROL=0` skips the control router.

### Step by step

`demo.sh` is these commands in this order. Each `rollout.sh` step blocks until the fleet has
settled (new pods Ready, old pods drained and gone).

```console
# 1. router + v0 (2 prefill, 2 decode)
$ ./rollout.sh deploy
$ ./rollout.sh watch start             # prefix-cache counters + screener shares every 10 s
$ ./probe.sh start                     # 16 session workers + 2 long streams -> pdcanary-router:80

# 2. traffic on v0
$ ./probe.sh mark 2-v0-2p2d
$ ./probe.sh tail                      # (optional) 10 s summaries; ctrl-c to leave

# 3. admit v1 next to v0
$ ./probe.sh mark 3-v1-loading
$ ./rollout.sh canary

# 4. traffic on both: ~67% v0 / 33% v1, by session
$ ./probe.sh mark 4-v0-2p2d+v1-1p1d
$ ./rollout.sh control start           # (optional) second router, same pods, affinity none
$ POD=pdcanary-control-probe URL=http://pdcanary-control:80 WORKERS=8 RESULTS=$PWD/results/control ./probe.sh start
$ ./rollout.sh status                  # pods by revision, per-pod hit rates, screener shares
$ POD=pdcanary-control-probe RESULTS=$PWD/results/control ./probe.sh stop
$ ./rollout.sh control stop

# 5. v0 -> 1P1D, draining: 50/50
$ ./probe.sh mark 5-v0-draining-to-1
$ ./rollout.sh scale v0 1

# 6. v1 -> 2P2D: ~33/67
$ ./probe.sh mark 6-v1-scaling-to-2
$ ./rollout.sh scale v1 2

# 7. retire v0, draining
$ ./probe.sh mark 7-v0-draining-to-0
$ ./rollout.sh retire v0

# verdict, then teardown
$ ./probe.sh flush && ./rollout.sh watch stop && ./report.py
$ ./probe.sh stop && ./rollout.sh clean
```

To roll back at any point, scale the other way (`./rollout.sh scale v0 2`,
`./rollout.sh retire v1`). Don't re-`apply -k` an overlay mid-rollout: it resets that version's
replica counts to its admission shape (v0 2+2, v1 1+1).

### See affinity by hand

Send the same conversation twice: same first user message, same revision, every time. Change
the first message and you may land on the other one.

```console
$ kubectl -n $NS port-forward svc/pdcanary-router 8000:80 &
$ curl -si localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-ai/DeepSeek-V2-Lite-Chat","messages":[{"role":"user","content":"The capital of France is"}],"max_tokens":8}' \
    | grep -i -e '^HTTP' -e x-llm-d-disagg-revision
```

## Results

One run on CoreWeave `kermit`, 2026-10-29: 3,401 requests through all seven steps, **0 failed**
(including 45 long streams and 300 answer-checked canaries, through two drains and a
retirement).

| | follow-up turns | changed version | sessions that moved back v1 → v0 |
|---|---|---|---|
| **prefix affinity** (all 7 steps) | 2,914 | **10 (0.3%)**, each a single v0 → v1 move | **0** |
| control, no affinity (step 4 only) | 213 | 91 (42.7%) | 15 |

- 150 of 160 sessions were served by one version for their whole life.
- The traffic split still followed the pods: 67/33, then 40/60, then 29/71.
- The prefill prefix-cache hit rate held at 89–93% while both versions were serving, the same
  as with a single version. It dipped only while pods were being removed (79%, 85%).

Per-phase tables and how each claim is checked are in [RESULTS.md](RESULTS.md).

## Files

| | |
|---|---|
| `manifests/base/disaggregatedset.yaml` | one version of the stack: prefill + decode roles, TP=1, drain settings |
| `manifests/v0`, `manifests/v1` | overlays: name suffix, admission replica counts, the version's knob |
| `manifests/router/` | EPP + Envoy (with `__ROUTER__`/`__AFFINITY__` placeholders), the EPP config, the InferencePool |
| `rollout.sh` | `deploy` / `canary` / `scale` / `retire` / `watch` / `control` / `status` / `clean` |
| `probe.sh`, `loadgen.py` | in-cluster multi-turn chat traffic, phase marks, capture |
| `report.py` | per-phase and per-session verdict from the capture |
| `demo.sh` | the seven steps, in order |
| `results/` | where a run's capture, counters and report land (not checked in) |
