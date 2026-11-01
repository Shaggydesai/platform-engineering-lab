#!/usr/bin/env python3
"""Dynamic Ansible inventory, generated from clusters/onprem/nodes.json.

The inventory is NOT a file someone maintains. It is derived from the same JSON that Terraform
reads to build the VMs, so the inventory cannot describe a cluster that does not exist - which
is the single most common way an Ansible repository rots. Change a node's address in nodes.json
and both Terraform and Ansible see the change; there is nowhere for them to disagree.

Ansible's script inventory interface:
    --list          every group, host and variable, as JSON
    --host <name>   per-host vars; unnecessary here because _meta carries them

Try it by hand:
    ansible/inventory/nodes.py --list | jq
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CONFIG = os.path.join(REPO, "clusters", "onprem", "nodes.json")

# Layer 2 is defined once for every substrate (ADR-0020), so the Argo CD pins come from a file
# that is not about this cluster. gcp.py reads the same file the same way.
#
# NOT a shared helper module imported by both inventories, deliberately. Ansible executes an
# inventory script, so a sibling import works only because the script's own directory happens to
# be on sys.path - and it would break the moment ansible.cfg pointed `inventory` at this
# DIRECTORY rather than at one file in it, at which point Ansible would also try to parse the
# helper as an inventory source. Six duplicated lines that read one shared file beat a shared
# module that depends on a config line nobody would connect to the failure. The thing that must
# not be duplicated is the version, and it is not.
PLATFORM = os.path.join(REPO, "clusters", "platform.json")


def build():
    with open(CONFIG, encoding="utf-8") as fh:
        cfg = json.load(fh)
    with open(PLATFORM, encoding="utf-8") as fh:
        platform = json.load(fh)

    argocd = platform["argocd"]
    net = cfg["network"]
    k8s = cfg["kubernetes"]
    ssh = cfg["ssh"]

    groups = {"control_plane": [], "workers": []}
    hostvars = {}

    for node in cfg["nodes"]:
        name = node["name"]
        group = "control_plane" if node["role"] == "control-plane" else "workers"
        groups[group].append(name)
        hostvars[name] = {
            "ansible_host": node["address"],
            "node_address": node["address"],
            "node_role": node["role"],
            "node_cpus": node["cpus"],
            "node_memory_mb": node["memory_mb"],
        }

    cp = next(n for n in cfg["nodes"] if n["role"] == "control-plane")

    return {
        "all": {
            "children": ["control_plane", "workers"],
            "vars": {
                "ansible_user": ssh["username"],
                "ansible_ssh_private_key_file": ssh["private_key_file"],
                # Cluster-wide facts every role needs. They come from nodes.json rather than
                # from group_vars so that there is exactly one place to change them.
                "cluster_name": cfg["cluster"],
                "cluster_domain": net["domain"],
                "pod_cidr": k8s["pod_cidr"],
                "service_cidr": k8s["service_cidr"],
                "control_plane_endpoint": k8s["control_plane_endpoint"],
                "control_plane_name": cp["name"],
                "control_plane_address": cp["address"],
                "cni": k8s["cni"],
                "kubernetes_version": k8s["version"],
                "cilium_version": k8s["cilium_version"],
                "gateway_api_version": k8s["gateway_api_version"],
                "gateway_api_sha256": k8s["gateway_api_sha256"],
                # Every node's name, so a role can assert resolution rather than assume it.
                "all_node_names": [n["name"] for n in cfg["nodes"]],
                # Workstation-side paths. Emitted here rather than in group_vars so that there
                # is no second file to find, and so they are derived from where this repository
                # actually is rather than from a hardcoded path that works on one machine.
                "repo_root": REPO,
                "cilium_values_file": os.path.join(
                    REPO, "ansible", "roles", "cilium", "files", "cilium-values.yaml"
                ),
                "kubeconfig_fetch_path": os.path.expanduser("~/.kube/onprem.conf"),
                # ---------------------------------------------------------- Layer 2, on-prem
                # Everything the argocd role needs that differs between substrates. The role
                # itself names no cluster, no file and no Application; it reads these (ADR-0020).
                "argocd_chart_version": argocd["chart_version"],
                "argocd_app_version": argocd["app_version"],
                "argocd_values_file": os.path.join(REPO, argocd["values_file"]),
                # The PRISTINE fetched admin.conf, not ~/.kube/config. The control_plane role
                # fetches it and never touches it again, so it holds exactly one cluster - which
                # is what makes it the safe thing to point Layer 2 at.
                "argocd_kubeconfig": os.path.expanduser("~/.kube/onprem.conf"),
                # THE CONTEXT INSIDE THAT FILE, which is NOT kube_context.
                #
                # kube_context (onprem-admin) is the readable name the control_plane role renames
                # to while merging a COPY into ~/.kube/config. The fetched file still carries
                # kubeadm's own name, so `--context onprem-admin` against it fails - which is
                # exactly the mistake adding --context to this role invited, and the reason the
                # role now asserts the context exists before it installs anything.
                "argocd_kube_context": f"kubernetes-admin@{cfg['cluster']}",
                # The seam (ADR-0009). Order matters: an Application referencing a missing
                # AppProject is rejected, so projects.yaml stays first.
                #
                # projects.yaml is SHARED with GCP, unchanged. The AppProjects turned out to be
                # substrate-independent because their destinations name the in-cluster address
                # rather than a cluster - so the boundary travels.
                "argocd_seam_files": [
                    "projects.yaml",
                    "root-onprem.yaml",
                    "root-tenants-onprem.yaml",
                ],
                "argocd_root_app": "platform-onprem",
                "argocd_platform_path": "gitops/clusters/onprem/platform",
                # Downloaded, verified, then applied. Under the repo rather than /tmp so that
                # a WSL shutdown clearing /tmp cannot silently change what is verified.
                "gateway_api_bundle": os.path.join(REPO, ".cache", "gateway-api-standard-install.yaml"),
                "kube_context": f"{cfg['cluster']}-admin",
            },
        },
        "control_plane": {"hosts": groups["control_plane"]},
        "workers": {"hosts": groups["workers"]},
        "_meta": {"hostvars": hostvars},
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
