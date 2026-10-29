# llm-d rollouts

Four runnable examples of rolling out an llm-d stack under live traffic, without dropping
requests and without throwing away the KV cache the router has been steering traffic toward.

A KV-cache-aware router keeps state in two places: the **model servers** hold the KV blocks, and
the **router** knows which server holds which prefix. A naive rollout of either one throws that
state away, and every in-flight conversation pays to recompute its prefix. Each example shows
the fix for one case, measures it against a control, and can be run end to end with one script.

**New to llm-d's router, P/D or DisaggregatedSet? Start with [docs/concepts.md](docs/concepts.md).**

## The examples

| | what rolls | what keeps the cache | needs |
|---|---|---|---|
| [**01** KV-aware EPP rollout, active-passive](01-kv-aware-epp-rollout-active-passive/) | the **router**: a leader EPP and a hot standby (leader election) behind Envoy, one pod at a time | each new EPP loads every vLLM pod's **KV-cache snapshot** as a standby, so whichever pod takes over knows the old prefixes | vllm-project/vllm#57789 (vendored); llm-d-router v1.0.0 |
| [**02** KV-aware EPP rollout, active-active](02-kv-aware-epp-rollout-active-active/) | the **router**: two EPPs both routing, sharing load through Redis | the same snapshots; no leader handover at all | the same |
| [**03** P/D manual canary](03-pd-manual-canary-prefix-affinity/) | the **model servers**: a P/D stack, two DisaggregatedSets, scaled by hand (canary 1P1D, then shift) | the **rollout screener** keeps each prefill/decode pair in one revision, and **prefix affinity** keeps each session on one revision, moving at most once, old to new | llm-d/llm-d-router#3456 (image provided) |
| [**04** P/D rolling update](04-pd-rolling-update-prefix-affinity/) | the **model servers**: a P/D stack, one DisaggregatedSet, rolled by its controller after one `kubectl apply` | the same screener and prefix affinity, following the controller's steps | llm-d/llm-d-router#3456 (image provided) |

Each example directory has the same layout and is independent of the others:

```
NN-example/
  README.md      design -> how to run it -> short results
  RESULTS.md     full numbers from the reference run, and how each claim is checked
  manifests/     everything that gets applied (kustomize)
  rollout.sh     deploy / do the rollout steps / status / clean
  probe.sh       in-cluster traffic generator (loadgen.py): start, mark <phase>, tail, flush, stop
  report.py      the verdict from the captured traffic
  demo.sh        the whole thing, in order
```

Suggested reading order: [concepts](docs/concepts.md) →
[01](01-kv-aware-epp-rollout-active-passive/) (router state, the standard leader + standby setup) →
[02](02-kv-aware-epp-rollout-active-active/) (the same with both routers active) →
[03](03-pd-manual-canary-prefix-affinity/) (model-server state, step by step) →
[04](04-pd-rolling-update-prefix-affinity/) (the same, automated).

## Quick start

```console
$ export KUBECONFIG=~/.kube/<cluster>.yaml NS=<namespace>

$ cd 01-kv-aware-epp-rollout-active-passive
$ ./rollout.sh deploy && ./demo.sh            # ~25 min, 4 GPUs
$ ./probe.sh stop && ./rollout.sh clean

$ cd ../02-kv-aware-epp-rollout-active-active
$ ./rollout.sh deploy && ./demo.sh            # ~25 min, 4 GPUs
$ ./probe.sh stop && ./rollout.sh clean

$ cd ../03-pd-manual-canary-prefix-affinity
$ ./demo.sh                                   # ~25 min + model load, 6 GPUs with RDMA
$ ./probe.sh stop && ./rollout.sh clean

$ cd ../04-pd-rolling-update-prefix-affinity
$ ./demo.sh                                   # ~15 min + model load, 6 GPUs with RDMA
$ ./probe.sh stop && ./rollout.sh clean
```

Each `demo.sh` prints a verdict at the end and saves it to `results/report.txt`.

## Results at a glance

Reference runs on CoreWeave `kermit` (H200), 2026-10-29, `deepseek-ai/DeepSeek-V2-Lite-Chat`.
Every run had **0 failed requests**, including long streams and answer-checked canaries through
every drain.

| example | measure | with the feature | control |
|---|---|---|---|
| 01 | idle sessions routed back to the pod holding their cache after both EPPs were replaced | **48/48 (100%)** with snapshots | 15/48 (31%) without (chance: 25%) |
| 02 | the same, active-active | **48/48 (100%)** with snapshots | 8/48 (17%) without (chance: 25%) |
| 03 | follow-up turns that switched version during the canary | **0.3%**, never back to v0 | 42.7%, 15 sessions bounced back |
| 04 | follow-up turns that switched version during the rolling update | **0.8%**, never back to v0 | 14.3%, 17 sessions bounced back |

## Prerequisites

- `kubectl` (with kustomize), `jq` and `python3` on your machine.
- On the cluster:
  - the Gateway API Inference Extension CRDs (InferencePool);
  - for 03 and 04, LWS v0.10+ with the DisaggregatedSet CRD;
  - a `llm-d-hf-token` secret (key `HF_TOKEN`) in the namespace;
  - GPUs: 4 for examples 01 and 02; 6 with RDMA (`rdma/ib`) for examples 03 and 04 at their peak.

### Running on your own cluster

The manifests were written for CoreWeave. Check these before running elsewhere:

| setting | where | change it to |
|---|---|---|
| `KUBECONFIG`, `NS` | every script; defaults `~/.kube/kermit.yaml`, `robshaw-dev` | your cluster and namespace (just export them) |
| `hostPath: /mnt/local/hf-cache`, `/mnt/local/jit-cache` | vLLM pods in all four | node-local disk on your nodes, or a PVC / `emptyDir` (slower cold start) |
| toleration `is_gpu` | vLLM pods in all four | your GPU nodes' taints |
| `rdma/ib: 1`, `NCCL_IB_HCA=ibp` | P/D pods in 03, 04 | your RDMA device plugin's resource name and HCA prefix (NIXL needs RDMA between prefill and decode) |

## Unreleased pieces

| piece | used by | how this repo gets it |
|---|---|---|
| vLLM KV-event snapshots, [vllm-project/vllm#57789](https://github.com/vllm-project/vllm/pull/57789) (branch `vMaroon/vllm` `codex/kv-event-snapshots`, `4319361e`) | 01, 02 | The PR changes three Python files. Examples 01 and 02 run the public nightly the PR is based on and copy the PR's three files over it at start, from a ConfigMap ([details](01-kv-aware-epp-rollout-active-passive/#vllm-with-the-snapshot-pr)). |
| Prefix-keyed revision affinity, [llm-d/llm-d-router#3456](https://github.com/llm-d/llm-d-router/pull/3456) | 03, 04 | A public EPP image, `ghcr.io/robertgshaw2-redhat/llm-d-router-endpoint-picker:cb-v1.0.0-68c5e10`: llm-d-router v1.0.0 plus the backports of [project-cb-lab/llm-d-router#4](https://github.com/project-cb-lab/llm-d-router/pull/4) at `68c5e10c`, which carry #3456. Built as below. |

```console
$ git -C llm-d-router checkout 68c5e10c
$ podman build --platform linux/amd64 -f Dockerfile.epp \
    --build-arg COMMIT_SHA=68c5e10c053 --build-arg BUILD_REF=cb-v1.0.0-pr3494-pr3650 \
    -t ghcr.io/robertgshaw2-redhat/llm-d-router-endpoint-picker:cb-v1.0.0-68c5e10 llm-d-router
$ podman push ghcr.io/robertgshaw2-redhat/llm-d-router-endpoint-picker:cb-v1.0.0-68c5e10
```

Once #3456 is in an llm-d-router release, swap the EPP image in `0[34]-*/manifests/router/router.yaml`
for the release. Nothing else changes.

Everything else is public and pinned by digest: `vllm/vllm-openai` nightlies,
`ghcr.io/llm-d/llm-d-router-endpoint-picker:v1.0.0` (examples 01 and 02; snapshot loading,
leader election with a populated standby and `redis-syncer` are all in v1.0.0), `ghcr.io/llm-d/llm-d-router-disagg-sidecar:v1.0.0`, Envoy
v1.38.4, Redis 7.4.6.

## Further reading

- [disagg-set-rollout-poc](https://github.com/robertgshaw2-redhat/disagg-set-rollout-poc): the
  manual P/D rollout that examples 03 and 04 extend (cross-revision pairing checked from the
  sidecar logs, no affinity).
- llm-d `guides/rollouts/`, and the `disaggregatedset-rollout-screener` README in llm-d-router
  (`pkg/epp/framework/plugins/requestcontrol/screener/disaggregatedsetrollout/`).
- The DisaggregatedSet rollout KEP: `kubernetes-sigs/lws` `keps/766-DisaggregatedSet`.
