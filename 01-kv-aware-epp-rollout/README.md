# 01: KV-aware rollout of an active-active EPP

**What you'll learn:** how to roll out the llm-d router itself (the EPP) under live traffic
without dropping requests *and* without forgetting which vLLM pod holds which prefix. The trick
is KV-event snapshots: a new EPP pod loads each vLLM pod's cache state before it takes traffic.

Background: [Problem 1 in the concepts doc](../docs/concepts.md#problem-1-rolling-the-router-loses-its-index).

- [Design](#design)
- [How to run it](#how-to-run-it)
- [Results](#results)
- [Files](#files)

## Design

### The problem

The EPP routes on a KV-cache index it builds from the vLLM pods' KV events (block stored, block
evicted). A new EPP pod starts with an empty index and only hears about blocks stored after it
subscribes. After a router rollout, every prefix cached before it (each idle conversation, each
shared system prompt) looks like a miss. It gets routed by load, probably to a pod that has to
recompute it, while the pod holding it sits idle.

### The stack

Four aggregated vLLM pods (no P/D), two EPPs, Redis and Envoy. The model is
`deepseek-ai/DeepSeek-V2-Lite-Chat` on 1 H200 per pod.

```
 probe pod (loadgen.py): 16 multi-turn chat sessions, 2 long streams, canaries, cold sessions
   |
   v
 Service kvepp :80
   |
 Envoy (kvepp-proxy) ---- ext_proc :9002, round-robin over healthy EPPs ------------+
   |                       gRPC health check :9003 every 2 s                         |
   |                                                                                 v
   |                                            +------------------+     +------------------+
   |                                            | EPP A            |<--->| Redis            |
   |                                            | (kvepp-epp)      |     | in-flight load   |
   |                                            +------------------+     | per vLLM pod     |
   |                                            | EPP B            |<--->| (redis-syncer)   |
   |                                            +------------------+     +------------------+
   |  request to the pod the EPP picked               ^   KV events  (ZMQ PUB    :5557)
   |  (x-gateway-destination-endpoint)                |   snapshots  (ZMQ ROUTER :6557)
   v                                                  |   tokenize   (/v1/chat/completions/render)
 +--------------------------------------------------------------+
 | vLLM x4 (kvepp-vllm) :8000, 1 H200 each                        |
 +--------------------------------------------------------------+
```

Three design choices:

**1. Active-active EPPs.** Both replicas run with no leader election, so both pass Envoy's health
check and Envoy spreads requests over them. Each subscribes to every vLLM pod's KV events and
builds the same index. The only state they would disagree on is load, since each sees only its
own in-flight requests, so they share per-pod in-flight counts through Redis:

```yaml
- type: redis-syncer
  name: redis
  parameters: {address: kvepp-redis:6379, stateTTL: 2s}
...
dataLayer:
  crossReplicaSyncerPluginRef: redis
```

With two active routers, a rolling update always leaves a fully warmed router serving. With
leader election, the handover would be a moment with one cold router.

**2. Precise prefix-cache routing.** Per request the EPP:

| plugin | does |
|---|---|
| `token-producer` | tokenizes the request on a vLLM pod (`/v1/chat/completions/render`, enabled by `--enable-scale-out`), so block hashes match vLLM's |
| `precise-prefix-cache-producer` | looks the 64-token blocks up in the index built from KV events |
| `prefix-cache-affinity-filter` | keeps only pods holding ≥ half the prefix, unless queueing there would cost more TTFT than recomputing elsewhere |
| `token-load-scorer` | picks by load among the survivors |

**3. Snapshots.** One field on each side:

```yaml
# vLLM: --kv-events-config
{"enable_kv_cache_events": true, "publisher": "zmq",
 "endpoint": "tcp://*:5557", "snapshot_endpoint": "tcp://*:6557", ...}

# EPP: precise-prefix-cache-producer.kvEventsConfig.podDiscoveryConfig
socketPort: 5557           # live events
snapshotSocketPort: 6557   # snapshots   <- the whole feature, router side
```

When the EPP discovers a vLLM pod, it asks the snapshot socket for every block the pod
currently holds, tagged with the event sequence number, loads them, and then follows the live
stream from that sequence number with no gap and no duplicates. This took about 100 ms per pod.

### The rollout

`kvepp-epp` is an ordinary Deployment: 2 replicas, `maxSurge: 1`, `maxUnavailable: 0`,
`minReadySeconds: 30`. For each of the two pods:

```
 t=0     new EPP pod starts -> discovers 4 vLLM pods -> loads 4 snapshots (~0.1 s each)
 t=10s   readiness probe starts (pool synced, not draining) -> Ready
         -> enters the headless Service -> Envoy resolves it, health-checks it, sends it traffic
         now serving: old A, old B, new A
 t=40s   minReadySeconds passes -> Kubernetes stops an old pod
         -> it reports NOT_SERVING -> Envoy marks it unhealthy within 4 s, sends nothing new
         -> streams it already holds finish (terminationGracePeriodSeconds: 600)
 ...     the same for the second pod
```

The readiness probe's 10 s initial delay is what guarantees the snapshots are in before the pod
gets traffic. The vLLM pods, Redis and Envoy are not touched.

### vLLM with the snapshot PR

Snapshots are [vllm-project/vllm#57789](https://github.com/vllm-project/vllm/pull/57789)
(branch `vMaroon/vllm` `codex/kv-event-snapshots`, head `4319361e`), not yet in a release. The PR
is pure Python and touches three files, so rather than build an image this example runs the
public nightly that contains the PR's base (`41f5146b`) and copies the PR's three files over it
at start:

| PR file | vendored as (mounted from a ConfigMap) |
|---|---|
| `vllm/config/kv_events.py` | `manifests/vllm-kv-snapshots/config_kv_events.py` |
| `vllm/distributed/kv_events.py` | `manifests/vllm-kv-snapshots/distributed_kv_events.py` |
| `vllm/distributed/kv_events_snapshot.py` (new) | `manifests/vllm-kv-snapshots/distributed_kv_events_snapshot.py` |

To move to a newer nightly, check that the three files are unchanged between the PR base and the
nightly (`git diff 41f5146b <nightly-sha> -- <files>`), or vendor them again.

The router side ([llm-d/llm-d-router#2946](https://github.com/llm-d/llm-d-router/pull/2946)) and
`redis-syncer` are both in llm-d-router **v1.0.0**, which is what the EPP runs. Every image in
this example is public.

## How to run it

**Needs:** `kubectl` (with kustomize) and `python3` locally. On the cluster: the Gateway API
Inference Extension CRDs (InferencePool), a `llm-d-hf-token` secret (key `HF_TOKEN`) in the
namespace, and 4 free GPUs (H200 here; anything that fits DeepSeek-V2-Lite works). The scripts
default to `KUBECONFIG=~/.kube/kermit.yaml` and `NS=robshaw-dev`; set both for your cluster, and
see [Running on your own cluster](../README.md#running-on-your-own-cluster).

### In one go

```console
$ export KUBECONFIG=~/.kube/<cluster>.yaml NS=<namespace>
$ cd 01-kv-aware-epp-rollout
$ ./rollout.sh deploy          # vLLM x4, Redis, 2 EPPs, Envoy; ~3 min with weights cached on the nodes
$ ./demo.sh                    # ~20 min: warm, roll with snapshots, roll without, restore
$ ./probe.sh stop && ./rollout.sh clean
```

The verdict is printed at the end and saved to `results/report.txt`. `HOLD=60 ./demo.sh` shortens
the traffic windows (default 120 s).

### Step by step

`demo.sh` is exactly this:

```console
$ ./probe.sh start                     # in-cluster probe: 16 chat sessions + 2 long streams -> kvepp:80
$ ./probe.sh mark 1-warm               # label the timeline
$ ./probe.sh tail                      # (optional) 10 s summaries; ctrl-c to leave

# The test: 48 "cold" sessions get their turn 1 now, then go quiet through the rollout.
$ ./probe.sh cold-seed 48 snapshot
$ ./probe.sh mark 2-rolling-snapshot
$ ./rollout.sh roll snapshot           # rolls both EPP pods; blocks until the old ones have exited
$ ./probe.sh mark 2-after-snapshot
$ ./probe.sh cold-probe 48 snapshot    # their turn 2, routed by EPPs that never saw turn 1's events

# The control: the same, rolling to a config without snapshotSocketPort.
$ ./probe.sh cold-seed 48 nosnap
$ ./probe.sh mark 3-rolling-nosnap
$ ./rollout.sh roll nosnap
$ ./probe.sh mark 3-after-nosnap
$ ./probe.sh cold-probe 48 nosnap

# Back to the committed config.
$ ./probe.sh mark 4-rolling-restore
$ ./rollout.sh roll snapshot
$ ./probe.sh mark 4-after-restore

$ ./probe.sh flush && ./report.py
```

### Things to look at while it runs

- `./rollout.sh status`: the pods, how many requests each EPP has routed
  (`llm_d_epp_request_total`), and Envoy's view of the EPP hosts (`health_flags`, `rq_total`).
- `results/epp-<pod>.log`: each EPP's log, followed during `roll`. Look for `Snapshot loaded`
  lines a fraction of a second after the pod starts.
- `results/envoy-hosts-<scenario>.tsv`: Envoy's EPP hosts sampled every 2 s during a roll. The new
  pod turns healthy and starts counting requests, then the old pod turns unhealthy.
- A request by hand. The `x-upstream-host` response header is the vLLM pod that served it.
  ```console
  $ kubectl -n $NS port-forward svc/kvepp 8000:80 &
  $ curl -si localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"deepseek-ai/DeepSeek-V2-Lite-Chat","messages":[{"role":"user","content":"The capital of France is"}],"max_tokens":8}' \
      | grep -i -e '^HTTP' -e x-upstream-host
  ```

## Results

One run on CoreWeave `kermit`, 2026-10-29: 2,746 requests through three EPP rollouts,
**0 failed** (including 38 long streams and 241 answer-checked canaries).

| 48 cold sessions, turn 2 after both EPPs were replaced | back on the pod holding turn 1 | prefix-cache hit |
|---|---|---|
| rolled **with** snapshots | **48/48 (100%)** | **48/48 (100%)** |
| rolled without snapshots (control) | 8/48 (17%) | 13/48 (27%) |
| chance, 4 pods | 25% | |

- Each new EPP loaded all four snapshots in 97–125 ms each, within a second of starting and well
  before it took traffic.
- Conversations that were mid-flight during the roll notice too: without snapshots, 22 of 302
  follow-up turns missed the cache. With snapshots, 0 of 369 did.

Per-phase tables, the Envoy handover timeline and how each claim is checked are in
[RESULTS.md](RESULTS.md).

## Files

| | |
|---|---|
| `manifests/vllm.yaml` | 4 vLLM pods with KV events + snapshots, their Service (tokenization), the InferencePool |
| `manifests/vllm-kv-snapshots/` | the three files of vllm-project/vllm#57789, vendored |
| `manifests/epp.yaml` | the 2 active-active EPPs, their rollout and drain settings, RBAC, Services |
| `manifests/config/epp.yaml` | EPP plugins: precise prefix-cache routing, snapshots, Redis sync |
| `manifests/redis.yaml` | Redis for the cross-replica in-flight state |
| `manifests/proxy.yaml`, `manifests/config/envoy.yaml` | Envoy: ext_proc over the healthy EPPs, `x-upstream-host` |
| `rollout.sh` | `deploy` / `roll [snapshot\|nosnap]` / `status` / `hosts` / `clean` |
| `probe.sh`, `loadgen.py` | in-cluster traffic, phase marks, cold sessions, capture |
| `report.py` | per-phase and cold-session verdict, snapshot loads from the EPP logs |
| `demo.sh` | the steps, in order |
| `results/` | where a run's capture, logs and report land (not checked in) |
