# Roadmap

Twelve modules from an empty repository to a platform running a real application on three
substrates. Each module has a **Definition of Done** that is objectively checkable — it either
passes or it does not. No module is "mostly finished".

**The shape of every module:** decide → automate → verify → document → commit. If a module ends
without a commit, it did not happen.

## Rules of engagement

These exist because the previous attempt broke each of them.

1. **Nothing is installed by hand.** See ADR-0002. If it belongs in the cluster, it belongs in Git.
2. **Timebox the yak-shaving.** If a side problem (a VMware quirk, a Windows path, a DHCP lease)
   has eaten 45 minutes, it goes in `docs/parking-lot.md` and we route around it. Last time this
   class of problem consumed whole evenings.
3. **Every module ends with STATUS.md updated.** Thirty seconds. It is how you resume after two
   weeks away.
4. **A working thing beats a complete thing.** We get ShopVerse serving traffic by Module 06, then
   deepen. The last attempt had no workload after 1,452 messages.
5. **Destroy what you create in the cloud, the same session.** See ADR-0003.
6. **Write the runbook while you remember.** Each platform component gets one page in
   `docs/runbooks/` as it is installed, not later.

---

## Phase 1 — Make it exist (Modules 00–04)

### Module 00 — Foundations

Repository, decisions, guardrails, local tooling.

- **Deliverables:** this repo; ADR-0001/0002/0003; `.gitattributes`; `make doctor`; cloud accounts
  with budget alarms.
- **Done when:** `make doctor` passes on your workstation, both cloud budget alerts exist and have
  been tested with a deliberate trigger, and nothing cloud-side has been created yet.
- **Sessions:** 1

### Module 01 — The on-prem substrate, built from code

Choose the substrate, then build the VMs reproducibly instead of clicking through a wizard.

- **Deliverables:** substrate ADR; a scripted VM build (Packer image + Terraform, or a documented
  scripted path if the hypervisor's API does not allow it); `make onprem-vms` and
  `make onprem-vms-destroy`.
- **Done when:** you destroy all VMs and rebuild them from one command, and the rebuilt nodes are
  byte-identical in configuration — unique hostnames, unique machine-ids, unique SSH host keys,
  static addressing that survives a reboot.
- **Sessions:** 2–3
- **Why this matters:** the last attempt hand-built a template and then spent an evening on DHCP
  reservations. Automating this once removes an entire category of future pain.

### Module 02 — Kubernetes, by hand, once

Build the control plane with kubeadm manually, understanding every phase. This is the only module
where manual work is the point.

- **Deliverables:** `docs/runbooks/cluster-bootstrap.md` written as you go; a CNI chosen with
  reasons recorded; a smoke-test script.
- **Done when:** `scripts/smoke-test.sh` passes — nodes Ready, Pod-to-Pod across nodes, DNS
  resolution, a Service reachable, and a deliberate node reboot recovers automatically.
- **Sessions:** 2

### Module 03 — Ansible: the bootstrap layer

Everything you just did by hand becomes code. This is Layer 1 and Layer 2 of ADR-0002.

- **Deliverables:** inventory, roles for OS prep, containerd, kubeadm, join; a single playbook.
- **Done when:** you `terraform destroy` the VMs, run `make onprem-up`, and have a working cluster
  with zero manual steps. Run it twice; the second run reports no changes.
- **Sessions:** 2–3

### Module 04 — Argo CD and the first reconciliation

Argo CD installed by Ansible (never by hand, never by itself), plus the app-of-apps skeleton.

- **Deliverables:** Ansible role for Argo CD; root `Application`; `AppProject`s; repository
  credentials via a documented mechanism.
- **Done when:** a commit to this repository changes the cluster without you running `kubectl`, and
  `kubectl delete` on a managed resource is reverted automatically by self-heal.
- **Sessions:** 1–2

---

## Phase 2 — Make it useful (Modules 05–07)

### Module 05 — The platform baseline

The add-ons every workload needs, all as wrapper charts, with the environment-overlay mechanism in
place from the first component.

- **Deliverables:** cert-manager + internal PKI; ingress (Gateway API); a storage class;
  metrics-server; `gitops/environments/{onprem,gcp,aws}/` overlays.
- **Done when:** the platform app-of-apps is fully Synced and Healthy on on-prem, and the overlay
  mechanism is proven by one value that genuinely differs per environment.
- **Sessions:** 3

### Module 06 — ShopVerse runs

The platform gets its tenant. This is the module that makes the project real.

- **Deliverables:** ShopVerse Helm chart deployed via Argo CD; MongoDB with persistence; TLS;
  DNS for the lab; a documented "how to reach it".
- **Done when:** you open the storefront in a browser over HTTPS with a trusted certificate, add an
  item to the cart and complete a checkout, and the order survives a Pod restart.
- **Sessions:** 2–3

### Module 07 — Secrets, properly

No plaintext secrets in Git, decided and implemented rather than postponed.

- **Deliverables:** chosen mechanism (Sealed Secrets, SOPS, or Vault + External Secrets) with an
  ADR comparing them; all ShopVerse credentials migrated; etcd encryption at rest enabled.
- **Done when:** `git grep` finds no credential, a fresh clone plus `make onprem-up` reproduces a
  fully working platform, and rotating one secret takes one commit.
- **Sessions:** 2

---

## Phase 3 — Make it portable (Modules 08–09)

### Module 08 — GCP: the managed environment

- **Deliverables:** Terraform for a zonal GKE cluster with spot nodes; `make up ENV=gcp` /
  `make down ENV=gcp`; the GCP overlay; `make cost-check`.
- **Done when:** the same platform and ShopVerse run on GKE from the same Git repository, the
  storefront is reachable through a cloud load balancer, and after `make down` the console shows
  no remaining billable resource.
- **Sessions:** 3
- **Cost note:** zonal cluster only — the free management credit does not cover regional.

### Module 09 — AWS: the self-managed environment

- **Deliverables:** Terraform for spot EC2 instances (no NAT gateway); Ansible reused from
  Module 03 to build the cluster; the AWS overlay; one EKS session for comparison, then destroyed.
- **Done when:** the same platform runs on AWS, you can explain in writing the six concrete
  differences from the GCP environment (ADR-0001 lists the axes), and the account is empty
  afterwards.
- **Sessions:** 3

---

## Phase 4 — Make it trustworthy (Modules 10–12)

### Module 10 — Observability

- **Deliverables:** kube-prometheus-stack; Grafana dashboards including ShopVerse's own; Loki;
  alert rules for the failures that actually matter; an SLO for the storefront.
- **Done when:** you induce a real failure (kill a node, fill a disk, break a dependency) and the
  alert that fires tells you what broke before you look at the cluster.
- **Sessions:** 2–3

### Module 11 — Resilience

- **Deliverables:** Velero backups to object storage; an etcd snapshot timer; a documented DR
  procedure; the Argo CD self-management experiment, done deliberately with the Ansible recovery
  path proven first.
- **Done when:** you delete the ShopVerse namespace *including its data*, restore from backup, and
  the storefront works with its orders intact — timed, and written up in a runbook.
- **Sessions:** 2–3

### Module 12 — Delivery and supply chain

- **Deliverables:** GitHub Actions to build, test, scan (Trivy) and sign (Cosign) ShopVerse images;
  an automated promotion PR that bumps the tag in this repo; branch protection; a policy engine
  rejecting unsigned or unscanned images.
- **Done when:** a one-line code change in ShopVerse reaches the on-prem cluster through CI and a
  merged PR, with no human running `kubectl` or `helm` anywhere in the path.
- **Sessions:** 2–3

---

## What "finished" means

v1.0 is tagged when Modules 00–12 are done and this is all true:

- A fresh clone plus one command produces a working platform on-prem.
- The same repository produces the same platform on GCP and on AWS.
- ShopVerse serves traffic over trusted TLS on all three.
- An induced failure produces an alert; a destroyed namespace is restored from backup.
- A code change reaches production through CI and GitOps, with no manual cluster access.
- Every component has a runbook, and every significant decision has an ADR.

Estimated total: **26–32 sessions**. At two sessions a week, about four months. The previous
attempt spent longer than that and did not reach Module 06.
