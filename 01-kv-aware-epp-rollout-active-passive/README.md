# 01: KV-aware rollout of an active-passive EPP

**What you'll learn:** how to roll out the llm-d router itself (the EPP) under live traffic
without dropping requests *and* without forgetting which vLLM pod holds which prefix. The router
runs as a leader and a hot standby (leader election), and KV-event snapshots let every new EPP pod
load each vLLM pod's cache state before it can take over.

Background: [Problem 1](../docs/concepts.md#problem-1-rolling-the-router-loses-its-index) and
[active-passive vs active-active](../docs/concepts.md#running-more-than-one-epp-active-passive-or-active-active)
in the concepts doc. [Example 00](../00-approx-epp-rollout/) shows what goes wrong in the
default setup, which this example fixes. The same rollout with both EPPs routing at once is
[example 02](../02-kv-aware-epp-rollout-active-active/).

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

Four aggregated vLLM pods (no P/D), two EPPs and Envoy. The model is
`deepseek-ai/DeepSeek-V2-Lite-Chat` on 1 H200 per pod.

```
 probe pod (loadgen.py): 16 multi-turn chat sessions, 2 long streams, canaries, cold sessions
   |
   v
 Service kvap :80
   |
 Envoy (kvap-proxy) ---- ext_proc :9002, only to the EPP that passes the health check -----+
   |                      gRPC health check :9003 every 2 s                                 |
   |                                                                                        v
   |                                         +---------------------------+   +------------------------+
   |                                         | EPP leader (kvap-epp)     |   | Lease                  |
   |                                         | SERVING: routes           |---| epp-<ns>-kvap.llm-d.ai |
   |                                         +---------------------------+   +------------------------+
   |                                         | EPP standby               |
   |                                         | NOT_SERVING: same index,  |
   |                                         | ready to take the lease   |
   |                                         +---------------------------+
   |  request to the pod the leader picked          ^   KV events  (ZMQ PUB    :5557)  to both
   |  (x-gateway-destination-endpoint)              |   snapshots  (ZMQ ROUTER :6557)
   v                                                |   tokenize   (/v1/chat/completions/render)
 +--------------------------------------------------------------+
 | vLLM x4 (kvap-vllm) :8000, 1 H200 each                         |
 +--------------------------------------------------------------+
```

Three design choices:

**1. A leader and a hot standby.** Both replicas run with `--ha-enable-leader-election` and
compete for a Kubernetes Lease. Both sync the pool, subscribe to every vLLM pod's KV events and
build the same index. (llm-d-router v1.0.0 populates a non-leader's datastore by default, so a
standby can route correctly the moment it has to.) Only the leader passes the ext_proc health
check, so Envoy sends every request to it, and queueing and in-flight load live in one process.
Two settings make this work with an ordinary Deployment rollout:

```yaml
# EPP pod: readiness on the always-passing liveness service, so the standby is Ready and a
# rollout can complete. (The readiness service passes only on the leader; a new pod would
# never turn Ready.) Which pod routes is decided by Envoy's health check, not pod readiness.
readinessProbe:
  grpc: {port: 9003, service: liveness}
  initialDelaySeconds: 10

# Envoy ext_proc cluster: if no EPP is healthy (the seconds of a handover), spread requests
# over all of them rather than fail. The standbys route them.
common_lb_config:
  healthy_panic_threshold: {value: 1}
health_checks:
- interval: 2s
  unhealthy_threshold: 2
  healthy_threshold: 1
  grpc_health_check: {service_name: envoy.service.ext_proc.v3.ExternalProcessor}
```

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
stream from that sequence number with no gap and no duplicates. This takes about 100 ms per pod.

A standby that has been running for a while doesn't need snapshots: it has heard every event.
A **new** standby, which is what a rollout creates, does. Without snapshots, a rollout that
ends with a new pod as leader routes every prefix cached before that pod started as a miss.

### The rollout

`kvap-epp` is an ordinary Deployment: 2 replicas, `maxSurge: 1`, `maxUnavailable: 0`,
`minReadySeconds: 30`. For each of the two pods:

```
 t=0     new EPP pod starts as a standby -> discovers 4 vLLM pods -> loads 4 snapshots (~0.1 s each)
 t=10s   Ready (liveness service) -> enters the headless Service -> Envoy health-checks it:
         NOT_SERVING (not the leader). Serving: the old leader. Warm standbys: old, new.
 t=40s   minReadySeconds passes -> Kubernetes stops an old pod. Which one is up to Kubernetes:
           a standby: nothing happens to traffic.
           the leader: on SIGTERM it releases the lease and reports NOT_SERVING.
             -> another pod takes the lease within 2 s (retry period). It may be a Ready
                standby, or the pod Kubernetes created at the same moment, seconds old.
             -> Envoy routes to the new leader once it passes a health check: within 2 s for
                a Ready standby, ~10 s for a fresh pod (it isn't in the headless Service
                until Ready). In between, no EPP is healthy, Envoy panics and spreads requests
                over the Ready standbys, which route them from the same index.
             -> streams the old leader holds finish (terminationGracePeriodSeconds: 600)
 ...     the same for the second pod
```

So a rollout has one or two leader handovers, each covered by panic routing to the warm
standbys. And the new leader can be a pod that is a second old: it knows the old prefixes only
because it loaded the snapshots first. The vLLM pods and Envoy are not touched.

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
leader election with a populated standby are both in llm-d-router **v1.0.0**, which is what the
EPP runs. Every image in this example is public.

## How to run it

**Needs:** `kubectl` (with kustomize) and `python3` locally. On the cluster: the Gateway API
Inference Extension CRDs (InferencePool), a `llm-d-hf-token` secret (key `HF_TOKEN`) in the
namespace, and 4 free GPUs (H200 here; anything that fits DeepSeek-V2-Lite works). The scripts
default to `KUBECONFIG=~/.kube/kermit.yaml` and `NS=robshaw-dev`; set both for your cluster, and
see [Running on your own cluster](../README.md#running-on-your-own-cluster).

### In one go

```console
$ export KUBECONFIG=~/.kube/<cluster>.yaml NS=<namespace>
$ cd 01-kv-aware-epp-rollout-active-passive
$ ./rollout.sh deploy          # vLLM x4, 2 EPPs, Envoy; ~3 min with weights cached on the nodes
$ ./demo.sh                    # ~20 min: warm, roll with snapshots, roll without, restore
$ ./probe.sh stop && ./rollout.sh clean
```

The verdict is printed at the end and saved to `results/report.txt`. `HOLD=60 ./demo.sh` shortens
the traffic windows (default 120 s).

### Step by step

`demo.sh` is exactly this:

```console
$ ./probe.sh start                     # in-cluster probe: 16 chat sessions + 2 long streams -> kvap:80
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

- `./rollout.sh status`: the pods, the current leader, how many requests each EPP has routed
  (`llm_d_epp_request_total`; the standby's stays near 0), and Envoy's view of the EPP hosts
  (`health_flags=healthy` on the leader only).
- Who leads:
  ```console
  $ kubectl -n $NS get lease epp-$NS-kvap.llm-d.ai -o jsonpath='{.spec.holderIdentity}'
  ```
- During `roll`, the script logs every leader change, and records it in
  `results/leader-<scenario>.tsv`. `results/envoy-hosts-<scenario>.tsv` has Envoy's EPP hosts
  every 2 s, and `results/epp-<pod>.log` each EPP's log. Look for `Snapshot loaded` lines a
  fraction of a second after each pod starts, on standbys too.
- The standby logs `gRPC ext_proc check not serving ... isLeader: false` every 2 s. That is
  Envoy's health check being told no, as intended.
- A request by hand. The `x-upstream-host` response header is the vLLM pod that served it.
  ```console
  $ kubectl -n $NS port-forward svc/kvap 8000:80 &
  $ curl -si localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"deepseek-ai/DeepSeek-V2-Lite-Chat","messages":[{"role":"user","content":"The capital of France is"}],"max_tokens":8}' \
      | grep -i -e '^HTTP' -e x-upstream-host
  ```

## Results

One run on CoreWeave `kermit`, 2026-10-29: 2,710 requests through three EPP rollouts,
**0 failed** (including 35 long streams and 239 answer-checked canaries).

| 48 cold sessions, turn 2 after both EPPs were replaced | back on the pod holding turn 1 | prefix-cache hit |
|---|---|---|
| rolled **with** snapshots | **48/48 (100%)** | **48/48 (100%)** |
| rolled without snapshots (control) | 15/48 (31%) | 15/48 (31%) |
| chance, 4 pods | 25% | |

- Each roll had one leader handover. In two of the three, the lease went to a pod that had
  started a second earlier, and for ~8–11 s, until it was Ready, Envoy spread requests over the
  standbys. Nothing failed.
- Every EPP pod, standbys included, loaded all four snapshots within a second of starting.
  Conversations mid-flight during the roll noticed the difference: without snapshots, 16 of 306
  follow-up turns missed the cache; with snapshots, 0 of 299.

The handover timeline, per-phase tables and how each claim is checked are in
[RESULTS.md](RESULTS.md).

## Files

| | |
|---|---|
| `manifests/vllm.yaml` | 4 vLLM pods with KV events + snapshots, their Service (tokenization), the InferencePool |
| `manifests/vllm-kv-snapshots/` | the three files of vllm-project/vllm#57789, vendored |
| `manifests/epp.yaml` | the 2 EPPs with leader election, their rollout and drain settings, RBAC (incl. the Lease), Services |
| `manifests/config/epp.yaml` | EPP plugins: precise prefix-cache routing, snapshots |
| `manifests/proxy.yaml`, `manifests/config/envoy.yaml` | Envoy: ext_proc to the leader, panic routing during a handover, `x-upstream-host` |
| `rollout.sh` | `deploy` / `roll [snapshot\|nosnap]` / `status` / `hosts` / `clean` |
| `probe.sh`, `loadgen.py` | in-cluster traffic, phase marks, cold sessions, capture |
| `report.py` | per-phase and cold-session verdict, leader handovers, snapshot loads from the EPP logs |
| `demo.sh` | the steps, in order |
| `results/` | where a run's capture, logs and report land (not checked in) |
