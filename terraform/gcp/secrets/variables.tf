locals {
  # One source of truth, the same arrangement as the other two GCP states and as nodes.json
  # on-prem (ADR-0008). Nothing here invents a value clusters/gcp/cluster.json already holds.
  cfg = jsondecode(file("${path.module}/../../../clusters/gcp/cluster.json"))

  # ---------------------------------------------------------------- the names, and why they are here
  #
  # These four strings also appear in gitops/environments/gcp/external-secrets.yaml, which Argo CD
  # reads as a static file and cannot template. That duplication is real and is checked rather
  # than trusted: `make lint` asserts the overlay agrees with this file and with cluster.json, the
  # same way it already asserts the on-prem load-balancer addresses agree between nodes.json and
  # the on-prem overlay. A duplicated value with a check is a different thing from a duplicated
  # value without one.

  # The Google service account External Secrets acts as. Its email is deterministic -
  # <id>@<project>.iam.gserviceaccount.com - which is what lets the overlay name it and lint
  # verify it.
  gsa_id = "external-secrets"

  # The Kubernetes service account that impersonates it. Created by the External Secrets chart,
  # and the pair below is what the Workload Identity binding is written against; a typo in either
  # produces a pod whose token is rejected with a message about the service account rather than
  # about the binding.
  ksa_namespace = "external-secrets"
  ksa_name      = "external-secrets"

  # ONE Secret Manager secret holding ALL SIX credentials as a JSON object, and this is the
  # finding that shaped the whole design rather than a convenience.
  #
  # ShopVerse's own chart (helm/shopverse/templates/externalsecret.yaml, in the application's
  # repository, which this platform does not control) renders:
  #
  #     data:
  #       - secretKey: jwt-secret
  #         remoteRef:
  #           key:      {{ .Values.externalSecret.remoteKey }}
  #           property: jwt-secret
  #       ... six times
  #
  # ONE remote key, six `property` lookups. On Vault that reads one KV path and picks fields out
  # of it; on Secret Manager the gcpsm provider JSON-parses the payload and does the same. So the
  # tenant's manifest is structurally IDENTICAL on both substrates and only `remoteKey` differs -
  # which is a value in an overlay, exactly where ADR-0018 said substrate differences belong.
  #
  # `shopverse-prod`, not `shopverse/prod`: Secret Manager secret IDs match [A-Za-z0-9_-]+ and
  # forbid the slash that Vault's hierarchy uses. That one character is the only place the two
  # backends' addressing is visibly different, and it is the reason `remoteKey` had to be a value
  # rather than a constant in the chart.
  #
  # AND IT IS ONE VERSION, NOT SIX, WHICH IS WHAT KEEPS THIS FREE. Secret Manager bills $0.06 per
  # active secret version per month with six free. Six separate secrets would have used the entire
  # free allowance, leaving a standing charge on the first rotation - and ADR-0003 forbids a
  # standing charge outright, however small. One secret leaves five versions of headroom.
  secret_id = "shopverse-prod"
}
