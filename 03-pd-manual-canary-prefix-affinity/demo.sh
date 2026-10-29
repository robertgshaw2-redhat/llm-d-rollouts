#!/usr/bin/env bash
# The whole example in one go, with traffic throughout (~25 min, plus model loading):
#
#   1 deploy router (affinity prefix) + v0 2P2D      4 traffic on both; control router alongside
#   2 traffic on v0                                  5 v0 -> 1P1D, draining
#   3 admit v1 1P1D                                  6 v1 -> 2P2D
#                                                    7 retire v0, draining
#
# Then the verdict (report.py), saved to results/report.txt. HOLD (default 150) is the traffic
# window between steps; set CONTROL=0 to skip the control router.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
HOLD=${HOLD:-150}

./rollout.sh deploy
./rollout.sh watch start
./probe.sh start

./probe.sh mark 2-v0-2p2d
sleep "$HOLD"

./probe.sh mark 3-v1-loading
./rollout.sh canary
./probe.sh mark 4-v0-2p2d+v1-1p1d
if [ "${CONTROL:-1}" = 1 ]; then
  # Same pods, a second router with affinity none, its own sessions.
  ./rollout.sh control start
  POD=pdcanary-control-probe URL=http://pdcanary-control:80 WORKERS=8 RESULTS="$PWD/results/control" ./probe.sh start
fi
sleep "$HOLD"
if [ "${CONTROL:-1}" = 1 ]; then
  POD=pdcanary-control-probe RESULTS="$PWD/results/control" ./probe.sh stop
  ./rollout.sh control stop
fi
./rollout.sh status

./probe.sh mark 5-v0-draining-to-1
./rollout.sh scale v0 1
./probe.sh mark 5-v0-1p1d+v1-1p1d
sleep "$HOLD"

./probe.sh mark 6-v1-scaling-to-2
./rollout.sh scale v1 2
./probe.sh mark 6-v0-1p1d+v1-2p2d
sleep "$HOLD"

./probe.sh mark 7-v0-draining-to-0
./rollout.sh retire v0
./probe.sh mark 7-v1-2p2d-only
sleep "$HOLD"

./probe.sh flush
./rollout.sh watch stop
./report.py --out results/report.txt
