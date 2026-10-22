variable "libvirt_uri" {
  type    = string
  default = "qemu:///system"
}

variable "nodes_file" {
  type        = string
  default     = "../../clusters/onprem/nodes.json"
  description = "The single source of truth, shared with Ansible."
}

variable "base_image" {
  type        = string
  default     = "../../packer/ubuntu-2404/output/ubuntu-2404-k8s.qcow2"
  description = "The Packer-built golden image. Build it with: make image"
}

variable "pool" {
  type        = string
  default     = "default"
  description = "libvirt storage pool. Lives inside WSL's ext4.vhdx, which sits on the SSD."
}
