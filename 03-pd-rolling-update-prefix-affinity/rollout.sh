#!/usr/bin/env bash
# Rolling update of a P/D stack held in one DisaggregatedSet, driven by the controller, with the
# router keeping each session on one revision (prefix affinity).
#
#   ./rollout.sh deploy              router (affinity prefix) + pdroll at v0 (2 prefill, 2 decode)
#   ./rollout.sh update <v0|v1>      apply that version's template; the controller rolls it out.
#                                    Blocks until every pod runs it and the old ones have drained,
#                                    printing each step of the roll.
#   ./rollout.sh watch start|stop    every 10 s, record each vLLM pod's prefix-cache counters and
#                                    the screener's shares into results/ (pods that go take
#                                    their counters with them)
#   ./rollout.sh control start|stop  a second router over the same pods, affinity none
#   ./rollout.sh status              pods by revision, prefix-cache hit rates, screener shares
#   ./rollout.sh clean               remove everything
#
# The sequence is: deploy, update v1 -- with ./probe.sh running throughout. demo.sh runs it, with
# the control router and its own probe running alongside.
#
# Defaults: KUBECONFIG=~/.kube/kermit.yaml, NS=robshaw-dev.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kermit.yaml}"
NS="${NS:-robshaw-dev}"
SET=pdroll
SEL="disaggregatedset.x-k8s.io/name=$SET"
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

# The fleet in one line: Ready (and draining) pods per version and role, e.g.
# "v0 prefill 2 decode 1(+1 draining) | v1 prefill 0 decode 1 (+1 starting)".
fleet() {
  k get pods -l "$SEL" -o json | jq -r '
    def ready: any(.status.conditions[]?; .type == "Ready" and .status == "True");
    [.items[] | {v: .metadata.labels["rollout.example/version"], r: .metadata.labels["llm-d.ai/role"],
                 s: (if .metadata.deletionTimestamp then "draining" elif ready then "ready" else "starting" end)}]
    | group_by(.v) | map(
        (.[0].v) + " " + (group_by(.r) | map(
          (.[0].r) + " " + ([.[] | select(.s == "ready")] | length | tostring)
          + (([.[] | select(.s == "draining")] | length) as $d | if $d > 0 then "(+\($d) draining)" else "" end)
          + (([.[] | select(.s == "starting")] | length) as $s | if $s > 0 then "(+\($s) starting)" else "" end)
        ) | join(" "))) | join(" | ")'
}

# Block until every pod of the set runs version $1: 2 prefill + 2 decode, all Ready, none
# draining. Prints the fleet whenever it changes.
settle() {
  local v=$1 t0 last="" cur done
  t0=$(now)
  while :; do
    cur=$(fleet)
    if [ "$cur" != "$last" ]; then
      printf '    [%4ss] %s\n' "$(( $(now) - t0 ))" "$cur"
      last=$cur
    fi
    done=$(k get pods -l "$SEL" -o json | jq --arg v "$v" '
      def ready: any(.status.conditions[]?; .type == "Ready" and .status == "True");
      [.items[]] | (length == 4) and all(.[]; .metadata.labels["rollout.example/version"] == $v
                                              and .metadata.deletionTimestamp == null and ready)')
    [ "$done" = true ] && break
    sleep 5
  done
  say "$SET settled at $v (2 prefill + 2 decode) after $(( $(now) - t0 ))s"
}

# One line per running vLLM pod: ts pod role version revision prefix-cache queries hits (tokens,
# since pod start). Read through the API server's pod proxy; decode vLLM listens on 8200.
scrape() {
  local ts; ts=$(date +%s)
  k get pods -l "$SEL" --field-selector=status.phase=Running -o json | jq -r '
    .items[] | [.metadata.name, .metadata.labels["llm-d.ai/role"], .metadata.labels["rollout.example/version"],
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
  pod=$(k get pods -l app.kubernetes.io/name=pdroll-router-epp -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || return 0
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
  router pdroll-router prefix | k apply -f - >/dev/null
  k rollout status deploy/pdroll-router-epp --timeout=300s
  k rollout status deploy/pdroll-router-proxy --timeout=300s
  wait_envoy pdroll-router
  say "$SET at v0: 2 prefill + 2 decode"
  k apply -k "$HERE/manifests/v0"
  settle v0
  ;;

update)
  v=${2:?usage: rollout.sh update <v0|v1>}
  say "$SET -> $v: the controller rolls both roles, surging one group at a time"
  k apply -k "$HERE/manifests/$v"
  settle "$v"
  ;;

watch)
  pidf="$RESULTS/.watch.pid"
  case "${2:-}" in
    start)
      [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null || true
      # Every 5 s rather than 10: the controller removes old pods on its own schedule, and a
      # pod's counters are lost with it.
      ( while :; do
          scrape >>"$RESULTS/prefix-cache.tsv" || true
          printf '%s\t%s\n' "$(date +%s)" "$(shares)" >>"$RESULTS/shares.tsv" || true
          sleep 5
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
      say "control router pdroll-control (affinity none) over the same pods"
      router pdroll-control none | k apply -f - >/dev/null
      k rollout status deploy/pdroll-control-epp --timeout=300s
      k rollout status deploy/pdroll-control-proxy --timeout=300s
  wait_envoy pdroll-control
      ;;
    stop)
      router pdroll-control none | k delete -f - --ignore-not-found >/dev/null
      ;;
    *) echo "usage: rollout.sh control start|stop" >&2; exit 1 ;;
  esac
  ;;

status)
  say "pods"
  k get pods -l "$SEL" -o json | jq -r '
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
  k delete disaggregatedset "$SET" --ignore-not-found
  router pdroll-control none | k delete -f - --ignore-not-found >/dev/null
  router pdroll-router prefix | k delete -f - --ignore-not-found >/dev/null
  k delete -f "$HERE/manifests/router/pool.yaml" --ignore-not-found >/dev/null
  ;;

*)
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 1
  ;;
esac
