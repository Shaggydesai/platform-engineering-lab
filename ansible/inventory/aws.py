#!/usr/bin/env python3
"""Dynamic Ansible inventory for the AWS substrate.

Addresses come from TERRAFORM STATE, not from a config file, and that is the one structural
difference from ansible/inventory/nodes.py. On-prem, every node's address is a CHOICE written in
clusters/onprem/nodes.json - libvirt is told to use it and cloud-init configures it, so the file
can be the source of truth for both Terraform and Ansible. On EC2 an address is an ALLOCATION:
AWS picks it at launch and it changes every session. The same distinction ADR-0019 drew for the
GKE load balancer, one layer down.

So this reads `terraform output -json nodes`, which means the inventory cannot describe a cluster
that does not exist - the same property nodes.py gets from reading the file Terraform reads.
Everything else (versions, CIDRs, SSH) comes from clusters/aws/cluster.json, whose pins `make
lint` checks against the on-prem ones.

Ansible's script inventory interface:
    --list          every group, host and variable, as JSON
    --host <name>   per-host vars; unnecessary here because _meta carries them

Try it by hand:
    ansible/inventory/aws.py --list | jq
"""

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CONFIG = os.path.join(REPO, "clusters", "aws", "cluster.json")
PLATFORM = os.path.join(REPO, "clusters", "platform.json")
TF_DIR = os.path.join(REPO, "terraform", "aws")

# The same six lines nodes.py and gcp.py each carry, and still deliberately duplicated rather
# than imported. Ansible EXECUTES an inventory script, so a sibling import breaks the moment
# `inventory` points at the directory instead of the file - and an inventory that fails to
# import fails in a way that reads as "no hosts matched" rather than as an error.


def terraform_nodes():
    """The nodes Terraform actually built, or a usable error."""
    try:
        out = subprocess.run(
            ["terraform", f"-chdir={TF_DIR}", "output", "-json", "nodes"],
            capture_output=True, text=True, timeout=60, check=False,
        )
    except FileNotFoundError:
        sys.exit(
            "terraform is not on PATH, and this inventory reads node addresses from its state.\n"
            "On AWS an address is allocated at launch rather than chosen, so there is no file to\n"
            "read instead - see the docstring."
        )
    except subprocess.TimeoutExpired:
        sys.exit("`terraform output` took more than 60s - is the state locked by another apply?")

    if out.returncode != 0:
        err = (out.stderr or "").strip().splitlines()
        hint = err[0] if err else "no error text"
        sys.exit(
            f"could not read the Terraform outputs: {hint}\n\n"
            "If the state is empty, the cluster has not been built yet:\n"
            "  make aws-up\n"
            "If it complains about initialisation, the module has never been init'd here:\n"
            f"  terraform -chdir={TF_DIR} init"
        )

    try:
        nodes = json.loads(out.stdout)
    except json.JSONDecodeError:
        sys.exit("`terraform output -json nodes` did not return JSON - run it by hand and look")

    if not nodes:
        sys.exit("Terraform knows of no nodes. Build them first:  make aws-up")
    return nodes


def build():
    with open(CONFIG, encoding="utf-8") as fh:
        cfg = json.load(fh)
    with open(PLATFORM, encoding="utf-8") as fh:
        platform = json.load(fh)

    argocd = platform["argocd"]
    k8s = cfg["kubernetes"]
    ssh = cfg["ssh"]
    nodes = terraform_nodes()

    groups = {"control_plane": [], "workers": []}
    hostvars = {}

    for name, node in sorted(nodes.items()):
        group = "control_plane" if node["role"] == "control-plane" else "workers"
        groups[group].append(name)
        hostvars[name] = {
            # ANSIBLE REACHES THE NODE ON ITS PUBLIC ADDRESS, because Ansible runs on a laptop
            # outside the VPC. Everything the cluster does internally uses the private one -
            # see control_plane_address below.
            "ansible_host": node["public_ip"],
            "node_address": node["private_ip"],
            "node_public_address": node["public_ip"],
            "node_role": node["role"],
        }

    cp_name = cfg["nodes"]["control_plane"]["name"]
    if cp_name not in nodes:
        sys.exit(
            f"Terraform built no node called {cp_name}, which clusters/aws/cluster.json names as\n"
            f"the control plane. It built: {', '.join(sorted(nodes))}"
        )
    cp = nodes[cp_name]

    return {
        "all": {
            "children": ["control_plane", "workers"],
            "vars": {
                "ansible_user": ssh["user"],
                "ansible_ssh_private_key_file": ssh["public_key_file"].removesuffix(".pub"),
                # A fresh instance has a host key nothing has seen before, and its address is
                # reused across sessions - so strict checking fails on every build and a known
                # host from last week is a false alarm. Accepting the key is the honest setting
                # for cattle; it is NOT set on-prem, where the VMs persist.
                "ansible_ssh_common_args": "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null",
                "cluster_name": cfg["cluster_name"],
                # AWS gives every instance an internal name under this domain. Nothing here
                # depends on it resolving - the addresses are used directly - but the kubeadm
                # certSANs template interpolates it.
                "cluster_domain": f"{cfg['region']}.compute.internal",
                "pod_cidr": k8s["pod_cidr"],
                "service_cidr": k8s["service_cidr"],
                # THE PRIVATE ADDRESS, and this is the line that would cost money if it were the
                # public one. Workers join through this endpoint; over the public IP that traffic
                # would leave through the internet gateway and be billed, for every packet
                # between a kubelet and its API server.
                "control_plane_endpoint": f"{cp['private_ip']}:6443",
                "control_plane_name": cp_name,
                "control_plane_address": cp["private_ip"],
                # AND THE PUBLIC ONE GOES IN THE CERTIFICATE, because kubectl on the laptop can
                # reach nothing else. Leave it out and the cluster builds perfectly and then
                # refuses the first kubectl command with a certificate error naming an IP -
                # unfixable without reissuing the API server certificate.
                "extra_cert_sans": [cp["public_ip"]],
                "cni": k8s["cni"],
                "kubernetes_version": k8s["version"],
                "cilium_version": k8s["cilium_version"],
                "gateway_api_version": k8s["gateway_api_version"],
                "gateway_api_sha256": k8s["gateway_api_sha256"],
                "all_node_names": sorted(nodes),
                "repo_root": REPO,
                # THE ONE LINE OF cilium-values.yaml THAT IS ON-PREM-SPECIFIC.
                #
                # The file sets k8sServiceHost to k8s-cp01.platform.local, a name that exists
                # only in the libvirt nodes' /etc/hosts. On EC2 it does not resolve, and
                # kubeProxyReplacement: true means there is no kubernetes.default ClusterIP to
                # fall back to - kube-proxy is gone, and Cilium is what would have programmed
                # that address. So the agent cannot reach the API server, the DaemonSet never
                # becomes available, and `rollout status` reports a timeout with no cause.
                #
                # The PRIVATE address, and by address rather than by name: the nodes do resolve
                # aws-cp01 from the /etc/hosts cloud-init wrote, but an address removes a
                # dependency instead of relying on one, and kubeadm puts the advertise address
                # in the API server certificate itself.
                "cilium_values_override": {
                    "k8sServiceHost": cp["private_ip"],
                },
                "cilium_values_effective": os.path.join(
                    REPO, ".cache", "cilium-values-aws.yaml"
                ),
                "cilium_values_file": os.path.join(
                    REPO, "ansible", "roles", "cilium", "files", "cilium-values.yaml"
                ),
                # THE SAME PATH ON THE WORKSTATION AS ON-PREM, and shared deliberately. The
                # gateway_api role downloads the bundle to the laptop and verifies it against
                # gateway_api_sha256 before applying it, so one download serves both substrates
                # and `make lint` already asserts the two digests agree. A per-substrate path
                # would mean downloading the same pinned bytes twice to prove the same thing.
                "gateway_api_bundle": os.path.join(
                    REPO, ".cache", "gateway-api-standard-install.yaml"
                ),
                "kubeconfig_fetch_path": os.path.expanduser("~/.kube/aws.conf"),
                # A SEPARATE FILE FROM THE FETCHED ONE, which on-prem it is not. The fetched
                # admin.conf names the private controlPlaneEndpoint, so the gateway_api, cilium
                # and kube_proxy_removal roles - all of which run kubectl and helm on the
                # workstation - cannot reach the cluster through it. The control_plane role
                # writes this copy with the public server instead, and verifies the rewrite
                # landed on the cluster entry the context actually uses.
                #
                # Not ~/.kube/config: that holds three clusters, and a kubectl with no
                # --context there is aimed by whatever ran last (ADR-0020). This file has one
                # context, so there is nothing to aim wrongly.
                "cluster_kubeconfig": os.path.expanduser("~/.kube/aws-local.conf"),
                # THE READABLE NAME IN ~/.kube/config, which is NOT argocd_kube_context above.
                # kubeadm writes kubernetes-admin@platform into the fetched admin.conf; the
                # control_plane role renames it to this when it merges. Passing one where the
                # other is wanted is the mistake ADR-0020 records for the on-prem path.
                "kube_context": "aws-platform",
                # And the address that context should point at: the PUBLIC one, because kubectl
                # runs outside the VPC. extra_cert_sans above is the other half - without it this
                # address would fail TLS verification against a certificate that never heard of
                # it.
                "kube_server": f"https://{cp['public_ip']}:6443",
                "argocd_chart_version": argocd["chart_version"],
                "argocd_app_version": argocd["app_version"],
                "argocd_values_file": os.path.join(REPO, argocd["values_file"]),
                # THE MERGED CONFIG, NOT THE FETCHED ONE - and this is where copying the
                # on-prem inventory would have produced a cluster that builds and then reports
                # its own API server dead.
                #
                # The argocd role runs delegate_to: localhost. On-prem that is fine: every
                # address in onprem.conf is reachable from the laptop, so the fetched file works
                # unchanged. Here the fetched file names control_plane_endpoint, which is the
                # PRIVATE address by the decision above - so the role's /readyz probe would hang
                # and then say "its API server did not answer", which reads as a broken control
                # plane rather than as an address the laptop was never able to route to.
                #
                # So point it at the file the control_plane role merged, where the server is the
                # public address. ansible/inventory/gcp.py does the same thing for the same
                # reason, one layer up: on a cloud substrate the fetched kubeconfig is an
                # artefact, not a working one.
                "argocd_kubeconfig": os.path.expanduser("~/.kube/config"),
                # And therefore the MERGED context name, which is kube_context above rather than
                # the kubernetes-admin@<cluster> that kubeadm wrote. The two were different files
                # when this said aws.conf; now they are the same file, and the name that exists
                # in it is aws-platform. ADR-0020 records the near-miss from getting this pair
                # the wrong way round on the on-prem path.
                "argocd_kube_context": "aws-platform",
                # NO root-tenants-aws.yaml YET, deliberately. There is no tenant on this
                # substrate and no gitops/clusters/aws/apps to point one at - and a seam file
                # naming a path that does not exist is how an inventory starts describing a
                # cluster that is not there, which is the property this design exists to have.
                # `make lint` checks both directions: every seam file exists, and nothing in
                # bootstrap is orphaned.
                "argocd_seam_files": [
                    "projects.yaml",
                    "root-aws.yaml",
                ],
                "argocd_root_app": "platform-aws",
                "argocd_platform_path": "gitops/clusters/aws/platform",
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
