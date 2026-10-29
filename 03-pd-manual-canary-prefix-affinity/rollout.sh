#!/usr/bin/env bash
# Manual, step-by-step canary rollout of a P/D stack held in two DisaggregatedSets, with the
# router keeping each session on one revision (prefix affinity).
#
#   ./rollout.sh deploy              router (affinity prefix) + v0 (2 prefill, 2 decode); wait Ready
#   ./rollout.sh canary              admit v1 (1 prefill, 1 decode); wait Ready
#   ./rollout.sh scale <v0|v1> <n>   set BOTH roles of one version to n replicas; waits for new
#                                    pods Ready / old pods drained
#   ./rollout.sh retire <v0|v1>      scale to 0, wait for the drain, delete the object
#   ./rollout.sh watch start|stop    every 10 s, record each vLLM pod's prefix-cache counters and
#                                    the screener's shares into results/ (pods that go take
#                                    their counters with them)
#   ./rollout.sh control start|stop  a second router over the same pods, affinity none
#   ./rollout.sh status              pods by revision, prefix-cache hit rates, screener shares
#   ./rollout.sh clean               remove everything
#
# The sequence is: deploy, canary, scale v0 1, scale v1 2, retire v0 -- with ./probe.sh running
# throughout and ./probe.sh mark <label> between steps. demo.sh runs exactly that.
#
# Defaults: KUBECONFIG=~/.kube/kermit.yaml, NS=robshaw-dev.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kermit.yaml}"
NS="${NS:-robshaw-dev}"
GUIDE="llm-d.ai/guide=pdcanary"
DS_NAME=disaggregatedset.x-k8s.io/name
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${RESULTS:-$HERE/results}"
mkdir -p "$RESULTS"

k()   { kubectl -n "$NS" "$@"; }
say() { printf '%s ==> %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
now() { date +%s; }

# The router objects, named $1, with screener affinity $2.
router() {
  kubectl kustomize "$HERE/manifests/router" | sed -e "s/__ROUTER__/$1/g" -e "s/__AFFINITY__/$2/g"
}

# "<total> <ready> <terminating>" for one version's pods.
counts() {
  k get pods -l "$DS_NAME=pdcanary-$1" -o json | jq -r '
    [.items[]] | [length,
      (map(select(.metadata.deletionTimestamp == null
                  and any(.status.conditions[]?; .type == "Ready" and .status == "True"))) | length),
      (map(select(.metadata.deletionTimestamp != null)) | length)] | @tsv'
}

# Block until the version has exactly 2n pods, all Ready, none terminating.
settle() {
  local v=$1 want=$(( $2 * 2 )) t0 total ready term
  t0=$(now)
  while :; do
    read -r total ready term < <(counts "$v")
    if (( total == want && ready == want && term == 0 )); then break; fi
    printf '    %s: %s pods, %s ready, %s draining (want %s ready)  [%ss]\n' \
      "pdcanary-$v" "$total" "$ready" "$term" "$want" "$(( $(now) - t0 ))"
    sleep 10
  done
  say "pdcanary-$v settled at $2 prefill + $2 decode after $(( $(now) - t0 ))s"
}

# One line per running vLLM pod: ts pod role version revision prefix-cache queries hits (tokens,
# since pod start). Read through the API server's pod proxy; decode vLLM listens on 8200.
scrape() {
  local ts; ts=$(date +%s)
  k get pods -l "$GUIDE" --field-selector=status.phase=Running -o json | jq -r '
    .items[] | select(.metadata.deletionTimestamp == null) |
    [.metadata.name, .metadata.labels["llm-d.ai/role"], .metadata.labels["rollout.example/version"],
     .metadata.labels["disaggregatedset.x-k8s.io/revision"]] | @tsv' |
  while IFS=$'\t' read -r pod role ver rev; do
    port=8000; [[ $role == decode ]] && port=8200
    kubectl get --raw "/api/v1/namespaces/$NS/pods/$pod:$port/proxy/metrics" 2>/dev/null |
      awk -v ts="$ts" -v pod="$pod" -v role="$role" -v ver="$ver" -v rev="$rev" '
        /^vllm:prefix_cache_queries_total/ {q+=$NF}
        /^vllm:prefix_cache_hits_total/    {h+=$NF}
        END {if (q != "") printf "%s\t%s\t%s\t%s\t%s\t%d\t%d\n", ts, pod, role, ver, rev, q, h}'
  done
}

# Block until router $1's Envoy has a healthy EPP host. Until then it fails every request (500):
# the EPP pod can be Ready a few seconds before Envoy has resolved and health-checked it.
wait_envoy() {
  local t0; t0=$(now)
  until k exec "deploy/$1-proxy" -- bash -c '
      exec 3<>/dev/tcp/127.0.0.1/19000
      printf "GET /clusters HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3
      cat <&3' 2>/dev/null | grep -q '^ext_proc::.*::health_flags::healthy'; do
    (( $(now) - t0 < 120 )) || { echo "$1: Envoy has no healthy EPP after 120s" >&2; exit 1; }
    sleep 2
  done
}

shares() {  # the screener's current share per revision, from the EPP's gauge
  local pod
  pod=$(k get pods -l app.kubernetes.io/name=pdcanary-router-epp -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || return 0
  [ -n "$pod" ] || return 0
  kubectl get --raw "/api/v1/namespaces/$NS/pods/$pod:9090/proxy/metrics" 2>/dev/null |
    awk '/^llm_d_epp_disaggregatedset_revision_gating_share/ {match($0, /revision="[^"]*"/); print substr($0, RSTART+10, RLENGTH-11) "=" $NF}' |
    paste -sd' ' -
}

case "${1:-}" in

deploy)
  k get secret llm-d-hf-token >/dev/null || { echo "missing secret $NS/llm-d-hf-token (key HF_TOKEN)" >&2; exit 1; }
  say "router (affinity prefix)"
  k apply -f "$HERE/manifests/router/pool.yaml" >/dev/null
  router pdcanary-router prefix | k apply -f - >/dev/null
  k rollout status deploy/pdcanary-router-epp --timeout=300s
  k rollout status deploy/pdcanary-router-proxy --timeout=300s
  wait_envoy pdcanary-router
  say "v0: 2 prefill + 2 decode"
  k apply -k "$HERE/manifests/v0"
  settle v0 2
  ;;

canary)
  say "admitting v1: 1 prefill + 1 decode, alongside v0"
  k apply -k "$HERE/manifests/v1"
  # No traffic gate is needed while it loads: the screener only offers a revision once it has a
  # Ready pod of EVERY required role.
  settle v1 1
  ;;

scale)
  v=${2:?usage: rollout.sh scale <v0|v1> <n>}; n=${3:?usage: rollout.sh scale <v0|v1> <n>}
  scrape >>"$RESULTS/prefix-cache.tsv"  # the pods about to go take their counters with them
  say "pdcanary-$v -> $n prefill + $n decode"
  k patch disaggregatedset "pdcanary-$v" --type=json -p "[
    {\"op\":\"test\",\"path\":\"/spec/roles/0/name\",\"value\":\"prefill\"},
    {\"op\":\"test\",\"path\":\"/spec/roles/1/name\",\"value\":\"decode\"},
    {\"op\":\"replace\",\"path\":\"/spec/roles/0/spec/replicas\",\"value\":$n},
    {\"op\":\"replace\",\"path\":\"/spec/roles/1/spec/replicas\",\"value\":$n}]"
  sleep 3
  settle "$v" "$n"
  ;;

retire)
  v=${2:?usage: rollout.sh retire <v0|v1>}
  "$0" scale "$v" 0
  say "pdcanary-$v is empty -- deleting the object"
  k delete disaggregatedset "pdcanary-$v"
  ;;

watch)
  pidf="$RESULTS/.watch.pid"
  case "${2:-}" in
    start)
      [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null || true
      ( while :; do
          scrape >>"$RESULTS/prefix-cache.tsv" || true
          printf '%s\t%s\n' "$(date +%s)" "$(shares)" >>"$RESULTS/shares.tsv" || true
          sleep 10
        done ) >/dev/null 2>&1 &
      echo $! >"$pidf"
      say "watching (pid $(cat "$pidf")): results/prefix-cache.tsv, results/shares.tsv"
      ;;
    stop)
      [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null || true
      rm -f "$pidf"
      ;;
    *) echo "usage: rollout.sh watch start|stop" >&2; exit 1 ;;
  esac
  ;;

control)
  case "${2:-}" in
    start)
      say "control router pdcanary-control (affinity none) over the same pods"
      router pdcanary-control none | k apply -f - >/dev/null
      k rollout status deploy/pdcanary-control-epp --timeout=300s
      k rollout status deploy/pdcanary-control-proxy --timeout=300s
  wait_envoy pdcanary-control
      ;;
    stop)
      router pdcanary-control none | k delete -f - --ignore-not-found >/dev/null
      ;;
    *) echo "usage: rollout.sh control start|stop" >&2; exit 1 ;;
  esac
  ;;

status)
  say "pods"
  k get pods -l "$GUIDE" -o json | jq -r '
    .items | sort_by(.metadata.labels["rollout.example/version"], .metadata.labels["llm-d.ai/role"], .metadata.name)[] |
    [.metadata.labels["rollout.example/version"],
     .metadata.labels["disaggregatedset.x-k8s.io/revision"],
     .metadata.labels["llm-d.ai/role"],
     .metadata.name,
     (if .metadata.deletionTimestamp then "Draining"
      elif any(.status.conditions[]?; .type == "Ready" and .status == "True") then "Ready"
      else "NotReady" end),
     .spec.nodeName] | @tsv' | column -t
  echo
  say "prefix-cache hit rate per pod, since pod start (tokens)"
  scrape | awk -F'\t' '{printf "    %-4s %-8s %-40s %5.1f%% of %d\n", $4, $3, $2, ($6 ? 100*$7/$6 : 0), $6}'
  echo
  say "screener share per revision: $(shares)"
  ;;

clean)
  "$0" watch stop || true
  k delete disaggregatedset pdcanary-v0 pdcanary-v1 --ignore-not-found
  router pdcanary-control none | k delete -f - --ignore-not-found >/dev/null
  router pdcanary-router prefix | k delete -f - --ignore-not-found >/dev/null
  k delete -f "$HERE/manifests/router/pool.yaml" --ignore-not-found >/dev/null
  ;;

*)
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 1
  ;;
esac
