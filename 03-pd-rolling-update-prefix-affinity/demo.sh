#!/usr/bin/env bash
# The whole example in one go, with traffic throughout (~15 min, plus model loading):
#
#   1 deploy router (affinity prefix) + pdroll at v0 (2P2D); control router alongside
#   2 traffic on v0, through both routers
#   3 update to v1: the controller rolls both roles, one surge group at a time
#   4 traffic on v1
#
# Then the verdict (report.py), saved to results/report.txt. HOLD (default 150) is the traffic
# window before and after the roll; set CONTROL=0 to skip the control router.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
HOLD=${HOLD:-150}

./rollout.sh deploy
./rollout.sh watch start
./probe.sh start
if [ "${CONTROL:-1}" = 1 ]; then
  # Same pods, a second router with affinity none, its own sessions, through the whole roll.
  ./rollout.sh control start
  POD=pdroll-control-probe URL=http://pdroll-control:80 WORKERS=8 RESULTS="$PWD/results/control" ./probe.sh start
fi

./probe.sh mark 2-v0
sleep "$HOLD"

./probe.sh mark 3-rolling-to-v1
./rollout.sh update v1
./probe.sh mark 4-v1
sleep "$HOLD"

if [ "${CONTROL:-1}" = 1 ]; then
  POD=pdroll-control-probe RESULTS="$PWD/results/control" ./probe.sh stop
  ./rollout.sh control stop
fi
./probe.sh flush
./rollout.sh watch stop
./report.py --out results/report.txt
