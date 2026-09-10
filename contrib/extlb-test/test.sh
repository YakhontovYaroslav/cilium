#!/usr/bin/env bash
# Assertions for the external L4LB rig. Run after up.sh.
set -uo pipefail
cd "$(dirname "$0")"

CLUSTER=${CLUSTER:-extlb}
K="kubectl --context kind-$CLUSTER"
VIP=10.99.100.2
KATRAN_IP=172.20.9.11
REAL=$($K get svc web-real -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
curl_vip() { docker exec katran curl -s -m "${1:-5}" "http://$VIP/" 2>/dev/null; }

echo "== real=$REAL vip=$VIP"
echo
echo "-- 1. BGP: the real is announced by exactly the backend-holding nodes (eTP=Local)"
paths=$(docker exec frr vtysh -c "show ip bgp $REAL/32 json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("paths",[])))' 2>/dev/null)
nodes=$($K get pods -l app=web -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
[ "${paths:-0}" = "$nodes" ] && ok "frr holds $paths path(s) for $REAL, backends on $nodes node(s)" \
                            || bad "frr holds ${paths:-0} path(s) for $REAL, backends on $nodes node(s)"

echo
echo "-- 2. Katran -> real (IPIP) -> VIP:80 is served by the pod on 8080"
body=$(curl_vip)
echo "$body" | grep -q '^Hostname:' && ok "HTTP served, port 80 translated to 8080 (forced-backend path cannot do that)" \
                                    || bad "no response through the tunnel: '$(echo "$body" | head -1)'"

echo
echo "-- 3. DSR: the backend saw the real client address"
cip=$(echo "$body" | grep -i '^RemoteAddr' | tr -d '\r')
echo "$cip" | grep -q "$KATRAN_IP" && ok "$cip" || bad "client IP not preserved: '${cip:-<none>}'"

echo
echo "-- 4. a node IP is NOT a delivery target (pre-existing forced-backend path)"
node_ip=$($K get nodes -o jsonpath='{.items[?(@.metadata.labels.node-role\.kubernetes\.io/control-plane=="")].status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')
docker exec katran sh -c "ip tunnel add kN mode ipip remote $node_ip local $KATRAN_IP 2>/dev/null; ip link set kN up; ip route replace $VIP/32 dev kN" >/dev/null 2>&1
code=$(docker exec katran curl -s -m 4 -o /dev/null -w '%{http_code}' "http://$VIP/" 2>/dev/null)
[ "$code" = "200" ] && bad "served via node IP real ($code): frontend gate fired on a host endpoint" \
                    || ok "not served via node IP real (curl: '$code'), as before this feature"
docker exec katran ip route replace $VIP/32 dev kV >/dev/null 2>&1

echo
echo "-- 5. eTP=Cluster: the forwarding hop (Geneve dispatch) translates the port too"
$K patch svc web-vip  -p '{"spec":{"externalTrafficPolicy":"Cluster"}}' >/dev/null
$K patch svc web-real -p '{"spec":{"externalTrafficPolicy":"Cluster"}}' >/dev/null
sleep 5
hosts=$(for i in $(seq 1 20); do curl_vip 4 | grep -i '^Hostname' | tr -d '\r'; done)
n_ok=$(echo "$hosts" | grep -c '^Hostname')
n_pods=$(echo "$hosts" | sort -u | grep -c '^Hostname')
[ "$n_ok" -eq 20 ] && ok "20/20 served under eTP=Cluster" || bad "only $n_ok/20 served under eTP=Cluster"
[ "$n_pods" -ge 2 ] && ok "$n_pods distinct pods answered, so the remote hop was exercised" \
                    || bad "only $n_pods pod answered; remote hop not exercised, result above proves little"
$K patch svc web-vip  -p '{"spec":{"externalTrafficPolicy":"Local"}}' >/dev/null
$K patch svc web-real -p '{"spec":{"externalTrafficPolicy":"Local"}}' >/dev/null

echo
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
