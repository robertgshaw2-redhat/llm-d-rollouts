#!/usr/bin/env bash
# The whole example in one go, with traffic throughout (~12 min after the deploy):
#
#   1. warm      hot sessions on the deployed stack
#   2. baseline  seed 48 cold sessions, wait as long as a rollout takes, probe them: what the
#                approximate index does when nothing restarts
#   3. rollout   seed 48 more, roll the EPP, probe them: what it does across a restart
#
# Then the verdict (report.py), saved to results/report.txt. HOLD (default 120) is the traffic
# window between steps; WAIT (default 75, about one rollout) is the baseline's idle time.
# Assumes ./rollout.sh deploy has run.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
HOLD=${HOLD:-120}
WAIT=${WAIT:-75}
COLD=${COLD:-48}

./probe.sh start
./probe.sh mark 1-warm
sleep "$HOLD"

./probe.sh cold-seed "$COLD" baseline
./probe.sh mark 2-baseline
sleep "$WAIT"
./probe.sh cold-probe "$COLD" baseline

./probe.sh cold-seed "$COLD" rollout
./probe.sh mark 3-rolling
./rollout.sh roll
./probe.sh mark 3-after
./probe.sh cold-probe "$COLD" rollout
sleep "$HOLD"

./probe.sh flush
./report.py --out results/report.txt
