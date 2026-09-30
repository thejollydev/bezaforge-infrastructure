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

variable "cloud_init_password" {
  description = "Password for cloud-init user accounts on template-based VMs"
  type        = string
  sensitive   = true
}

variable "cloud_init_user" {
  description = "Name of the cloud-init user account on template-based VMs. Set it in terraform.tfvars, which is untracked; pass it to any module with create_from_template = true"
  type        = string
  default     = ""
}
