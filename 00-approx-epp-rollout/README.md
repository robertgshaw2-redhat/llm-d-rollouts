# 00: Basic EPP rollout with approximate prefix-cache routing, and its limits

**What you'll learn:** what happens when you roll the llm-d router (the EPP) in its simplest,
default setup: one replica, approximate prefix-cache routing, a plain Deployment rollout.
Requests don't fail, but the router forgets where every prefix is cached. This example measures
that, and explains why nothing in this setup can prevent it. Examples
[01](../01-kv-aware-epp-rollout-active-passive/) and
[02](../02-kv-aware-epp-rollout-active-active/) are the fix.

Background: [prefix-cache routing](../docs/concepts.md#prefix-cache-routing-the-state-that-makes-a-rollout-expensive)
and [Problem 1](../docs/concepts.md#problem-1-rolling-the-router-loses-its-index) in the concepts doc.

- [Design](#design)
- [The limitations](#the-limitations)
- [How to run it](#how-to-run-it)
- [Results](#results)
- [Files](#files)

## Design

### The stack

Four aggregated vLLM pods, one EPP and Envoy. The model is `deepseek-ai/DeepSeek-V2-Lite-Chat`
on 1 H200 per pod. The vLLM image is a stock nightly with no extra flags for the router.

```
 probe pod (loadgen.py): 16 multi-turn chat sessions, 2 long streams, canaries, cold sessions
   |
   v
 Service apx :80
   |
 Envoy (apx-proxy) ---- ext_proc :9002 ---->  EPP (apx-epp), 1 replica
   |                    health check :9003     approx-prefix-cache-producer:
   |                                             "I sent this prefix to pod X"  (in memory)
   |  request to the pod the EPP picked
   v
 +--------------------------------------------------------------+
 | vLLM x4 (apx-vllm) :8000, 1 H200 each                          |
 +--------------------------------------------------------------+
         nothing flows back from vLLM to the EPP about what is cached
```

### How approximate prefix-cache routing works

```yaml
- type: approx-prefix-cache-producer      # the index
- type: prefix-cache-scorer               # weight 3: prefer the pod with the longest match
- type: queue-scorer                      # weight 1: spread load, break ties
- type: max-score-picker
```

For each request the producer:

1. tokenizes the prompt with a built-in estimate (no tokenizer, nothing asked of vLLM),
2. hashes it in 64-token blocks,
3. looks up which pods it has *sent* those blocks to, and scores each pod by how many leading
   blocks match,
4. after the scheduler picks a pod, records "these blocks are now on that pod" in a per-pod LRU.

It is a guess that works well in steady state: if the EPP sent a conversation to pod X, pod X
probably still has it cached, so the next turn goes back to X. It needs no cooperation from
vLLM, which is why it is the default.

### The rollout

`apx-epp` is a 1-replica Deployment with `maxSurge: 1`, `maxUnavailable: 0`,
`minReadySeconds: 30`. `rollout.sh roll` restarts it, which is what any config or image change
does:

```
 t=0     new EPP pod starts, syncs the pool: index EMPTY
 t~2s    Ready -> Envoy health-checks it -> requests round-robin over old and new EPP
         old EPP: knows every prefix it routed     new EPP: knows nothing
 t~32s   minReadySeconds -> Kubernetes stops the old pod -> NOT_SERVING -> Envoy drops it
         -> its open streams finish (terminationGracePeriodSeconds: 600)
         -> its index is gone
```

## The limitations

**1. A new EPP starts blind.** The index is built only from the EPP's own routing decisions and
lives only in its memory. A new pod has routed nothing, so it knows nothing. For it, every
existing conversation is a miss, routed by load. With 4 pods, a conversation lands back on the
pod holding its cache 1 time in 4, and recomputes its whole prefix the other 3.

**2. There is nothing to recover from.** The precise producer (examples 01, 02) indexes what
vLLM *reports* it holds, so a new EPP can ask vLLM for a snapshot. The approximate index records
what the EPP *decided*, which vLLM never saw as such, and v1.0.0 has no way to persist it or
hand it to the next pod. No setting in this setup closes the gap.

**3. Hot conversations pay once, idle ones pay later.** A conversation that is mid-flight
during the rollout loses one turn: the first turn the new EPP routes goes wherever load says,
and from then on the new EPP has recorded it. An idle conversation (a user who comes back in
five minutes, a shared system prompt used hourly) pays when it returns, whenever that is.

**4. During the overlap, two EPPs disagree.** While old and new both route (~30 s here), a
session's turns alternate between them. The old one sends it to its cached pod; the new one may
send it elsewhere. The same is true in steady state if you run two replicas without leader
election: each has its own index, built from the half of the traffic it routed.

**5. It is approximate in steady state, too.** It assumes a pod still holds what it was sent.
It doesn't see evictions (an LRU sized from vLLM's cache metrics stands in), and it doesn't see
prefixes that reached a pod some other way, such as through another router. That is the trade
for needing nothing from vLLM.

**What does survive:** requests. Envoy health-checks the EPPs, the old EPP drains its open
streams, and nothing fails. The cost of a rollout here is recomputation, not errors.

## How to run it

**Needs:** `kubectl` (with kustomize) and `python3` locally. On the cluster: the Gateway API
Inference Extension CRDs (InferencePool), a `llm-d-hf-token` secret (key `HF_TOKEN`) in the
namespace, and 4 free GPUs. The scripts default to `KUBECONFIG=~/.kube/kermit.yaml` and
`NS=robshaw-dev`; set both for your cluster, and see
[Running on your own cluster](../README.md#running-on-your-own-cluster).

### In one go

```console
$ export KUBECONFIG=~/.kube/<cluster>.yaml NS=<namespace>
$ cd 00-approx-epp-rollout
$ ./rollout.sh deploy          # vLLM x4, 1 EPP, Envoy; ~3 min with weights cached on the nodes
$ ./demo.sh                    # ~10 min: warm, baseline, rollout
$ ./probe.sh stop && ./rollout.sh clean
```

The verdict is printed at the end and saved to `results/report.txt`.

### Step by step

```console
$ ./probe.sh start                     # 16 chat sessions + 2 long streams -> apx:80
$ ./probe.sh mark 1-warm

# Baseline: 48 cold sessions, idle for about as long as a rollout takes, no rollout.
$ ./probe.sh cold-seed 48 baseline
$ ./probe.sh mark 2-baseline
$ sleep 75
$ ./probe.sh cold-probe 48 baseline    # turn 2: back on the turn-1 pod?

# The same across an EPP rollout.
$ ./probe.sh cold-seed 48 rollout
$ ./probe.sh mark 3-rolling
$ ./rollout.sh roll                    # blocks until the old EPP has exited
$ ./probe.sh mark 3-after
$ ./probe.sh cold-probe 48 rollout

$ ./probe.sh flush && ./report.py
```

`./rollout.sh status` shows the pods, how many requests each EPP has routed, and Envoy's view
of the EPP hosts. `results/envoy-hosts-<HHMMSS>.tsv` has Envoy's hosts every 2 s through the
roll: both EPPs healthy and taking requests during the overlap, then only the new one.

## Results

One run on CoreWeave `kermit`, 2026-10-29: 1,518 requests, one EPP rollout, **0 failed**
(including 20 long streams and 130 answer-checked canaries).

| 48 cold sessions, turn 2 ~75 s after turn 1 | back on the pod holding turn 1 | prefix-cache hit |
|---|---|---|
| no rollout in between (baseline) | **48/48 (100%)** | **48/48 (100%)** |
| EPP rolled in between | 14/48 (29%) | 14/48 (29%) |
| chance, 4 pods | 25% | |

- **In steady state approximate routing works:** every idle session went back to its pod.
  Across one EPP restart it fell to chance (limitation 1).
- **Hot sessions paid once:** 11 of 223 follow-up turns missed during the roll, then 0 of 390
  after it (limitation 3).
- **The two EPPs overlapped for ~25 s**, both healthy in Envoy and both taking requests, before
  the old one was stopped (limitation 4).
- The same number as example 01's control (rolling *precise* routing without snapshots, 15/48):
  without snapshots, the two kinds of index lose the same thing.

Per-phase numbers and how each claim is checked are in [RESULTS.md](RESULTS.md).

## Files

| | |
|---|---|
| `manifests/vllm.yaml` | 4 stock vLLM pods, the InferencePool |
| `manifests/epp.yaml` | 1 EPP, its rollout and drain settings, RBAC, Services |
| `manifests/config/epp.yaml` | EPP plugins: approximate prefix-cache producer + scorer, queue scorer |
| `manifests/proxy.yaml`, `manifests/config/envoy.yaml` | Envoy: ext_proc to the healthy EPP(s), `x-upstream-host` |
| `rollout.sh` | `deploy` / `roll` / `status` / `hosts` / `clean` |
| `probe.sh`, `loadgen.py` | in-cluster traffic, phase marks, cold sessions, capture |
| `report.py` | per-phase and cold-session verdict |
| `demo.sh` | the steps, in order |
| `results/` | where a run's capture and report land (not checked in) |
