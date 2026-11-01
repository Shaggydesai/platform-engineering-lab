# The GCP secret backend: an identity, a grant, and an empty box to put secrets in.
#
# ADR-0018 chose External Secrets so the tenant's manifest would be portable. This state is the
# other half of that bet on GCP: a Google service account the operator acts as, a Workload
# Identity binding that lets a Kubernetes service account become it without a key file, and one
# Secret Manager secret.
#
# WHAT IS NOT HERE, and it is the most important line in the file:
#
#   NO google_secret_manager_secret_version. NO secret VALUES, of any kind.
#
# Terraform writes every attribute it manages into terraform.tfstate in plaintext, including ones
# marked sensitive - `sensitive` suppresses them in OUTPUT, not in state. A
# google_secret_manager_secret_version with `secret_data` set would therefore put all six
# ShopVerse credentials in a local file, and a module whose entire subject is "no secrets in Git"
# would have put them on disk next to the repository on the way to the secret manager.
#
# So Terraform creates the secret as an empty container and `make gcp-secrets-seed` adds the
# version, generating the values and streaming them in on stdin. The division is deliberate:
# Terraform owns the SHAPE, a script owns the CONTENT, and the content exists in exactly one place
# that is not a laptop.
#
# NO google_project_service RESOURCES, for the reason ADR-0019 Decision 1c establishes: an API
# that must exist before Terraform can refresh its own state cannot be managed by that Terraform.
# Refreshing a secret calls the Secret Manager API. `make gcp-secrets` enables it with gcloud
# first.

# ---------------------------------------------------------------------------- the identity
resource "google_service_account" "external_secrets" {
  account_id = local.gsa_id
  project    = local.cfg.project_id

  display_name = "External Secrets Operator"
  description  = "Read-only access to ShopVerse's credentials in Secret Manager. Impersonated by the external-secrets Kubernetes service account via Workload Identity - no key file exists for this account."
}

# ---------------------------------------------------------------------------- the box
resource "google_secret_manager_secret" "shopverse" {
  secret_id = local.secret_id
  project   = local.cfg.project_id

  replication {
    # Google picks the locations and manages the keys. The alternative - user_managed with an
    # explicit location list - would let this sit in asia-south1 beside the cluster, and buys
    # nothing a lab can measure while adding a value that must agree with cluster.json.
    #
    # Worth knowing for the cost line either way: a version is billed per version per LOCATION,
    # so a user-managed replica in three regions is three times the count against the six-version
    # free tier. Automatic counts as one.
    auto {}
  }

  labels = {
    substrate = "gcp"
    tenant    = "shopverse"
    # So `make cost-check` and a human reading the console can both tell this apart from a secret
    # somebody created by hand. The abandoned shopverse-lab project is the reason that matters.
    managed-by = "terraform-gcp-secrets"
  }
}

# ---------------------------------------------------------------------------- the grant
#
# ON THE SECRET, NOT ON THE PROJECT, and that is the whole point of this resource existing in this
# shape. `google_project_iam_member` with roles/secretmanager.secretAccessor would let External
# Secrets read EVERY secret in the project, now and in future, including ones created by something
# else entirely.
#
# This is the GCP analogue of the Vault policy `make vault-bootstrap` writes, which grants read on
# `secret/data/shopverse/*` and `secret/data/platform/*` and nothing else. The parking-lot entry
# about a ClusterSecretStore being one identity for the whole cluster still applies here - the
# boundary is this grant, not the namespace asking - but at least the grant is as narrow as the
# single secret rather than as wide as the project.
resource "google_secret_manager_secret_iam_member" "eso_reads_shopverse" {
  project   = local.cfg.project_id
  secret_id = google_secret_manager_secret.shopverse.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.external_secrets.email}"
}

# ---------------------------------------------------------------------------- Workload Identity
#
# THE RESOURCE THAT REPLACES A KEY FILE, and the comparison with on-prem is the clearest thing
# this substrate has produced.
#
# On-prem, ESO proves who it is like this: it mints a short-lived token for its Kubernetes service
# account, presents it to Vault, and Vault calls TokenReview back to the API server to ask whether
# the token is real. Three identities, a Vault role, a Vault policy, an auth mount, and an unseal
# key a human re-enters after every restart (ADR-0018).
#
# Here, GCP trusts the cluster's OIDC issuer directly. The member string below says: "the
# Kubernetes service account external-secrets/external-secrets, in this project's workload identity
# pool, may act as this Google service account". No token review, no role, no policy, no shared
# secret anywhere in the chain - and nothing to lose.
#
# That is not Vault being badly designed. It is the irreducible secret being moved into something
# with a hardware root of trust, which a laptop does not have.
#
# THE MEMBER STRING IS WHERE THIS GOES WRONG. `[namespace/name]`, square brackets included, and a
# mismatch is not rejected at apply time - IAM accepts any syntactically valid principal, including
# one naming a service account that does not exist. The failure appears later, in the pod, as a
# 403 on the metadata server that reads like a missing role rather than a misspelled name. Both
# halves come from the same locals the overlay is checked against.
resource "google_service_account_iam_member" "eso_impersonates" {
  service_account_id = google_service_account.external_secrets.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.cfg.project_id}.svc.id.goog[${local.ksa_namespace}/${local.ksa_name}]"
}
