variable "proxmox_api_token" {
  description = "Proxmox API token in format root@pam!terraform=<token>"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  default     = "forge-hypervisor"
}

variable "ssh_public_key" {
  description = "SSH public key to inject via cloud-init"
  type        = string
}