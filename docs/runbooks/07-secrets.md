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
