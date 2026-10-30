# Reaching ShopVerse

Module 06's deliverable list includes "a documented how to reach it", because the answer involves
a private CA, a name that only resolves on one workstation, and an admin password that exists only
inside the cluster. None of that is guessable six weeks later.

## From the WSL workstation

```bash
make hosts                      # shopverse.platform.local -> 192.168.100.200
make onprem-ca                  # .cache/platform-ca.crt, which curl needs to trust the Gateway

curl -sS -o /dev/null -w '%{http_code}\n' --cacert .cache/platform-ca.crt \
  https://shopverse.platform.local
```

A `200` means nginx is serving the React bundle. That is less than it looks: it proves the route,
the Gateway, the certificate and the frontend pod, and nothing behind them.

**The request worth making is the API one**, because it traverses the whole stack:

```bash
curl -sS --cacert .cache/platform-ca.crt https://shopverse.platform.local/api/products | head -c 400
```

frontend nginx → `shopverse-api-gateway` → `product-service` → MongoDB. `SEED_DATA: "true"` is set
for product-service, so a working stack returns actual products rather than an empty list.

## From a browser on Windows

The name resolves in WSL, not in Windows, and the certificate is signed by a CA nothing trusts
yet. Both have to be dealt with, and they are separate problems:

1. **The name.** Add `192.168.100.200 shopverse.platform.local` to
   `C:\Windows\System32\drivers\etc\hosts` (as Administrator). Whether Windows can reach
   `192.168.100.*` at all depends on WSL's networking mode — NAT mode generally cannot without a
   static route; mirrored mode can. **This is untested** (ADR-0013 says so too).
2. **The certificate.** Import `.cache/platform-ca.crt` into the Windows trust store for
   Chrome and Edge. Firefox keeps its own store and needs it imported separately.

Clicking through the browser's warning instead also works, and proves the same things about the
application while proving nothing about the certificate. That is a fine way to test the app and a
misleading way to test the platform.

## The admin login

```bash
make shopverse-admin
```

Reads it back out of the `shopverse-credentials` Secret, which `make shopverse-secret` generated
in-cluster. It is not in Git and not in any file (ADR-0016). Module 07 replaces that Secret with
External Secrets, which the chart already supports.

## When it does not answer

**`404` from `https://shopverse.platform.local`.** Almost always that the HTTPRoute does not exist
yet rather than anything broken: the Gateway's listener is a wildcard (`*.platform.local`), so it
answers for any name under it and returns 404 when no route matches. Argo CD polls Git every 180
seconds, so for the first minutes after a push `make gitops-status` shows everything Synced and
Healthy at the PREVIOUS revision.

```bash
make gitops-refresh            # ask Argo CD to re-read Git now
kubectl -n shopverse-prod get httproute
kubectl -n shopverse-prod get httproute shopverse \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
```

`Accepted=True` and `ResolvedRefs=True` is what a working route reports. `Accepted=False` with
`NoMatchingParent` means the listener name or hostname does not line up; `ResolvedRefs=False`
means the backend Service or its port is wrong.

**Connection refused or a timeout rather than a 404.** Then the problem is below HTTP — the
address is not being announced. That is ADR-0013 territory:

```bash
kubectl get leases -n kube-system | grep l2announce
make smoke                      # step 7 tests LB-IPAM and L2 without the Gateway involved
```

**A `200` on `/` but nothing from `/api/products`.** The frontend is up and something behind it is
not. Work inwards:

```bash
kubectl -n shopverse-prod get pod
kubectl -n shopverse-prod logs deploy/shopverse-api-gateway --tail=50
kubectl -n shopverse-prod logs deploy/shopverse-product-service --tail=50
kubectl -n shopverse-prod exec deploy/shopverse-api-gateway -- \
  wget -qO- http://shopverse-product-service:8080/health || true
```

Every service in that chart listens on **8080**, hardcoded in its template rather than taken from
values. `port-forward svc/shopverse-frontend 8081:80` fails with "does not have a service port 80"
for that reason.

## A restart that looks like a fault

`shopverse-mongodb-0` showed `RESTARTS 1` with:

```
Last State:  Terminated
  Reason:    Unknown
  Exit Code: 255
  Finished:  2026-10-30T06:05:48Z
```

Not OOMKilled, and the workers were at 25% memory — no pressure. `Exit Code 255` with
`Reason: Unknown` is what a container looks like when it is *killed abruptly* rather than when it
crashes: the node went away underneath it.

The cause was mundane — the laptop was restarted. `uptime` on the workstation and on `k8s-w01`
both put the boot a few minutes before `06:05:48Z`.

**The detail worth keeping** is what the Node objects said about it:

```
NODE       READY_SINCE
k8s-cp01   2026-10-23T09:30:59Z
k8s-w01    2026-10-23T09:32:25Z
```

Unchanged — days earlier. The nodes **never went NotReady**, despite having rebooted. A libvirt VM
comes back in roughly 25 seconds, and `node-monitor-grace-period` is 40 seconds, so the control
plane never waited long enough to mark them down. The node-failure timeline in
`docs/runbooks/cluster-bootstrap.md` is why: lease expiry at 10s, grace period at 40s, taint, then
a 300s toleration before eviction. A reboot that finishes inside 40 seconds is invisible to it.

So after a host restart, expect container restart counts to go up with no corresponding node
event, and do not read a steady `READY_SINCE` as proof that a node has been up. The two facts are
not the same, and `kubectl get nodes` cannot tell them apart.

