# ADR-0018: secrets management — Vault and External Secrets

**Status:** Accepted
**Date:** 2026-10-30
**Decides:** where secrets live, how they reach a pod, which secret cannot be eliminated, and who
owns Vault's own configuration. Retires the exception ADR-0016 opened.

## Context

ADR-0016 created a deliberate, time-boxed exception to ADR-0002 Rule 3: `make shopverse-secret`
generates six random values and applies them as a Kubernetes Secret by hand. Nothing is in Git,
which was the point, but the credential exists only because someone ran a command — it is not
reproducible, not rotatable, and not auditable.

The roadmap's bar for this module is specific: `git grep` finds no credential, a fresh clone plus
`make onprem-up` reproduces a working platform, and **rotating one secret takes one commit**.

## The constraint nobody escapes

Every option below ends with **exactly one secret that cannot be in Git** — the key that decrypts
or unlocks the others. Sealed Secrets has the controller's private key. SOPS has the age identity.
Vault has its unseal keys.

You do not eliminate that secret. You reduce N credentials to one, and then you decide what shape
that one takes and where it lives. Any design claiming otherwise has hidden it somewhere.

## Options

**Sealed Secrets.** A controller holds a private key; `kubeseal` encrypts with its public half and
the `SealedSecret` is committed. Simplest to install — one controller, no Argo CD plugin.

Rejected on one specific ground: **the keys are per-cluster.** The same committed ciphertext
cannot be decrypted on GKE or EKS, so secrets become the one thing that is not one definition
across three substrates, which is ADR-0001's whole premise. Losing the controller's key also loses
every secret, and backing it up is a manual step outside everything else here.

**SOPS with age.** Encrypted values committed to Git, decrypted at render time, multi-recipient so
one file serves several clusters. Genuinely strong, and the cheapest to run — no new component, no
memory, no unsealing.

Rejected narrowly: it needs a decryption plugin in Argo CD (KSOPS or a config management plugin),
which is a change to the Layer 2 install, and it teaches a pattern that is common in GitOps circles
but rarer in the places this project is preparing for.

**Vault with External Secrets Operator.** Chosen.

## Decision

### 1. Vault on-prem, External Secrets Operator everywhere

The deciding property is how cleanly it fits ADR-0001, and it is the sharpest example so far:

```
the ExternalSecret manifest is IDENTICAL on all three substrates
only the ClusterSecretStore changes, per environment:

  onprem  ->  Vault
  gke     ->  GCP Secret Manager
  eks     ->  AWS Secrets Manager
```

The portable half is the thing a tenant writes; the substrate-specific half is one object in the
overlay. That is exactly the seam the per-environment overlays exist for, and it is the same shape
as ADR-0017's finding about network policy — except there the boundary was a limitation, and here
it is the design working.

The ShopVerse chart also already supports it, with no change: `externalSecret.enabled`, a
`ClusterSecretStore` named `vault-backend`, and six properties read from one KV path.

### 2. Not dev mode. Standalone with file storage on a PVC

Vault's dev mode auto-unseals and keeps everything in memory, so it loses every secret on a pod
restart. On a cluster that restarts whenever the laptop does, that would teach the opposite of the
lesson: it would make secrets look free and durable when they are neither.

So: standalone, file storage, a `platform-local` PVC (ADR-0015). Which means the data is
node-local and a dead node takes Vault's storage with it — the same warning as MongoDB, and for
Vault it is worse, because losing it loses the ability to decrypt rather than just the data.

### 3. The unseal keys are THE irreducible secret, and they live outside everything

After `vault operator init`, five unseal keys and a root token exist exactly once. They go to
`.cache/vault-init.json`, which is gitignored, and **nowhere else** — not in the repo, not in a
Kubernetes Secret, not in Git history.

`make vault-unseal` reads that file and unseals. It must be run after every cluster restart,
and that friction is the honest cost of this choice rather than a defect to engineer away. In
production the answer is cloud KMS auto-unseal, which replaces "a human has the keys" with "a cloud
IAM role has them" — a different trust model, not an absent one.

**If `.cache/vault-init.json` is lost, every secret in Vault is unrecoverable.** That sentence is
the whole reason this ADR exists, and it is the property the other two options also have, just
spelled differently.

### 4. Vault's own configuration is a fifth kind of state

This repository has had four: Terraform owns Layer 0, Ansible owns Layer 1 and the Argo CD install
(Layer 2), Argo CD owns in-cluster objects (Layer 3). Vault's auth methods, policies and roles are
none of those — they are **state inside an application**, reachable only through its own API.

Argo CD cannot own it. A Kubernetes manifest cannot express it. So it gets an explicit owner rather
than a script nobody explains: **`make vault-bootstrap`, idempotent, and the one place in this
project where imperative configuration is the correct answer** rather than a shortcut.

Terraform's Vault provider is the "proper" alternative and was considered; it means a second
Terraform state for application-internal config, which is more machinery than one Kubernetes auth
role justifies. Recorded so the decision is visible when there are twenty roles instead of one.

### 5. Seed Vault with the EXISTING values, never fresh ones

The migration copies the six values out of the current `shopverse-credentials` Secret into Vault
unchanged.

`mongo-password` initialised MongoDB's root user on the volume's **first boot only**. Generating
new values during migration would leave every service authenticating against a database that still
expects the old password — a failure that presents as a healthy, running MongoDB refusing
connections, which `make shopverse-secret` already refuses to cause and this must not reintroduce.

### 6. Enabling it causes a rollout, and that is expected

`externalSecret.enabled` changes the chart's `secretName` helper output from
`shopverse-credentials` to `shopverse-secrets`, so every Deployment's `secretKeyRef` changes. A
changed pod template is a rollout — the same lesson as pinning an image tag, where identical bytes
still rolled every pod because the spec changed.

So the order is not negotiable: Vault populated → ESO and the `ClusterSecretStore` working → the
new Secret materialised → *then* flip the flag. Flipping first gives seven pods a `secretKeyRef` to
an object that does not exist.

### 7. etcd encryption at rest, included

A kubeadm `EncryptionConfiguration` plus `--encryption-provider-config` on the API server, then
`kubectl get secrets -A -o json | kubectl replace -f -` to rewrite existing secrets through the new
provider — because enabling encryption does **not** retroactively encrypt what is already in etcd,
and that is the step everyone skips.

**What it protects against:** someone who reads etcd's files on the control-plane node, or an etcd
backup that leaks.

**What it does not:** anyone with `get secret` RBAC, a compromised pod with a mounted Secret, or
root on a node — the API server decrypts for all of them. Encryption at rest is not access
control, and conflating the two is how it gets treated as a solved problem.

Verifiable by reading a key directly out of etcd and seeing ciphertext rather than plaintext, which
is the only way to know it is on.

## Consequences

- **Vault being down does not break running pods.** ESO syncs into an ordinary Kubernetes Secret,
  so the Secret persists independently. What stops is rotation and any *new* secret. That is a
  genuinely good failure mode and worth knowing before someone panics about Vault at 3am.
- Memory cost: Vault standalone plus ESO's three pods. The workers are at ~25%, so there is room,
  and `kubectl top nodes` is the check before and after.
- An unseal step after every cluster restart, which `make doctor` should notice and report rather
  than leaving someone to discover through a failing ExternalSecret.
- `make shopverse-secret` becomes a bootstrap-only tool, kept because it is how the values exist
  before Vault does, and because the fresh-clone path needs it.
- Nothing here is verified at the time of writing. This is a plan, in four stages, and at least one
  section above will turn out to be wrong.

---

## Verified, 2026-10-30 — stages 1 to 3

```
externalsecret shopverse-secrets   SecretSynced   True
secret/shopverse-credentials  Opaque  6  27h      (kept, for rollback)
secret/shopverse-secrets      Opaque  6  48m      (ESO, from Vault)

make shopverse-check  7/7
  5/7  order SV660435213332 placed, total 439
  6/7  delete shopverse-mongodb-0 -> back Ready, same PV pvc-3a7105d5…
  7/7  GET /api/orders/SV660435213332 -> 200
```

A real order was placed and survived the database restart, with every service authenticating
against MongoDB using a password that now comes out of Vault. **That is Decision 5 verified in
the only way that counts** — the root user on that volume was created from the pre-migration
value, and it still accepts the post-migration one, because `make vault-seed-shopverse` copied
the bytes and checked each one by hash rather than trusting that it had.

Three corrections and one non-finding.

### Decision 6 was right about the mechanism and wrong about the scope

It said the flip is a rollout, and it is. It implied a rollout of all seven services, and that is
wrong: **six of eight pods were replaced, and `shopverse-frontend` and `shopverse-api-gateway`
were not** — 6h9m old against 48m for everything else.

The reason is in the chart. The six `secretKeyRef` env vars are gated on `$svc.mongoDatabase`, so
only services with a database get them, so only those pod templates changed.

Which makes the set of pods that rolled exactly: the five services Hubble observed connecting to
MongoDB in ADR-0017, plus MongoDB itself. **Two independent questions — "who talks to the
database" and "whose pod template contains the credential" — landed on the same five services**,
because both are really the question "who holds database credentials". The network policy and the
blast radius of a secret change are the same boundary, arrived at from opposite directions.

The general form, worth carrying into the cloud modules: the blast radius of a secret change is
the set of pods that *read* it, which is narrower than the release and is discoverable from the
chart before the change rather than from pod ages afterwards.

### The ~9 second 502 window did not appear

Step 7 returned `200` on the first attempt. The 2026-10-29 run needed three retries at
three-second intervals, which ADR-0016 recorded as "~9 seconds".

So that number is **variable, not a property**. Same cluster, same deliberate deletion, same
check — three retries once and none the next time. ADR-0016's measurement stands as something
that happened; it does not stand as a constant, and the retry count in `make shopverse-check` is
the measurement rather than a threshold. Recorded here so nobody later treats 9 seconds as a
budget.

### The roadmap's rotation bar is not met, and the bar encoded an assumption

The bar: *"rotating one secret takes one commit."* With Vault and ESO it takes **zero** commits,
because the value is not in Git. The bar quietly assumed the secret lives in the repository —
which is exactly what SOPS or Sealed Secrets would have given, and is a real argument for them
that this ADR's options section did not make.

What rotation actually costs, now in `docs/runbooks/07-secrets.md` with commands: a Vault
`kv patch` (not `put` — `put` replaces the whole secret and would drop the other five keys), a
forced ESO refresh because `refreshInterval` is 1h, and **a rollout** — because all six values are
`secretKeyRef` env vars, which are resolved once at pod creation. ESO updating the Secret changes
nothing about a running pod. A mounted Secret volume would update in place; an env var never does.

And one of the six cannot be rotated at all: `mongo-password` initialised the root user on first
boot, so changing it means deleting the volume and every order with it. That is MongoDB's
behaviour, not a property of any secrets mechanism, and it is the kind of thing that should be
written down before an incident rather than discovered during one.

### `make secrets-audit` answers the other bar with evidence

The *"git grep finds no credential"* bar is a claim about this repository, so the repository now
answers it: `scripts/secrets-audit.sh` reads the live values out of the cluster and out of
`.cache/vault-init.json` and searches every commit on every ref for each one. Patterns go through
a mode-600 file rather than argv, and a finding reports the key name and `rev:path` — never the
value, because `git grep` without `--name-only` prints the matching line into a scrollback buffer.

Result: no credential in the working tree, none in 97 commits. Verified by planting a live value
in a commit and watching it fail.

It also caught a false positive in itself, which is the more useful part. The first version
reported *"a live credential is in this repository — treat it as disclosed"*, pointing at the
`Makefile` across 97 commits — for `admin@shopverse.local`, which `make shopverse-secret` sets as
a literal. An email address. **A check that cries leak over a username is one nobody reads after
the second time, which makes the next alert worse than useless.** `admin-email` and
`mongo-username` are now classified as identifiers: still searched for, still reported, reported
as what they are.

### Still not verified

- **Rotation.** The commands in the runbook are written and have never been run. The `force-sync`
  annotation in particular is the documented ESO pattern and is untested here.
- **Stage 4**, etcd encryption at rest, is outstanding.
- Vault's API is still plaintext HTTP, mitigated by a NetworkPolicy and nothing else; ESO still
  runs its own CA for its own webhook. Both in `docs/parking-lot.md`, both Module 08.
