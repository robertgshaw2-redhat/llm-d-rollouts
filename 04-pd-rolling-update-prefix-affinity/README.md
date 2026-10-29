# 04: Zero-downtime rolling update of llm-d P/D, with prefix affinity across revisions

**What you'll learn:** the hands-off version of a P/D rollout. You have one DisaggregatedSet and
run one `kubectl apply` of the new pod template, and the controller rolls both roles by itself
under live multi-turn chat traffic. Meanwhile the router keeps every session on the revision
that holds its KV cache until the roll moves it to the new revision, once.

Background: [P/D, the rollout screener and prefix affinity in the concepts doc](../docs/concepts.md#pd-disaggregation).
The step-by-step version of the same rollout is [example 03](../03-pd-manual-canary-prefix-affinity/).

- [Design](#design)
- [How to run it](#how-to-run-it)
- [Results](#results)
- [Files](#files)

## Design

### The rollout

| step | action | fleet |
|---|---|---|
| 1 | deploy the router + `pdroll` at v0 | v0 2P+2D |
| 2 | traffic, with a control router without affinity alongside throughout | |
| 3 | `kubectl apply -k manifests/v1`: the controller surges one group at a time, per role | v0 2P+2D → … → v1 2P+2D |
| 4 | traffic | v1 2P+2D |

The model is `deepseek-ai/DeepSeek-V2-Lite-Chat`, and every replica is one pod with 1 H200 (TP=1).
The peak is 6 GPUs: 4, plus one surge group per role.

### The stack

The same as [example 03](../03-pd-manual-canary-prefix-affinity/#the-stack): one Envoy, one EPP
with the rollout screener, prefill and decode pods with the routing sidecar and NIXL. The only
differences are that there is one DisaggregatedSet instead of two and the screener's scope is
the set's name.

**One DisaggregatedSet, rolled by its controller.** Both roles carry

```yaml
rolloutStrategy:
  type: RollingUpdate
  rollingUpdateConfiguration:
    maxSurge: 1          # one extra group per role while rolling
    maxUnavailable: 0    # never remove an old group before its replacement is Ready
```

The v0 and v1 overlays differ in `--max-num-seqs` (64 vs 128) and a version label. Any change to
the pod template is a new `disaggregatedset.x-k8s.io/revision`, and applying it starts a roll.
The controller interleaves the prefill and decode steps to keep the two roles' progress close
(see the DisaggregatedSet rollout KEP, `kubernetes-sigs/lws` `keps/766-DisaggregatedSet`, and its
`hack/plan-steps` planner).

**The rollout screener, scoped to the set, with prefix affinity:**

```yaml
- type: disaggregatedset-rollout-screener
  parameters:
    scope:
      labelSelector: "disaggregatedset.x-k8s.io/name=pdroll"
    revisionGating:
      mode: max-role
      requiredRoles: [prefill, decode]
      disableCoordination: true       # one EPP, sequential P/D
      affinity:
        mode: prefix                  # llm-d/llm-d-router#3456
```

The controller moves on its own schedule, and the screener follows it from Ready pods alone.
These are the main steps from the run below, as `rollout.sh update` printed them:

```
  t     Ready pods (controller)                       screener share      sessions
   1s   v0 2P 2D | v1 0P 0D, +1P +1D starting         v0 100             all on v0
  60s   v0 1P 1D, +1P +1D draining                    v0 50  / v1 50     one slice -> v1, once
        v1 1P 1D, +1P +1D starting
 138s   v0 1P 1D | v1 1P 2D, +1P starting             v0 33  / v1 67     next slice -> v1, once
 239s   v0 0P 0D, +1P +1D draining | v1 2P 2D         v1 100             the rest -> v1, once
 275s   v1 2P 2D                                      v1 100
```

(At 138 s decode is the most numerous role, with 3 Ready pods, 2 of them v1, hence 33/67.)

- A new revision is only offered once it has a Ready pod of **both** roles, so a half-started
  surge group gets no traffic.
- The covered revisions are weighted by their Ready pods of the most numerous role.
- Each request's prefill and decode come from the same revision.
- With prefix affinity, the draw is a hash of the conversation up to its first user message.
  Each step moves the boundary between the two revisions toward the old one, and only the
  sessions it passes move, to the new revision, once. See the
  [boundary diagram](../03-pd-manual-canary-prefix-affinity/#the-stack) in example 03.

**Within a revision**, both profiles score with the approximate prefix-cache scorer, so a session
also returns to the same prefill and decode pods.

**Draining** is covered in
[the concepts doc](../docs/concepts.md#draining-without-dropping-requests). It matters more here
than in 03: the controller deletes old pods as soon as their replacements are Ready, whether or
not they are mid-generation.

### 03 or 04?

| | 03 manual canary | 04 rolling update |
|---|---|---|
| objects | one DisaggregatedSet per version | one DisaggregatedSet |
| who drives | you, one `scale` at a time | the controller, after one `apply` |
| hold at a mix / bake a canary | yes, as long as you like | no, it rolls through |
| roll back | scale the other way, delete an object | `apply` the old template, which rolls again |
| router config | screener scoped by a shared label | screener scoped by the set name; otherwise identical |

### Images

The same as example 03. The EPP is `ghcr.io/robertgshaw2-redhat/llm-d-router-endpoint-picker:cb-v1.0.0-68c5e10`
(llm-d-router v1.0.0 plus #3456, public, by digest); see
[the top-level README](../README.md#unreleased-pieces).

## How to run it

**Needs:** the same as example 03: `kubectl`, `jq` and `python3` locally. On the cluster: LWS
v0.10+ with the DisaggregatedSet CRD, the InferencePool CRDs, a `llm-d-hf-token` secret, and 6
free GPUs with `rdma/ib`. Set `KUBECONFIG` and `NS` (defaults: `~/.kube/kermit.yaml`,
`robshaw-dev`), and see [Running on your own cluster](../README.md#running-on-your-own-cluster).

### In one go

```console
$ export KUBECONFIG=~/.kube/<cluster>.yaml NS=<namespace>
$ cd 04-pd-rolling-update-prefix-affinity
$ ./demo.sh                    # ~15 min plus model loading
$ ./probe.sh stop && ./rollout.sh clean
```

The verdict is printed at the end and saved to `results/report.txt`. `HOLD=60` shortens the
traffic windows (default 150 s), and `CONTROL=0` skips the control router.

### Step by step

```console
$ ./rollout.sh deploy                  # router + pdroll at v0 (2P2D); waits Ready
$ ./rollout.sh watch start             # prefix-cache counters + screener shares every 5 s
$ ./probe.sh start                     # 16 session workers + 2 long streams -> pdroll-router:80

# (optional) control: a second router over the same pods with affinity none, its own sessions
$ ./rollout.sh control start
$ POD=pdroll-control-probe URL=http://pdroll-control:80 WORKERS=8 RESULTS=$PWD/results/control ./probe.sh start

$ ./probe.sh mark 2-v0
$ ./probe.sh mark 3-rolling-to-v1
$ ./rollout.sh update v1               # = kubectl apply -k manifests/v1, then prints every step
$ ./probe.sh mark 4-v1

$ POD=pdroll-control-probe RESULTS=$PWD/results/control ./probe.sh stop && ./rollout.sh control stop
$ ./probe.sh flush && ./rollout.sh watch stop && ./report.py
$ ./probe.sh stop && ./rollout.sh clean
```

`./rollout.sh update v0` rolls back the same way. While it rolls, `./rollout.sh status` in another
terminal shows the pods by revision, each pod's prefix-cache hit rate and the screener's current
shares.

## Results

One run on CoreWeave `kermit`, 2026-10-29. The controller replaced all 4 pods in 275 s, and
2,026 requests went through the roll with **0 failed** (including 23 long streams and 178
answer-checked canaries). The control router's 984 requests also had 0 failures.

| through the same roll | follow-up turns | changed version | moved back v1 → v0 |
|---|---|---|---|
| **prefix affinity** | 1,775 | **15 (0.8%)**, each a single v0 → v1 move | **0** |
| control, no affinity | 830 | 119 (14.3%) | 17 sessions |

- 82 of 97 sessions never changed version. Without affinity, on the same pods at the same
  moments, 17 of 48 sessions changed revision more than once.
- The prefill prefix-cache hit rate during the roll (89%) stayed close to the single-version
  level (93%).

Per-phase tables, the controller's steps as they happened and how each claim is checked are in
[RESULTS.md](RESULTS.md).

## Files

| | |
|---|---|
| `manifests/base/disaggregatedset.yaml` | the stack: prefill + decode roles at 2 replicas, TP=1, `RollingUpdate` surge 1, drain settings |
| `manifests/v0`, `manifests/v1` | the two versions of the pod template (`--max-num-seqs` 64 vs 128) |
| `manifests/router/` | EPP + Envoy (with `__ROUTER__`/`__AFFINITY__` placeholders), the EPP config, the InferencePool |
| `rollout.sh` | `deploy` / `update` / `watch` / `control` / `status` / `clean` |
| `probe.sh`, `loadgen.py` | in-cluster multi-turn chat traffic, phase marks, capture |
| `report.py` | per-phase and per-session verdict from the capture |
| `demo.sh` | the steps, in order |
| `results/` | where a run's capture, counters and report land (not checked in) |
