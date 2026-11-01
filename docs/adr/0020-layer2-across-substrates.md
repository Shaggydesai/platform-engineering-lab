# ADR-0020: one Argo CD role for every substrate

**Status:** Accepted
**Date:** 2026-11-01
**Decides:** how Layer 2 — installing Argo CD and handing it the seam — is defined now that there
is more than one cluster. Applies ADR-0001's premise to Layer 2 itself rather than only to Layer
3, and records what is deliberately absent from the GCP platform set.

## Context

ADR-0001 claims one platform runs on three substrates. ADR-0002 divides that platform into three
layers: Layer 0 the infrastructure, Layer 1 Kubernetes itself, Layer 2 Argo CD, Layer 3 everything
Argo CD manages. The claim has only ever been tested at Layer 3, where it was designed to be
tested — `gitops/charts/` holds the definitions and `gitops/environments/<substrate>/` holds the
differences.

Module 08 brought up a GKE cluster (ADR-0019) and then asked a question the layer model does not
answer: **which layer does the Argo CD installation belong to on a managed substrate, and is it
the same installation?**

The honest starting position was that it probably could not be. The `argocd` role lives in an
Ansible repository whose other seven roles are all about machines — asserting a Packer image,
running `kubeadm init`, writing static pod manifests, joining kubelets. GKE has none of those
things, and no host to log into: Google's control plane never appears in `kubectl get nodes`, and
the worker nodes are managed instances that this repository must not touch, because anything done
to them by hand is lost at the next auto-repair.

Three options were on the table:

1. **Reuse the `argocd` role** against the `gcp-platform` context, with a GCP inventory holding
   one local host.
2. **Terraform's helm provider**, installing Argo CD as part of `make gcp-up`.
3. **A shell script** per substrate.

## Decision

### 1. Reuse the role. One definition of "how Argo CD is installed", for all three substrates

`make gcp-argocd` runs `ansible/roles/argocd` — the same files, the same tasks, the same values
file — against the `gcp-platform` context. `ansible/playbooks/gcp.yml` is the playbook;
`ansible/inventory/gcp.py` is the inventory, and it has one host, which is this workstation.

**Why it works at all, which was luck rather than foresight.** Every task in that role already
had `delegate_to: localhost` and already shelled out to `helm` and `kubectl` rather than doing
anything over SSH. That was not a portability decision — ADR-0009 required the role to be
re-runnable *when Argo CD is the broken thing*, so it had to depend on as little as possible,
including the cluster it was repairing. A role that cannot rely on the cluster working turns out
to be a role that does not need a host inside it. The property chosen for recovery is exactly the
one portability needed.

That is worth naming as a pattern rather than a happy accident: **a component built to work when
its surroundings are broken is usually also a component that can be moved.** The same reasoning
says ADR-0009's refusal to let Argo CD manage its own installation is what makes Layer 2
portable — a self-managing Argo CD would have been bootstrapped differently on every substrate.

**Why not the helm provider (option 2).** It is fewer moving parts and it is wrong for one
specific reason: it would put Layer 2 inside the Terraform state that owns Layer 0. `make
gcp-down` destroys that state, so tearing down a cluster at the end of a session would also
destroy the definition of how Argo CD was installed on it — and `terraform apply` would then be
the recovery path for a broken Argo CD, which means reading Layer 0's plan output to find out why
Layer 2 did not come up. ADR-0002's layers exist to keep those failures apart. It also means the
on-prem and cloud installs are described in two different languages, which is the thing this ADR
is trying not to do.

**Why not a script (option 3).** The role already contains eight assertions and four idempotency
checks earned over Modules 04 to 07 — the resource-tracking-method annotation, the values-drift
check, the server-side diff, the saved seam diff, the app-version read-back. A second
implementation starts with none of them, and nothing would keep the two in step.

### 2. Three things had to become variables, and the third one is a correctness fix

The role was *nearly* substrate-neutral; it named three things.

| was | is now | on-prem | GCP |
|---|---|---|---|
| the seam file list, inline in a `loop:` | `argocd_seam_files` | 3 files | 2 files |
| `application platform-onprem` | `argocd_root_app` | `platform-onprem` | `platform-gcp` |
| `KUBECONFIG` from `kubeconfig_fetch_path` | `argocd_kubeconfig` + `argocd_kube_context` | the fetched `admin.conf` | `~/.kube/config` |

**`projects.yaml` is shared and was not edited.** That was not planned. The AppProjects turned out
to be substrate-independent because their `destinations` name `https://kubernetes.default.svc` —
the address a cluster uses for *itself* — so the trust boundary travels without a line changing.
The same is true of the root Application's `destination`, which is why `root-gcp.yaml` differs from
`root-onprem.yaml` in two lines: the name and the path it watches.

**The third row is not a rename.** Until now the role exported `KUBECONFIG` and let kubectl use
whatever `current-context` that file happened to carry. On-prem that is harmless: the fetched
`admin.conf` holds exactly one cluster and the `control_plane` role never writes to it again.

It stops being harmless the moment there are two clusters. `make gcp-kubeconfig` writes into
`~/.kube/config`, alongside `onprem-admin` and any stale `gke_*` context from a deleted cluster,
and `current-context` there is whatever the last `gcloud` or `kubectl` command set. **A role that
installs Argo CD into "whichever cluster was most recently selected" is one `kubectl config
use-context` away from installing the on-prem platform onto GKE — and both would succeed.** So
`--context` (and helm's `--kube-context`, which is spelled differently) is passed on every call.

### 3. Because the context is explicit, it can be wrong — so the role asserts it exists

Making the context explicit introduces a new way to fail, and it failed immediately. The first
version passed `{{ kube_context }}`, which is `onprem-admin` — the readable name the
`control_plane` role renames to while merging a **copy** into `~/.kube/config`. The file the role
actually points at still carries kubeadm's own `kubernetes-admin@onprem`. That flag would have
broken a working on-prem path, blind, with an error about a context several layers from the cause.

So the role now reads the kubeconfig's context list and asserts the named one is in it, printing
the ones that are. A wrong name fails in one second with the answer in the message, rather than
acting on the wrong cluster or failing obscurely.

**And the guard had the exact bug it was built to prevent.** Pointed at a hand-written kubeconfig
holding two contexts, the assertion reported *"kubectl listed NO contexts in it"*. kubectl was not
installed on that machine. A check whose "no" does not mean no — the fourth instance of that shape
in this project, after `kubectl auth can-i create serviceaccounts/token`, the External Secrets
store read during a backoff, and `cost-check` reporting a clean account it had not read.

It was found by deliberately running the failure path to read its message, which is now the habit
worth keeping: **the error branch of a guard is the branch that will never be exercised in
production, so it is the one to exercise on purpose.** Two fixes followed — the binaries are ruled
out first, and the message keeps three outcomes apart instead of two (kubectl listed contexts /
the file holds none / kubectl could not read it).

### 4. The Argo CD version pins move to `clusters/platform.json`

They were in `clusters/onprem/nodes.json`, which was correct when there was one cluster and became
a category error when there were two: a chart version is not a fact about three virtual machines.

The tempting alternative was a copy in `clusters/gcp/cluster.json`. That is two numbers that
**must** agree with nothing making them agree — they agree until the day one is bumped, and the
symptom is two clusters running different versions of the tool whose job is to make them the same,
found by a behaviour difference nobody connects to a version for an hour.

So: `clusters/platform.json` holds what is true of Layer 2 everywhere, and both inventories read
it. `nodes.json` keeps a comment where the keys were, because the next person looking for the Argo
CD version will look there first.

**One values file, shared**, for reasons recorded in that file: the two things in
`argocd-values.yaml` that look on-prem-specific are cosmetic (`global.domain`, used for generated
links, while both clusters are reached by port-forward) or coincidentally identical (resource
requests sized for a 4 GB node; GKE's e2-medium is also 4 GB). Splitting it today would produce
two identical files. A per-substrate overlay passed as a second `--values` is the cheaper answer
when one line genuinely needs to differ.

### 5. The GCP platform set is two Applications, and five absences are decisions

`gitops/clusters/gcp/platform/` holds `gitops-canary.yaml` and `cert-manager.yaml`. Both cost ₹0
beyond the nodes already running.

- **The canary** is first on purpose. It renders plain manifests from the *same* directory the
  on-prem cluster renders — no overlay, no values, nothing substrate-specific — so a
  `Synced/Healthy` on it proves the entire Layer 2 chain on a second substrate: the role installed
  Argo CD, the seam applied, the root Application found its directory, the AppProject let it read
  this repository, the controller reconciled something real. Proving that with the cheapest
  possible payload means every later failure has a known-good baseline. The alternative — finding
  out whether Argo CD works by deploying External Secrets with Workload Identity — produces a
  failure that could be in any of six layers.
- **cert-manager** tests the harder claim: a wrapper chart with an upstream dependency, rendered
  from the same `gitops/charts/cert-manager`, differing only in a values file selected by path.
  One path segment apart, on-prem gets a self-signed root CA and three certificates; here
  cert-manager installs and issues nothing.

The five absences, each recorded in its own overlay file:

| component | why there is no Application |
|---|---|
| `metrics-server` | GKE runs its own. A second one would fight it for the **cluster-scoped** `metrics.k8s.io` APIService: last writer owns the endpoint, `kubectl top` keeps working, the HPA reads whichever won. A conflict with no error message. |
| `local-path` | GKE has a default StorageClass backed by Persistent Disk, which detaches from a dead node and reattaches elsewhere — the property on-prem's node-local provisioner cannot have. |
| `vault` | The backend here is GCP Secret Manager via Workload Identity. The hardest problem in the on-prem design — an unseal key a human holds and re-enters after every restart — does not exist, because Google's KMS has a hardware root of trust and a laptop does not. |
| `platform-ingress` | A `type=LoadBalancer` Service here is fulfilled by a Google load balancer that bills monthly, which ADR-0003 forbids leaving running. GKE Gateway is a different implementation of the same contract and belongs in its own module. |
| `tenant-network-policies` | No tenant on this cluster yet. The pod-to-pod rules would port unchanged; "allow the ingress layer in" would not, and that is the finding recorded in the overlay. |

**The pattern in the first two rows is the real content of this section.** On a managed substrate
**Layer 1 extends further up than it does on-prem.** metrics-server is a component of *our*
platform on a cluster built from kubeadm, and part of *Google's* platform on a cluster they built.
The boundary moved, and the overlay mechanism cannot express "this component belongs to someone
else" — only an absent Application can. That is a limit of ADR-0010's design, found by using it.

### 6. `make lint` renders every chart against every environment that deploys it

It rendered every chart against `onprem` and only `onprem`, which was right with one cluster and
became a hole with two. `gitops/environments/gcp/` had existed for several modules, unrendered and
unchecked, and the first thing to deploy from it would have found out at Argo CD sync time.

The pairs are derived from the **Applications**, not from a list, so coverage grows on its own:
adding `gitops/clusters/<env>/platform/<chart>.yaml` is what makes that overlay checked. A list
would have to be remembered by the module least likely to remember it. Environments with overlays
but no Applications — `aws`, seven files — are deliberately *not* rendered: a failure in a file
nothing deploys is not yet a failure, and reporting it would mean fixing problems against
decisions that have not been made.

## Consequences

**What this buys.** One Layer 2 definition, one version pin, one values file, one set of
assertions, for three substrates. Adding AWS in Module 09 means an `aws.py` inventory, an
`aws.yml` playbook, a `root-aws.yaml`, and no change to the role.

**What it costs.** The role is now configured by its inventory rather than readable top to bottom:
"which cluster does this install into" is answered in `ansible/inventory/gcp.py`, not in the
tasks. The assertion block at the top is the mitigation — it names every variable the role needs
in one place and refuses to run without them.

**Layer 2 is a single point of failure for recovery on three clusters now, not one.** ADR-0002
already stated that risk; it is three times larger. The compensation is unchanged and is the
reason the role is written the way it is: it depends on nothing inside the cluster, so it works
when the cluster does not.

**A new hazard this ADR only half-closes.** The Argo CD and GitOps *helper* targets in the
Makefile — `gitops-status`, `argocd-password`, `argocd-ui`, `gitops-refresh` — still act on
`current-context`. They are read-only, so a wrong cluster costs confusion rather than damage, and
forcing an explicit context on every invocation is friction out of proportion to that. They take
`CTX=` and **print which context they acted on**, which makes the ambiguity visible rather than
removing it. Anything that writes gets the opposite treatment: the role names its context and
asserts it. Revisit when something destructive joins that list.

**A sentence in an overlay was a plan, not a decision.**
`gitops/environments/gcp/cert-manager.yaml` said Module 08 would use an ACME ClusterIssuer with
DNS-01 against Cloud DNS. It does not, and cannot: DNS-01 needs a public zone (~$0.20/month, a
standing charge ADR-0003 forbids outright) and a domain this project does not own. Neither fact
needed hindsight; they were simply not checked when the sentence was written. The original wording
is kept in the file above the correction, because the pattern — **a plan recorded as a decision
because it was plausible** — is the one this project keeps finding in its own notes, and it is the
same shape as ADR-0019 Decision 2 reasoning about version drift from a release channel without
comparing the two actual version numbers.

**`applicationSet` stays off.** Two root Applications this similar is the obvious argument for a
generator, and it is the right *end state* rather than the right next step: a mistake in a
generator is a mistake on every cluster at once. Worth making deliberately with three clusters to
justify it, not with two. `argocd-values.yaml` already carries the note.

## Amendment, 2026-11-01: fetching the chart is not part of installing it

The first real run of `make gcp-argocd` against a live GKE cluster got through all five guards
above and then failed here:

```
TASK [argocd : Install or upgrade Argo CD]
  Error: Get "https://release-assets.githubusercontent.com/...argo-cd-10.11.0.tgz":
  context deadline exceeded (Client.Timeout exceeded while awaiting headers)
  rc: 1    delta: 0:02:01
```

A slow network between WSL2 and GitHub's release CDN, presenting as a failed Argo CD install on a
brand-new cluster — ten tasks of cluster-shaped output above it and `rc: 1` at the bottom. The
first thing anyone would suspect is the cluster, and the cluster was fine.

**The cause is that one command did two unrelated things.** `helm upgrade --install argocd
argo/argo-cd --version X` downloads a tarball from the internet *and* talks to the cluster, inside
a single `command` task whose failure message is "the command exited with a non-zero return code".
There is no way to retry the half that is worth retrying, and no way to tell the two halves apart
in the output.

So the fetch is now its own step: `helm pull` into `.cache/`, four attempts, then install from the
local path. Three things follow, and the third was not the motivation but is the most useful:

1. **Only the network retries.** Retrying the combined command would re-run a release install
   that may already have started creating objects under `--wait`.
2. **The download happens once** per chart version per workstation — so the other substrate's run
   ten minutes later, and every re-run, use the file on disk.
3. **A human can put the file there.** If that CDN is unreachable rather than slow, getting
   `argo-cd-<version>.tgz` into `.cache/` by any means makes this role work unchanged. Verified
   by running it with the download deliberately broken and the file pre-placed: it succeeds.

`--version` is dropped from the install, because helm rejects it against a local chart path. The
pin is not lost — it selects the filename, and a new task re-reads the version *out of the
archive* with `helm show chart` before installing. That task exists for a specific failure: **a
download that times out part-way leaves a file.** Without the check, the `stat` would find it,
every later run would skip the fetch, and helm would fail on a truncated archive forever — a
permanent failure inherited from a transient one.

This is the same shape as the `.cache` handling the Gateway API bundle already had (ADR-0012), and
it should have been the pattern from the start: **anything fetched over the network is a separate,
retryable, cacheable step from anything done with it.**

A smaller note, recorded because it happened twice in one minute. The comment beside `retries: 4`
first said "four attempts", was then "corrected" to five on a misreading of Ansible's countdown
log, and is four: Ansible counts down `3 retries left` → `0 retries left` and stops, and the
registered result reports `attempts: 4`. The message now prints `argocd_pull.attempts` instead of
restating the number. **A count written in prose beside the same count in code is a second copy of
a fact**, and this copy was wrong within a minute of being written.

## Verified

**On a live GKE cluster, 2026-11-01. `make gcp-argocd`: 27 ok, 3 changed, 0 failed. `make
gcp-smoke`: every check passed.** Every claim this ADR made and could not settle is now settled:

| claim | result |
|:--|:--|
| the same role installs Argo CD on GKE | chart 10.11.0 → Argo CD **v3.5.5**, the version `clusters/platform.json` pins for every substrate, read back off the running deployment |
| the seam applies | `projects.yaml` + `root-gcp.yaml`, both created server-side |
| `platform-gcp` reaches Synced/Healthy | yes, after one retry while the controller started |
| the canary appears | `generation=2`, matching Git — rendered from the directory on-prem renders, with no overlay |
| cert-manager's CRDs apply with `ServerSideApply` on this datapath | **Synced/Healthy** |
| GKE serves `kubectl top` without us installing one | yes, and the negative check passed: no `metrics-server` Application here |
| `datapath_provider` | **`ADVANCED_DATAPATH`** — NetworkPolicy will actually be enforced |
| the pool name is the only controllable part of a node name | `gke-platform-workers-c328afe6-3qlb`, with `platform` appearing once |

Decisions 2–4 held on the first attempt, which is the part worth noting: the guards passed, the
context was found in `/home/sagar/.kube/config`, and **the only thing that failed on first contact
with a real cluster was the network, not the design** (amended above).

### Two bugs in the checking, found by reading output that had already passed

Both are the shape this project keeps finding, and both were in checks written the same day.

**`make gcp-smoke` reported "returns data for 1 node(s)" against a two-node cluster.** The count
came from `printf '%s' "$top" | wc -l`: command substitution strips the trailing newline, so N
lines carry N−1 newlines. An off-by-one in a shell pipeline — and the wrong number reads exactly
like a real, documented failure mode, since the on-prem parking-lot entry about kubelet serving
certificates *is* "metrics-server cannot scrape some nodes". The check passed anyway, because
**the number was printed and never compared to anything.** A number with nothing to compare it
against looks like evidence and carries none: no value of it would have failed anything. It is now
compared against the node count, and a shortfall is a warning that says to re-run before
concluding — because "not scraped yet" and "cannot be scraped" look identical in one read, which
is the same lesson as the External Secrets store read during its backoff.

**The first install wrote a `.cache/seam-diff-*.diff` for every seam file.** `kubectl diff` exits 1
whether the object differs or does not exist, so a diff against nothing (`@@ -0,0 +1,24 @@`) was
recorded as drift. Those files exist for one purpose — evidence for the unexplained seam re-applies
in `docs/parking-lot.md`, where a saved diff is what finally showed the cause was a line of ours —
and an evidence directory that also fills up on every clean install is one somebody has to sort
before they can use it, which is most of the way to not using it. A diff whose every hunk starts
at `-0,0` is now reported as a creation in one line and not saved. Classification verified against
five diff shapes, including the two that matter: a file where one object is created and another
has drifted, and `rc=1` with no output at all. Both resolve to *difference*, so ambiguity records
evidence rather than discarding it.

### Everything the cluster could not show

These were verified against stubbed `helm` and `kubectl`, which exercises the role's logic and
nothing about Kubernetes. They are the *failure* paths — the branches a working cluster never
reaches, and therefore the ones to exercise deliberately:

- the full happy path, 24 tasks, `failed=0`, installing from the local tarball with
  `--kube-context` and no `--version`;
- the CDN unreachable: four attempts, then a message that says the workstation's network is at
  fault and names the path to drop a file into;
- the download truncated: the version read out of the archive catches it and says which file to
  delete, instead of helm failing on it on every future run;
- the chart already on disk *with the download deliberately broken*: succeeds, fetch skipped;
- a seam that is being created vs one that has drifted: one line each vs a saved diff, with the
  mixed and empty-output cases both erring toward saving evidence.

And these without a cluster at all:

- `clusters/platform.json` parses; both inventories render and emit the same `argocd_*` key set
  with substrate-correct values — `kubernetes-admin@onprem` vs `gcp-platform`, three seam files vs
  two, `platform-onprem` vs `platform-gcp`.
- `ansible-playbook --syntax-check` passes on `cluster.yml` and `gcp.yml`.
- `gcp.yml` **run for real** against a machine with no kubeconfig: it reaches the guards and stops
  there. That run is what exposed the missing-binary false negative described in Decision 3.
- All four branches of the context-report message exercised against stub register values
  (contexts listed / empty file / kubectl errored with stderr / kubectl absent, which reports via
  `msg` and not `stderr`).
- `make lint` clean, including the new render matrix — which resolves to exactly the previous
  seven `onprem` pairs plus `cert-manager (gcp)`.

### What is still not established

**That NetworkPolicy blocks a packet on this cluster.** `make gcp-smoke` reads
`datapath_provider` out of the control plane, which is one step better than reading our own
manifest and one step worse than a probe. `make netpol-check` is the probe and has no GCP
counterpart, because there is no tenant here to write policies about — so the cluster that was
*fixed* to enforce NetworkPolicy has not yet been shown to enforce one. That belongs with
ShopVerse on GKE.

**That the budget alert email arrives.** Unchanged from ADR-0019, and the one thing in the cost
guardrail that no amount of API reading can settle.

**That `make gcp-argocd` reports `changed=0` on a second run.** The idempotency gate every other
module had to pass has not been run here: the first install necessarily reported `changed=3` (the
chart repo, the fetch, the install), and nobody has yet run it twice against the same cluster. The
pieces are in place — the values-drift check, the chart-version check, the creation-vs-difference
split above — but "in place" is not "observed", which is the distinction this whole document is
about. **Next GCP session, run it twice.**
