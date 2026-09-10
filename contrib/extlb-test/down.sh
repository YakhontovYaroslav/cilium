#!/usr/bin/env bash
set -uo pipefail
CLUSTER=${CLUSTER:-extlb}
docker rm -f katran frr >/dev/null 2>&1
kind delete cluster --name "$CLUSTER"
