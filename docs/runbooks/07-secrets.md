# Operating Vault and External Secrets

Module 07's deliverable, and the only part of this platform where a file on one laptop is the
difference between a recoverable cluster and a lost one. Read the first section before running
anything.

## The one thing that cannot be rebuilt

`.cache/vault-init.json` holds five unseal keys and a root token, written once by
`make vault-init`. It is gitignored, mode 600, and exists nowhere else — not in Git, not in a
Kubernetes Secret, not in any terminal history.

**If it is lost, every secret in Vault is unrecoverable.** Not inconvenient: the data is encrypted
with a key derived from those shares, and no amount of cluster rebuilding brings it back. The only
path afterwards is deleting Vault's volume and starting again.

So: copy it off this machine. A password-manager entry is enough.

This is not a flaw in Vault. ADR-0018 goes through the alternatives and every one of them ends
with exactly one irreducible secret — Sealed Secrets has the controller's private key, SOPS has
the age identity. You do not eliminate that secret; you reduce N credentials to one and then
decide what shape it takes. Vault's is just the first file in this repository where that is
visible.

## After every cluster restart

A sealed Vault is the normal state of a cluster that has been off. Nothing recovers it
automatically, because nothing is allowed to hold the keys.

```bash
make vault-status          # initialised? sealed? are the keys present?
make vault-unseal          # submits 3 of the 5 shares
```

Expect `progress=1`, `progress=2`, then `sealed=false`. Only three shares are ever submitted —
looping to the threshold rather than over every key means the other two are never transmitted,
which is the entire point of having a threshold.

Until it is unsealed, Argo CD shows the `vault` Application as Progressing or Degraded. That is
the honest state and is deliberately not annotated away.

**Running pods are unaffected by a sealed Vault.** ESO syncs into ordinary Kubernetes Secrets,
which persist on their own. What stops is rotation and any *new* secret — a genuinely good failure
mode, and worth knowing before someone panics about Vault at 3am.

## First-time setup, in order

The order is not optional. Each step's check depends on the one before it.

```bash
make vault-status                 # expect: not initialised
make vault-init                   # ONE TIME - read the output, back up the file
make vault-unseal

make vault-bootstrap              # KV v2, Kubernetes auth, the policy, the ESO role
make eso-check                    # a fresh value into Vault, out of a Secret
```

### What `make vault-bootstrap` does, and why it is a script

Vault's auth methods, policies and roles are **state inside an application**, reachable only
through that application's own API. Terraform owns Layer 0, Ansible owns Layer 1 and the Argo CD
install, Argo CD owns in-cluster objects — and none of them can own this. No Kubernetes manifest
expresses "KV v2 is mounted at `secret/`".

ADR-0018 Decision 4 calls that a fifth kind of state and gives it an explicit owner rather than a
script nobody explains. It is idempotent and prints `unchanged` when nothing moved, which is the
only thing that makes an imperative step acceptable here.

**It reads the arrangement out of the cluster rather than hardcoding it.** The
`ClusterSecretStore` named `vault-backend` — which Argo CD applies from Git — supplies the KV
mount, the auth mount path, the role name and the service account. Vault is then configured to
match. Change the role name in Git, re-run, and the two stay consistent; hardcode it here and it
drifts silently, with the symptom being a permission denial on an identity that looks correct in
both places.

It ends by **logging in as External Secrets** and doing two reads: one the policy permits and one
it must not. Everything before that is a request Vault recorded; the login is the only part that
shows the arrangement works, and the denied read is the only part that shows the policy is a
boundary rather than a decoration.

### What `make eso-check` proves that bootstrap does not

Bootstrap tests Vault's side. `eso-check` tests the operator: that it is running, that the store
resolves, that the NetworkPolicy lets it through, and that an ExternalSecret produces a Secret
with the right bytes.

It writes a **fresh random canary** to Vault on every run and asserts that exact value comes out.
Freshness is the design: a Secret left over from a previous run holds a different value and fails,
which is the difference between "a Secret exists" and "the path from Vault to that Secret works
right now". A check comparing against a fixed string would pass on a stale object.

## Diagnosing a secret that is not arriving

Work from the outside in. The three common causes produce the *same* symptom — a
`ClusterSecretStore` that never becomes Ready — and two of them are silent.

```bash
make vault-status                                   # sealed Vault refuses every request
kubectl get clustersecretstore vault-backend -o yaml | tail -20   # ESO's own verdict
kubectl -n external-secrets logs deploy/external-secrets --tail=40
make vault-bootstrap                                # re-runs clean; says what was missing
```

If the store is NotReady and the logs mention a connection rather than a permission:

```bash
# A NetworkPolicy drop produces NO error - a dropped packet has no RST, so the connection
# hangs until a timeout. Silence is the policy working, which is why it has to be looked at
# directly (ADR-0017 found the same thing for the tenant's database).
kubectl -n kube-system exec ds/cilium -- \
  hubble observe --to-namespace vault --verdict DROPPED --last 20
```

`make eso-check` compares the policy's allowed pod label against the controller pod's real labels
before it probes anything, precisely because a label typo and a broken Vault role are otherwise
indistinguishable.

## What is deliberately still wrong

Both are in `docs/parking-lot.md` with the full reasoning, and both are Module 08:

- **Vault's API is plaintext HTTP.** `tls_disable = 1` is in the chart's default standalone
  config, which this repository does not override because rewriting that stanza is how the
  `storage "file"` block gets lost — and losing it makes Vault silently in-memory. The
  NetworkPolicy restricts port 8200 to one pod. That reduces who can listen; it encrypts nothing.
- **Vault's egress is unrestricted.** Writable, unlike the tenant's edge case, and deferred rather
  than impossible. The rules must permit DNS *and* the API server, because Kubernetes auth works
  by Vault calling TokenReview.

## A failure that is not one

On a first run the order is necessarily: ESO starts, fails to log in because the Vault role does
not exist yet, and backs off. `make vault-bootstrap` then creates the role — and ESO does **not**
notice immediately. It retries on an exponential backoff (observed: 1s, 4s, 8s, 16s, 32s), so the
`ClusterSecretStore` keeps reporting `Ready=False: unable to create client` for up to a minute
after everything is correct.

`make eso-check` waits for that. If you are looking by hand instead:

```bash
# compare the TIMES, not the presence of errors
kubectl get clustersecretstore vault-backend -o jsonpath='{.status.conditions[0].lastTransitionTime}'
kubectl -n external-secrets logs deploy/external-secrets --tail=5 | jq -r '.ts'
```

An error older than the last `lastTransitionTime` is history, not evidence. Reading a controller's
log as a current-state report is how a fixed problem gets diagnosed for an hour — it happened here
on 2026-10-30 and is recorded in `docs/parking-lot.md`.

To reset the backoff rather than wait it out:

```bash
kubectl -n external-secrets rollout restart deploy/external-secrets
```

## Rotating a secret

The roadmap's bar for this module says *"rotating one secret takes one commit"*. That bar is not
met, and the reason is worth more than the bar: **with Vault and ESO, rotation is not a Git
operation at all.** The value is not in Git, so there is nothing to commit. It is a Vault write.

```bash
# rotate jwt-secret. Reads the root token from .cache/, nothing is echoed.
NEW=$(openssl rand -hex 24)
printf '%s\n{"jwt-secret":"%s"}\n' "$(jq -r .root_token .cache/vault-init.json)" "$NEW" \
  | kubectl -n vault exec -i vault-0 -- sh -c '
      ALL=$(cat); VAULT_TOKEN=$(printf %s "$ALL" | head -1); export VAULT_TOKEN
      printf %s "$ALL" | tail -n +2 | vault kv patch -mount=secret shopverse/prod -'
unset NEW
```

`kv patch`, not `kv put` — `put` replaces the whole secret, so it would drop the other five keys.

**Then two more steps, and the second one is the one people miss.**

ESO re-reads Vault on the ExternalSecret's `refreshInterval`, which is **1h** here. Until then the
Kubernetes Secret still holds the old value. To force it:

```bash
kubectl -n shopverse-prod annotate externalsecret shopverse-secrets \
  force-sync="$(date +%s)" --overwrite
kubectl -n shopverse-prod get secret shopverse-secrets -o jsonpath='{.data.jwt-secret}' | base64 -d | sha256sum
```

And then — **the Secret updating does not change a running pod.** The chart consumes all six
values as `secretKeyRef` environment variables (verified in `deployments.yaml` and
`mongodb.yaml` at the pinned commit), and env vars are resolved once, at pod creation. A mounted
Secret volume would update in place; an env var never does. So:

```bash
kubectl -n shopverse-prod rollout restart deploy -l app.kubernetes.io/instance=shopverse
```

So the honest cost of rotating one secret is: **one Vault write, one forced refresh, and one
rollout** — zero commits, and roughly the ~9s of 502s per service that ADR-0016 measured.

### `mongo-password` is the exception, and it is a big one

It cannot be rotated this way at all. MongoDB's root user was created from that value on the
volume's **first boot only**, so changing it in Vault gives every service a password the database
has never heard of — and MongoDB stays `Running` and `Ready` while refusing every connection.

Rotating it means rotating the database with it:

```bash
# destroys every order. Read this twice.
kubectl -n shopverse-prod delete statefulset shopverse-mongodb
kubectl -n shopverse-prod delete pvc -l app.kubernetes.io/component=mongodb
# write the new value to Vault, force the refresh, then let Argo CD recreate the StatefulSet
```

One of the six credentials is effectively immutable without data loss. That is a property of
MongoDB's initialisation, not of Vault or ESO, and no secrets mechanism would change it — which is
precisely why it is written down here rather than discovered during an incident.
