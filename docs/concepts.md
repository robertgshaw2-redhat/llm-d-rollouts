# Background: why rollouts are hard for a KV-cache-aware router

This page covers the pieces the five examples are built from. Read it first if llm-d's router,
P/D disaggregation or DisaggregatedSet are new to you. Each example's README assumes this
material and only covers what is specific to that example.

- [How llm-d routes a request](#how-llm-d-routes-a-request)
- [Prefix-cache routing: the state that makes a rollout expensive](#prefix-cache-routing-the-state-that-makes-a-rollout-expensive)
- [Problem 1: rolling the router loses its index](#problem-1-rolling-the-router-loses-its-index)
- [Running more than one EPP: active-passive or active-active](#running-more-than-one-epp-active-passive-or-active-active)
- [P/D disaggregation](#pd-disaggregation)
- [Problem 2: rolling the model servers splits sessions across versions](#problem-2-rolling-the-model-servers-splits-sessions-across-versions)
- [The rollout screener](#the-rollout-screener)
- [Prefix affinity across revisions](#prefix-affinity-across-revisions)
- [Draining without dropping requests](#draining-without-dropping-requests)
- [How the examples measure all this](#how-the-examples-measure-all-this)

## How llm-d routes a request

```
 client
   |
   v
 Envoy  --- ext_proc (gRPC) --->  EPP (endpoint picker)
   |        "which pod?"            - watches the InferencePool's pods
   |   <--- "this one" -----------  - runs a plugin pipeline per request
   |        (x-gateway-destination-endpoint)
   v
 vLLM pod chosen by the EPP
```

- **Envoy** is the data plane. For every request it asks the EPP, over Envoy's external
  processing (ext_proc) gRPC API, where to send it, then proxies the request there.
- The **EPP** (endpoint picker, from `llm-d-router`) is the brain. It watches the pods selected
  by an **InferencePool** (a Gateway API Inference Extension CRD: a label selector plus a port
  plus "this EPP picks for me") and runs each request through a configurable **plugin
  pipeline**:
  - *producers* attach data to the request or to endpoints (tokens, prefix-match info, load),
  - *filters* drop candidate pods,
  - *scorers* score the survivors, with weights,
  - a *picker* chooses the winner.

  Plugin chains are grouped into **scheduling profiles**. An aggregated deployment has one
  profile; P/D has a `prefill` and a `decode` profile.
- The EPP reports its health over gRPC (port 9003). Envoy health-checks it and only sends
  ext_proc streams to healthy EPPs. That is what makes the EPP itself rollable: a draining EPP
  reports `NOT_SERVING`, and Envoy stops using it.

Every example here puts Envoy, the EPP config and the InferencePool in its own `manifests/`, so
you can read the whole path in one place.

## Prefix-cache routing: the state that makes a rollout expensive

vLLM caches the KV tensors of every prompt prefix it has computed, in fixed-size blocks
(64 tokens in examples 01 and 02). A follow-up turn of a chat conversation repeats the whole conversation
so far. If it lands on the pod that served the previous turn, the prefix is a cache hit and only
the new tokens are computed. If it lands anywhere else, the whole conversation is recomputed,
which for a long conversation is most of the cost of the turn.

So the router tries to send each request to the pod that already holds its prefix. llm-d has two
ways of knowing where prefixes live:

| | how it knows | used in |
|---|---|---|
| **approximate** (`approx-prefix-cache-producer` + `prefix-cache-scorer`) | it remembers which pod it sent each prefix to | examples 00, 03, 04 |
| **precise** (`precise-prefix-cache-producer`) | every vLLM pod publishes **KV events** (block stored / block evicted) over ZMQ, and the EPP builds an index of exactly which blocks each pod holds. It tokenizes each request the same way vLLM does (`token-producer` → vLLM's `/v1/chat/completions/render`) so the block hashes match. | examples 01, 02 |

Either way, the cache is **state**, and it lives in two places:

1. in the **model servers** (the KV blocks themselves), and
2. in the **router** (its knowledge of which server holds what).

A rollout replaces one of them. Done naively, either kind of rollout throws that state away and
every in-flight conversation pays to recompute. Examples 00, 01 and 02 roll the router; 03 and
04 roll the model servers.

## Problem 1: rolling the router loses its index

With approximate routing the index is built from the EPP's own routing decisions, so a new EPP
pod starts empty and has nothing to rebuild it from: every existing conversation is a miss until
its next turn teaches the new pod where it went. [Example 00](../00-approx-epp-rollout/) measures
this in the default setup and lists the limitations.

With precise routing, the EPP's index is built from the live KV-event stream. A new EPP pod
subscribes when it starts, so it only hears about blocks stored **after** it started. Every
prefix cached before that (an idle conversation waiting for its user's next message, a shared
system prompt) is invisible to it, and gets routed by load to a pod that has to recompute it.

The fix in [examples 01](../01-kv-aware-epp-rollout-active-passive/) and [02](../02-kv-aware-epp-rollout-active-active/) is **KV-event snapshots**
(vllm-project/vllm#57789 + llm-d/llm-d-router#2946):

```
 vLLM pod                                      new EPP pod
   ZMQ ROUTER :6557  <-- "snapshot please" --- on discovering the pod
                     --- every block held,  -> load into the index
                         + the sequence no.
   ZMQ PUB    :5557  --- live events ------->  follow the stream from that sequence no.
                                                (no gap, no duplicate)
```

The new EPP loads each pod's current state before it reports Ready, so from its first request it
knows everything the old EPPs knew.

## Running more than one EPP: active-passive or active-active

One EPP replica is a single point of failure, and rolling it means a moment with no router. Both
EPP examples run two replicas, in the two ways llm-d supports:

**Active-passive** ([example 01](../01-kv-aware-epp-rollout-active-passive/)):
`--ha-enable-leader-election`. The replicas compete for a Kubernetes Lease. Both sync the pool,
follow the KV events and keep the same index (a *hot standby*), but only the leader passes the
ext_proc health check, so Envoy sends every request to it. Queueing and in-flight load live in
one process. When the leader shuts down it releases the lease, a standby takes it within a retry
period (2 s), and Envoy moves to it at its next health check. For the second or two in between,
Envoy has no healthy EPP and, with `healthy_panic_threshold: 1`, spreads requests over all of
them; the standbys route those too.

**Active-active** ([example 02](../02-kv-aware-epp-rollout-active-active/)): no leader election.
Both replicas pass the health check and Envoy round-robins between them. Each builds the same
index from the same events. The one thing they would disagree on is load (each sees only its
own in-flight requests), so they share per-pod in-flight counts through Redis (`redis-syncer`).
A rollout never hands over: a new pod joins the rotation, then an old one leaves it.

Either way, snapshots are what make the new pod warm. The comparison table is in
[example 02's README](../02-kv-aware-epp-rollout-active-active/#01-or-02).

## P/D disaggregation

Prefill (compute-bound: process the prompt) and decode (memory-bandwidth-bound: generate tokens)
run on separate pods:

```
 Envoy -> EPP: runs the prefill profile AND the decode profile, picks one pod of each
   |
   v
 decode pod :8000 = llm-d routing sidecar
   1. sends the prompt to the chosen prefill pod (vLLM computes the KV, generates nothing)
   2. hands the request to its local vLLM :8200, which pulls the KV from the prefill pod over
      NIXL (RDMA) and decodes
```

The prefill and the decode pod must agree on model weights, KV layout, NIXL version and so on.
**A v0 prefill paired with a v1 decode is a correctness bug, not a performance one.** It can fail
outright, or return HTTP 200 with garbage if the KV is reinterpreted under a different layout.

A **DisaggregatedSet** (from LWS, `disaggregatedset.x-k8s.io/v1`) manages the prefill and decode
roles of one P/D stack as one object. Every pod carries a `disaggregatedset.x-k8s.io/revision`
label, a hash of the set's pod templates. Change any template and you get a new revision. Its
controller can roll both roles together (`rolloutStrategy: RollingUpdate`, with surge and
unavailability limits per role, interleaving the two roles' steps), or you can run one object
per version and scale them by hand.

## Problem 2: rolling the model servers splits sessions across versions

During a P/D rollout both versions serve at once. The router must:

1. **never pair across revisions** (correctness),
2. **split traffic in proportion to capacity** (each version gets the share its pods can serve),
3. **keep each conversation on one revision** (cache), and
4. **move a conversation at most once**, from old to new, as the old version shrinks.

The rollout screener does 1 and 2. Prefix affinity (llm-d/llm-d-router#3456) adds 3 and 4.

## The rollout screener

`disaggregatedset-rollout-screener` is an EPP plugin that runs once per request, before both
scheduling profiles:

```yaml
- type: disaggregatedset-rollout-screener
  parameters:
    scope:
      labelSelector: "llm-d.ai/guide=pdcanary"   # which pods form the fleet
    revisionGating:
      mode: max-role                             # how shares are computed
      requiredRoles: [prefill, decode]           # a revision is only offered once it has both
      disableCoordination: true                  # single EPP; nothing to coordinate
      affinity:
        mode: prefix                             # llm-d/llm-d-router#3456; default: random
```

Per request it:

1. groups the Ready pods in scope by `disaggregatedset.x-k8s.io/revision`;
2. drops any revision missing a required role. A new revision with only its decode pod Ready
   gets no traffic, so nothing needs to gate traffic while new pods load;
3. gives each remaining revision a **share**. With `max-role`, the share is the revision's
   fraction of Ready pods of the globally most numerous role. 2P2D next to 1P1D is 67% / 33%;
4. **draws** a number in [0, 1), maps it onto the shares, and picks that revision;
5. hides every other revision's pods from both profiles, so prefill and decode are picked from
   the same revision.

The EPP exports the current shares as `llm_d_epp_disaggregatedset_revision_gating_share`, and
each response carries the revision that served it in `x-llm-d-disagg-revision`.

## Prefix affinity across revisions

Without affinity, step 4's draw is `rand.Float64()`, independently for every request. At
67/33, a 20-turn conversation lands on the other revision for about a third of its turns, and
each switch recomputes the whole conversation on pods that have never seen it. Worse, sessions
bounce back and forth for the whole rollout, so both revisions carry everyone's working set.

With `affinity.mode: prefix` the draw is a hash (xxhash) of the conversation **up to and
including its first user message** (plus `cache_salt` if present). Every turn of a chat repeats
that prefix, so every turn draws the same number:

```
 draw = hash(system prompt + first user message)  ->  a fixed point in [0, 1) per session

 shares 67/33   [============ v0 ============|====== v1 ======]
 shares 50/50   [======== v0 ========|========== v1 ==========]
                                     ^^^^^^^^
                     only the sessions whose point is in here move, v0 -> v1, once
 shares 33/67   [==== v0 ====|============== v1 ==============]
 shares  0/100  [============================ v1 =============]
```

The revisions are laid out in a fixed order, so when the shares change only the boundary moves.
Sessions on the far side of the moved boundary switch to the revision that gained share, and
every other session keeps its revision and its cache. While the old version only shrinks, no
session ever moves back. Over many sessions the split still matches the shares.

Two limits to know:

- It works for chat completions and Anthropic messages, which have a "first user message".
  `/v1/completions` and Responses requests keep the random draw.
- The split is per session, not per request, so with few, unequal sessions it is lumpy. In
  example 03, 50/50 capacity served 40/60.

## Draining without dropping requests

Every pod that a rollout removes is doing work. The examples use the same chain to finish it.

**Model-server pods** (examples 03, 04):

| setting | why |
|---|---|
| deleted pod leaves the InferencePool at once | the EPP stops picking it for new requests |
| `preStop: sleep 20` | vLLM stays fully up while the EPP's view converges, and while decodes that already chose this prefill pull their KV from it |
| `vllm serve --shutdown-timeout 90` | on SIGTERM vLLM stops accepting new work but finishes in-flight requests |
| routing sidecar as a native sidecar (`initContainers` + `restartPolicy: Always`) | it outlives vLLM on shutdown, so draining requests keep their proxy |
| `terminationGracePeriodSeconds: 150` | more than preStop + shutdown timeout |
| `kv_load_failure_policy: fail` | a KV transfer lost to a drain fails the request loudly instead of silently recomputing, so the test can see it |

**EPP pods** (examples 01, 02): `maxSurge: 1, maxUnavailable: 0, minReadySeconds: 30`. On SIGTERM
the EPP reports `NOT_SERVING` (and, as leader, releases the lease), and Envoy marks it unhealthy
within two health checks (4 s) and sends it no new streams. Streams it already holds run to the end of their response, and
`terminationGracePeriodSeconds: 600` covers the longest.

## How the examples measure all this

All five are judged on traffic, not on object status. An in-cluster probe pod (`loadgen.py`)
runs through every step:

- **multi-turn chat sessions** (16 workers × 20 turns, a unique ~1500-word first message each so
  each session has its own cache and affinity key), recording which pod and revision served each
  turn and how many prompt tokens were cached;
- **long streams** (thousands of tokens), so every drain lands on a pod mid-generation;
- **canaries**: 1 request in 10 is a fixed greedy "The capital of France is" whose answer is
  checked. A corrupted KV transfer returns 200 with garbage, and only an answer check catches it.

`probe.sh mark <phase>` labels the timeline between steps, and `report.py` prints per-phase
failures, latency and prefix-cache hit rates. For the P/D examples it also prints, per session,
which version served each turn.

Each example also runs a **control**. Example 00 probes cold sessions with and without a
rollout in between. Examples 01 and 02 roll the EPP again without snapshots. Examples 03 and 04
run a second router with `affinity.mode: none` over the same pods, with its own sessions. The
difference between the two is the effect of the feature, measured on the same hardware at the
same time.
