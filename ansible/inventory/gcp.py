#!/usr/bin/env python3
"""Dynamic Ansible inventory for the GCP substrate, from clusters/gcp/cluster.json.

ONE HOST, AND IT IS THIS WORKSTATION. That is the whole shape of this file, and it is worth
saying why rather than leaving it to be inferred.

The on-prem inventory (nodes.py) lists three machines because Ansible has to log into them:
kubeadm runs on the control plane, kubelets are configured on each node, static pod manifests are
written on disk. GKE has none of that. There is no control-plane node - Google manages it and it
never appears in `kubectl get nodes` - and the worker nodes are managed instances this repository
deliberately does not touch, because anything done to them by hand is lost on the next
auto-repair or upgrade.

So the only machine Ansible needs for the GCP substrate is the one it is already running on. The
argocd role never needed more than that either: every task in it delegates to localhost and
shells out to helm and kubectl, because it had to keep working when the cluster's own control
plane was the broken thing (ADR-0009). That property, chosen for recovery, is what made Layer 2
portable to a substrate with nothing to log into - which is the pleasant kind of accident.

WHAT IS NOT HERE: Layers 0 and 1. Terraform builds the VPC and the cluster (terraform/gcp), and
Google provides Kubernetes itself. There is no preflight, no CNI role, no kube-proxy removal and
no join. The GCP playbook is one play long, and ADR-0020 argues that is the honest measure of
what "managed" buys and costs.

Ansible's script inventory interface:
    --list          every group, host and variable, as JSON
    --host <name>   per-host vars; unnecessary here because _meta carries them

Try it by hand:
    ansible/inventory/gcp.py --list | jq
    make gcp-inventory
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CONFIG = os.path.join(REPO, "clusters", "gcp", "cluster.json")

# Layer 2 is defined once for every substrate (ADR-0020), so the Argo CD pins come from a file
# that is not about this cluster. nodes.py reads the same file the same way, and the reason that
# is a duplicated six lines rather than a shared helper module is written out there.
PLATFORM = os.path.join(REPO, "clusters", "platform.json")

# The kubectl context `make gcp-kubeconfig` creates. NOT the name gcloud generates
# (gke_<project>_<zone>_<cluster>), which is long enough that the shell prompt truncates it -
# and a truncated context name sitting next to onprem-admin is how a command lands on the wrong
# cluster, which on this substrate costs money rather than time.
#
# Hardcoded here and in the Makefile target that creates it. Those two must agree, and the
# argocd role asserts the context exists before it installs anything, so a disagreement fails
# with a list of the contexts that DO exist rather than acting on whichever one was selected.
KUBE_CONTEXT = "gcp-platform"


def build():
    with open(CONFIG, encoding="utf-8") as fh:
        cfg = json.load(fh)
    with open(PLATFORM, encoding="utf-8") as fh:
        platform = json.load(fh)

    argocd = platform["argocd"]

    return {
        "all": {
            "children": ["gcp"],
            "vars": {
                # Facts about the substrate, from the same file Terraform reads. Nothing here
                # can describe a cluster that does not exist, which is the property nodes.py
                # exists for and the reason this file is generated rather than written.
                "cluster_name": "platform",
                "gcp_project_id": cfg["project_id"],
                "gcp_zone": cfg["zone"],
                "gcp_region": cfg["region"],
                "repo_root": REPO,
                # ---------------------------------------------------------- Layer 2, GCP
                # The same keys nodes.py emits, read by the same role. Everything above the line
                # differs between substrates; everything below it is either shared outright or
                # the same shape with a different value.
                "argocd_chart_version": argocd["chart_version"],
                "argocd_app_version": argocd["app_version"],
                # THE SAME VALUES FILE as on-prem. clusters/platform.json records why one file
                # serves both, and what would have to change for that to stop being true.
                "argocd_values_file": os.path.join(REPO, argocd["values_file"]),
                # ~/.kube/config, NOT a dedicated file - and this is the one place the GCP path
                # is genuinely more dangerous than the on-prem one.
                #
                # On-prem, Layer 2 points at the pristine fetched admin.conf, which holds exactly
                # one cluster. There is no equivalent here: `gcloud container clusters
                # get-credentials` writes into the main kubeconfig, beside onprem-admin and any
                # stale gke_* context from a deleted cluster. current-context in that file is
                # whatever the last command set, so the context below is not a convenience - it
                # is what stops this role installing the platform onto the wrong cluster.
                "argocd_kubeconfig": os.path.expanduser("~/.kube/config"),
                "argocd_kube_context": KUBE_CONTEXT,
                # THREE seam files, matching on-prem, and the order matters: an Application
                # referencing a missing AppProject is rejected, so projects.yaml stays first.
                #
                # projects.yaml is shared with on-prem and UNCHANGED - the AppProjects turned out
                # to be substrate-independent, because their destinations name
                # https://kubernetes.default.svc and `shopverse-*` rather than a cluster. The
                # tenant root needed no edit to that file at all.
                #
                # It was two files until the tenant arrived. The third was added once the GCP
                # secret backend existed (ADR-0018's amendment): ShopVerse cannot start without
                # its six credentials, so deploying it before there was anywhere to read them
                # from would have been a crash-looping tenant rather than a milestone.
                "argocd_seam_files": [
                    "projects.yaml",
                    "root-gcp.yaml",
                    "root-tenants-gcp.yaml",
                ],
                "argocd_root_app": "platform-gcp",
                "argocd_platform_path": "gitops/clusters/gcp/platform",
            },
        },
        "gcp": {
            "hosts": ["gcp-platform"],
        },
        "_meta": {
            "hostvars": {
                # Named after the kubectl context rather than `localhost`, so that a line of
                # Ansible output saying "ok: [gcp-platform]" names the cluster being changed
                # instead of the machine doing the changing. With one host and everything
                # delegated to localhost anyway, the name is the only signal there is.
                #
                # ansible_connection: local means no SSH, no Python interpreter discovery over
                # the wire, and no host key - and it is set here rather than relying on the name
                # `localhost`, which is the implicit host Ansible invents and whose behaviour is
                # a special case rather than a setting.
                "gcp-platform": {
                    "ansible_connection": "local",
                    "ansible_python_interpreter": sys.executable,
                },
            },
        },
    }


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "--list"
    if arg == "--list":
        print(json.dumps(build(), indent=2))
    elif arg == "--host":
        print(json.dumps({}))
    else:
        sys.exit(f"usage: {sys.argv[0]} --list | --host <name>")


if __name__ == "__main__":
    main()
