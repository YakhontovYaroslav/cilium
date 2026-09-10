# External L4LB IPIP termination: local BGP test rig

Brings up a kind cluster with Cilium from this branch, an FRR router acting as
the fabric, and a "Katran" box that IPIP-encapsulates client traffic to a
*real* that the cluster announces via BGP. Everything lives on the kind docker
network, no containerlab needed.

```
                   BGP (eBGP, dynamic neighbors)
  extlb-* nodes  <------------------------------>  frr  172.20.9.1
       ^                                           ^
       | IPIP: outer dst = REAL (LB IPAM, BGP)     | route 10.99.99.0/24 via frr
       |        inner dst = VIP  (externalIP)      |
       +-------------------------------------- katran  172.20.9.11
```

- `web-vip`   : Katran's VIP `10.99.100.2` as an `externalIPs` entry. Never announced.
- `web-real`  : `type: LoadBalancer` from pool `10.99.99.0/24`, announced by BGP,
                `externalTrafficPolicy: Local` so only backend-holding nodes announce it.
- backend     : `traefik/whoami` listening on **8080** while the service port is **80**,
                so a 200 is by itself proof that the port was translated.

## Run

```sh
# 1. build the agent image from this branch (once)
make dev-docker-image DOCKER_DEV_ACCOUNT=quay.io/local DOCKER_IMAGE_TAG=extlb

# 2. bring everything up
contrib/extlb-test/up.sh

# 3. assertions
contrib/extlb-test/test.sh

# 4. tear down
contrib/extlb-test/down.sh
```

`up.sh` honours `IMAGE` (default `quay.io/local/cilium-dev:extlb`) and `CLUSTER`
(default `extlb`).

## What test.sh asserts

1. FRR learned the real from exactly the nodes that host a backend (eTP=Local).
2. Katran -> REAL (IPIP) -> VIP:80 returns 200 from the pod on 8080, i.e. the
   outer header was stripped, no backend was forced, the port was translated.
3. The backend saw the real client address (DSR, client IP preserved).
4. A node IP as the real is *not* a delivery target: the pre-existing
   forced-backend path applies and the request is not served.
5. Under eTP=Cluster with Geneve dispatch, 20 requests all succeed and more
   than one pod answers, i.e. the forwarding hop translates the port too.

Not asserted, by design: source gating. Any host that can route to the real
gets the same treatment; the real is a public frontend already.
