#!/usr/bin/env bash
# The whole example in one go, with traffic throughout (~20 min after the deploy):
#
#   1. warm      hot sessions on the deployed stack
#   2. snapshot  seed 48 cold sessions, roll both EPP pods, probe the cold sessions
#   3. nosnap    the control: the same, rolling to an EPP config without snapshotSocketPort
#   4. restore   roll back to the committed config (snapshots on)
#
# Then the verdict (report.py), saved to results/report.txt. HOLD (default 120) is the traffic
# window between steps. Assumes ./rollout.sh deploy has run.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
HOLD=${HOLD:-120}
COLD=${COLD:-48}

./probe.sh start
./probe.sh mark 1-warm
sleep "$HOLD"

./probe.sh cold-seed "$COLD" snapshot
./probe.sh mark 2-rolling-snapshot
./rollout.sh roll snapshot
./probe.sh mark 2-after-snapshot
./probe.sh cold-probe "$COLD" snapshot
sleep "$HOLD"

./probe.sh cold-seed "$COLD" nosnap
./probe.sh mark 3-rolling-nosnap
./rollout.sh roll nosnap
./probe.sh mark 3-after-nosnap
./probe.sh cold-probe "$COLD" nosnap
sleep "$HOLD"

./probe.sh mark 4-rolling-restore
./rollout.sh roll snapshot
./probe.sh mark 4-after-restore
sleep 60

./probe.sh flush
./report.py --out results/report.txt
