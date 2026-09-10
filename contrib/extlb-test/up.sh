#!/usr/bin/env bash
# Bring up the external L4LB rig: kind + Cilium (this branch) + FRR + Katran box.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=${CLUSTER:-extlb}
IMAGE=${IMAGE:-quay.io/local/cilium-dev:extlb}
NET=kind
FRR_IP=172.20.9.1
KATRAN_IP=172.20.9.11
REALS=10.99.99.0/24
K="kubectl --context kind-$CLUSTER"

echo "== kind cluster $CLUSTER"
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --config kind.yaml --name "$CLUSTER"
kind load docker-image "$IMAGE" --name "$CLUSTER"
$K label nodes --all bgp=enabled --overwrite >/dev/null

CP_IP=$(docker inspect "$CLUSTER-control-plane" -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}')

echo "== cilium ($IMAGE)"
helm upgrade --install cilium ../../install/kubernetes/cilium \
  --kube-context "kind-$CLUSTER" --namespace kube-system \
  --values values.yaml \
  --set image.override="$IMAGE" --set image.pullPolicy=Never \
  --set k8sServiceHost="$CP_IP" --set k8sServicePort=6443 >/dev/null
$K -n kube-system rollout status ds/cilium --timeout=300s

echo "== frr (the fabric) at $FRR_IP"
docker rm -f frr >/dev/null 2>&1 || true
docker run -d --name frr --network "$NET" --ip "$FRR_IP" --privileged \
  frrouting/frr:v8.4.0 sleep infinity >/dev/null
docker exec frr sh -c '
  sysctl -qw net.ipv4.ip_forward=1
  touch /etc/frr/vtysh.conf
  sed -i -e "s/bgpd=no/bgpd=yes/" /etc/frr/daemons
  /usr/lib/frr/frrinit.sh start >/dev/null
  vtysh -c "conf t" \
    -c "router bgp 65000" \
    -c "  bgp router-id 172.20.9.1" \
    -c "  no bgp ebgp-requires-policy" \
    -c "  bgp bestpath as-path multipath-relax" \
    -c "  neighbor CILIUM peer-group" \
    -c "  neighbor CILIUM remote-as external" \
    -c "  bgp listen range 172.20.0.0/16 peer-group CILIUM" \
    -c "  address-family ipv4 unicast" \
    -c "    neighbor CILIUM activate" \
    -c "    maximum-paths 8" \
    -c "  exit-address-family"'

echo "== workload + bgp"
$K apply -f bgp.yaml >/dev/null
$K apply -f workload.yaml >/dev/null
$K rollout status deploy/web --timeout=180s >/dev/null
for i in $(seq 1 60); do
  REAL=$($K get svc web-real -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -n "$REAL" ] && break; sleep 2
done
[ -n "$REAL" ] || { echo "no LB IP allocated for web-real"; exit 1; }
echo "   real = $REAL"

echo "== katran box at $KATRAN_IP"
docker rm -f katran >/dev/null 2>&1 || true
docker run -d --name katran --network "$NET" --ip "$KATRAN_IP" --privileged \
  nicolaka/netshoot:latest sleep infinity >/dev/null
docker exec katran sh -c "
  sysctl -qw net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0
  ip route add $REALS via $FRR_IP
  ip tunnel add kV mode ipip remote $REAL local $KATRAN_IP
  ip link set kV up
  ip route add 10.99.100.2/32 dev kV"

echo "== waiting for BGP to converge"
for i in $(seq 1 30); do
  docker exec frr vtysh -c "show ip route $REAL/32" 2>/dev/null | grep -q "via" && break; sleep 2
done
docker exec frr vtysh -c "show ip bgp summary" | tail -6
echo "== up. Next: contrib/extlb-test/test.sh"
