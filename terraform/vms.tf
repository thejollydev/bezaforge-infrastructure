# ---------------------------------------------------------------------------
# forge-ai — VMID 101
# Ubuntu 24.04, RX 7900 XT GPU passthrough, ROCm + Ollama
# VLAN 50 (AI), 10.10.50.10
# ---------------------------------------------------------------------------

module "forge_ai" {
  source = "./modules/proxmox-vm"

  vm_id                 = 101
  name                  = "forge-ai"
  description           = "GPU inference host — ROCm, Ollama"
  node_name             = var.proxmox_node
  cores                 = 4
  memory                = 16384
  disk_size             = 400
  storage_pool          = "vm-fast"
  disk_interface        = "virtio0"
  cpu_type              = "host"
  bios_type             = "ovmf"
  bridge                = "vmbr0"
  vlan_id               = 50
  ip_address            = "10.10.50.10/24"
  gateway               = "10.10.50.1"
  ssh_public_key        = var.ssh_public_key
  tags                  = ["ai", "gpu", "ollama"]
  create_from_template  = false
  scsi_hardware         = "virtio-scsi-single"                                                                
  disk_iothread         = true                                                                                
  has_efi_disk          = true

  disk_format  = "qcow2"

  hostpci_devices = [
    {
      id     = "0000:2f:00"
      pcie   = true
      rombar = false
      xvga   = true
    }
  ]
}

# ---------------------------------------------------------------------------
# forge-dev — VMID 102
# Arch Linux + KDE Plasma 6, development workstation
# VLAN 30 (Development), 10.10.30.10
# ---------------------------------------------------------------------------

module "forge_dev" {
  source = "./modules/proxmox-vm"

  vm_id                 = 102
  name                  = "forge-dev"
  description           = "Development workstation — Arch Linux, KDE Plasma 6"
  node_name             = var.proxmox_node
  cores                 = 4
  memory                = 8192
  disk_size             = 150
  storage_pool          = "vm-fast"
  disk_interface        = "scsi0"
  cpu_type              = "host"
  bios_type             = "ovmf"
  bridge                = "vmbr0"
  vlan_id               = 30
  ip_address            = "10.10.30.10/24"
  gateway               = "10.10.30.1"
  ssh_public_key        = var.ssh_public_key
  cloud_init_password   = var.cloud_init_password
  tags                  = ["dev", "arch"]
  create_from_template  = true
  template_id           = 9001
  scsi_hardware         = "virtio-scsi-single"
  disk_iothread         = true
  disk_cache            = "writeback"
  has_efi_disk          = true
  disk_format           = "raw"
}

# ---------------------------------------------------------------------------
# forge-erp — VMID 103
# Ubuntu 24.04, ERPNext v16
# VLAN 20 (Production), 10.10.20.50
# ---------------------------------------------------------------------------

module "forge_erp" {
  source = "./modules/proxmox-vm"

  vm_id                 = 103
  name                  = "forge-erp"
  description           = "ERPNext v16 — BezaCore Labs LLC ERP"
  node_name             = var.proxmox_node
  cores                 = 2
  memory                = 4096
  disk_size             = 50
  storage_pool          = "vm-fast"
  disk_interface        = "scsi0"
  cpu_type              = "x86-64-v2-AES"
  bios_type             = "seabios"
  bridge                = "vmbr0"
  vlan_id               = 20
  ip_address            = "10.10.20.50/24"
  gateway               = "10.10.20.1"
  ssh_public_key        = var.ssh_public_key
  tags                  = ["erp", "production"]
  create_from_template  = false
  scsi_hardware         = "virtio-scsi-single"
  disk_iothread         = true
  disk_cache            = "writeback"
  disk_format           = "qcow2"
}

# ---------------------------------------------------------------------------
# forge-cortex — VMID 104 (net-new)
# Ubuntu 24.04, AI assistant host
# VLAN 50 (AI), 10.10.50.20
# ---------------------------------------------------------------------------

module "forge_cortex" {
  source = "./modules/proxmox-vm"

  vm_id          = 104
  name           = "forge-cortex"
  description    = "forge-cortex host — FastAPI, Neo4j, Qdrant, LiteLLM, Open WebUI"
  node_name      = var.proxmox_node
  cores          = 4
  memory         = 12288
  disk_size      = 64
  storage_pool   = "vm-fast"
  disk_interface = "scsi0"
  cpu_type       = "x86-64-v2-AES"
  bios_type      = "ovmf"
  bridge         = "vmbr0"
  vlan_id        = 50
  ip_address     = "10.10.50.20/24"
  gateway        = "10.10.50.1"
  ssh_public_key      = var.ssh_public_key
  cloud_init_password = var.cloud_init_password
  tags                = ["ai", "forge-cortex"]
}