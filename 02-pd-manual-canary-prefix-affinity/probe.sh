#!/usr/bin/env bash
# In-cluster traffic, so the rollout is judged on requests rather than on what the objects say.
#
#   ./probe.sh start              launch the probe pod (loadgen.py run: sessions, long streams, canaries)
#   ./probe.sh mark <label>       stamp a phase boundary (on the pod's clock)
#   ./probe.sh tail               follow the 10 s summaries
#   ./probe.sh flush              copy the capture into results/
#   ./probe.sh stop               flush, then delete the probe pod
#
# Tunables (env, read at start): WORKERS=16 TURNS=20 PREFIX_WORDS=1500 MAX_TOKENS=64 THINK=5 LONG=2
# LONG_TOKENS=12000. POD, URL and RESULTS can be overridden to run a second, independent probe.
# Defaults: KUBECONFIG=~/.kube/kermit.yaml, NS=robshaw-dev.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kermit.yaml}"
NS="${NS:-robshaw-dev}"
POD="${POD:-pdcanary-probe}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${RESULTS:-$HERE/results}"
mkdir -p "$RESULTS"

k() { kubectl -n "$NS" "$@"; }

case "${1:-}" in

start)
  k delete pod "$POD" --ignore-not-found --wait=true >/dev/null
  k create configmap "$POD" --from-file=loadgen.py="$HERE/loadgen.py" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  cat <<YAML | k apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  labels: {app.kubernetes.io/name: $POD, app.kubernetes.io/part-of: pdcanary}
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: docker.io/library/python@sha256:2d44738ebf4ce5f63b9d9ea871e9c7cfdc0426f7b0c97cac915fd88ded1d86bb # 3.13-slim
      command: [python3, -u, /app/loadgen.py, run]
      env:
        - {name: URL, value: "${URL:-http://pdcanary-router:80}"}
        - {name: WORKERS, value: "${WORKERS:-16}"}
        - {name: TURNS, value: "${TURNS:-20}"}
        - {name: PREFIX_WORDS, value: "${PREFIX_WORDS:-1500}"}
        - {name: MAX_TOKENS, value: "${MAX_TOKENS:-64}"}
        - {name: THINK, value: "${THINK:-5}"}
        - {name: LONG, value: "${LONG:-2}"}
        - {name: LONG_TOKENS, value: "${LONG_TOKENS:-12000}"}
      resources:
        requests: {cpu: "1", memory: 512Mi}
        limits: {cpu: "4", memory: 1Gi}
      volumeMounts:
        - {name: app, mountPath: /app}
        - {name: results, mountPath: /results}
  volumes:
    - name: app
      configMap: {name: $POD}
    - name: results
      emptyDir: {}
YAML
  k wait --for=condition=Ready "pod/$POD" --timeout=180s >/dev/null
  rm -f "$RESULTS"/requests.jsonl "$RESULTS"/timeline.tsv
  "$0" mark probe-start
  ;;

mark)
  label=${2:?usage: probe.sh mark <label>}
  # Stamped inside the pod: same clock as the request log.
  k exec "$POD" -- python3 -c "
import time
line = f'{time.time():.3f}\t$label\n'
open('/results/timeline.tsv', 'a').write(line)
print(line, end='')"
  ;;

flush)
  # The capture lives in the pod's emptyDir: nothing rotates away, but it dies with the pod.
  for f in $(k exec "$POD" -- sh -c 'cd /results && ls'); do
    k exec "$POD" -- cat "/results/$f" > "$RESULTS/$f.tmp" && mv "$RESULTS/$f.tmp" "$RESULTS/$f"
  done
  echo "$(wc -l < "$RESULTS/requests.jsonl" | tr -d ' ') requests captured"
  ;;

tail)
  k logs -f "$POD" --tail=5
  ;;

stop)
  "$0" flush || true
  k delete pod "$POD" --ignore-not-found >/dev/null
  k delete configmap "$POD" --ignore-not-found >/dev/null
  echo "probe stopped"
  ;;

*)
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 1
  ;;
esac
