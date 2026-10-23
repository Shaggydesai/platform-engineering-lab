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


def build():
    with open(CONFIG, encoding="utf-8") as fh:
        cfg = json.load(fh)

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
                "argocd_chart_version": k8s["argocd_chart_version"],
                "argocd_app_version": k8s["argocd_app_version"],
                # Every node's name, so a role can assert resolution rather than assume it.
                "all_node_names": [n["name"] for n in cfg["nodes"]],
                # Workstation-side paths. Emitted here rather than in group_vars so that there
                # is no second file to find, and so they are derived from where this repository
                # actually is rather than from a hardcoded path that works on one machine.
                "repo_root": REPO,
                "cilium_values_file": os.path.join(
                    REPO, "ansible", "roles", "cilium", "files", "cilium-values.yaml"
                ),
                "argocd_values_file": os.path.join(
                    REPO, "ansible", "roles", "argocd", "files", "argocd-values.yaml"
                ),
                "kubeconfig_fetch_path": os.path.expanduser("~/.kube/onprem.conf"),
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
