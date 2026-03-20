terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.98"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://10.10.10.10:8006/"
  api_token = var.proxmox_api_token
  insecure  = true  # Self-signed cert — internal LAN only, acceptable
}