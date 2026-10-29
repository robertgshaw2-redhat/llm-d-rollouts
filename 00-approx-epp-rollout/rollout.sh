#!/usr/bin/env bash
# Cluster side of the basic EPP rollout (approximate prefix-cache routing, one EPP).
#
#   ./rollout.sh deploy     vLLM x4, EPP x1, Envoy; waits until Ready
#   ./rollout.sh roll       roll the EPP (a restart: same config, new pod, empty index)
#   ./rollout.sh status     pods, EPP request counts, Envoy's view of the EPP hosts
#   ./rollout.sh hosts      Envoy's ext_proc hosts and their health, once
#   ./rollout.sh clean      delete everything this example created
#
# `roll` blocks until the old EPP pod has exited. While it runs it samples Envoy's ext_proc hosts
# every 2 s into results/envoy-hosts-<HHMMSS>.tsv.
#
# Defaults: KUBECONFIG=~/.kube/kermit.yaml, NS=robshaw-dev.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kermit.yaml}"
NS="${NS:-robshaw-dev}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${RESULTS:-$HERE/results}"
mkdir -p "$RESULTS"

k() { kubectl -n "$NS" "$@"; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

render() {
  kubectl kustomize "$HERE/manifests"
}

epp_pods() { k get pods -l app.kubernetes.io/name=apx-epp -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }

# Envoy admin is on localhost:19000 inside the proxy pod; the image has bash but no curl.
hosts() {
  k exec deploy/apx-proxy -- bash -c '
    exec 3<>/dev/tcp/127.0.0.1/19000
    printf "GET /clusters HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3
    cat <&3' | awk -F'::' '/^ext_proc::/ && ($3=="health_flags" || $3=="rq_total") {print $2, $3, $4}' |
    awk '{v[$1]=v[$1] " " $2 "=" $3} END {for (h in v) print h v[h]}' | sort
}

sample_hosts() {  # until the stop file appears
  local stop=$1 out=$2
  while [ ! -e "$stop" ]; do
    hosts 2>/dev/null | sed "s/^/$(date +%s.%N | cut -c1-14)\t/" >>"$out" || true
    sleep 2
  done
}

request_counts() {  # llm_d_epp_request_total per EPP pod, through the API server's pod proxy
  for p in $(epp_pods); do
    n=$(kubectl get --raw "/api/v1/namespaces/$NS/pods/$p:9090/proxy/metrics" 2>/dev/null |
        awk '/^llm_d_epp_request_total/ {s+=$NF} END {print s+0}')
    echo "$p requests=$n"
  done
}

case "${1:-}" in

deploy)
  if ! k get secret llm-d-hf-token >/dev/null 2>&1; then
    echo "missing secret $NS/llm-d-hf-token (key HF_TOKEN)" >&2; exit 1
  fi
  render | k apply -f -
  log "waiting for vLLM (first start on a node downloads ~31 GB of weights)"
  k rollout status deploy/apx-vllm --timeout=45m
  k rollout status deploy/apx-epp --timeout=10m
  k rollout status deploy/apx-proxy --timeout=5m
  log "deployed"
  "$0" status
  ;;

roll)
  old=$(epp_pods | tr '\n' ' ')
  stop="$RESULTS/.roll.stop"; rm -f "$stop"
  sample_hosts "$stop" "$RESULTS/envoy-hosts-$(date -u +%H%M%S).tsv" & sh=$!
  trap 'touch "$stop"; wait $sh 2>/dev/null || true' EXIT

  request_counts | sed 's/^/before: /'
  log "rolling the EPP; old pod: $old"
  k rollout restart deploy/apx-epp >/dev/null
  k rollout status deploy/apx-epp --timeout=20m
  for p in $old; do
    k wait --for=delete "pod/$p" --timeout=15m >/dev/null 2>&1 || true
    log "old pod $p exited"
  done
  request_counts | sed 's/^/after: /'
  log "rolled"
  ;;

status)
  k get pods -l app.kubernetes.io/part-of=apx -o wide
  echo
  request_counts
  echo
  hosts
  ;;

hosts)
  hosts
  ;;

clean)
  render | k delete -f - --ignore-not-found
  ;;

*)
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 1
  ;;
esac
