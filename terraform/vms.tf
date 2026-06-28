# ---------------------------------------------------------------------------
# forge-ai — VMID 101
# Ubuntu 26.04, RX 7900 XT GPU passthrough, ROCm + Ollama
# VLAN 50 (AI), 10.10.50.10
# ---------------------------------------------------------------------------

module "forge_ai" {
  source = "./modules/proxmox-vm"

  vm_id                = 101
  name                 = "forge-ai"
  description          = "GPU inference host — ROCm, Ollama"
  node_name            = var.proxmox_node
  cores                = 4
  memory               = 8192 # 2026-06-21 rebalance: was 16384 — forge-ai uses ~1 GiB system RAM (LLM weights live in the 20 GiB VRAM)
  disk_size            = 400
  storage_pool         = "vm-fast"
  disk_interface       = "virtio0"
  cpu_type             = "host"
  bios_type            = "ovmf"
  bridge               = "vmbr0"
  vlan_id              = 50
  ip_address           = "10.10.50.10/24"
  gateway              = "10.10.50.1"
  ssh_public_key       = var.ssh_public_key
  tags                 = ["ai", "gpu", "ollama"]
  vga_type             = "none" # headless — no Proxmox console rendering, SSH only
  create_from_template = false
  scsi_hardware        = "virtio-scsi-single"
  disk_iothread        = true
  has_efi_disk         = true

  disk_format = "qcow2"

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
# forge-erp — VMID 103
# Ubuntu 26.04, ERPNext v16
# VLAN 20 (Production), 10.10.20.50
# ---------------------------------------------------------------------------

module "forge_erp" {
  source = "./modules/proxmox-vm"

  vm_id       = 103
  name        = "forge-erp"
  description = "ERPNext v16 — BezaCore Labs LLC ERP"
  node_name   = var.proxmox_node
  cores       = 2
  memory      = 8192 # 2026-06-21: 4096→8192 — ERPNext (MariaDB + gunicorn workers) was RAM-tight now it holds BCL financial data
  # FORGE-83: enable ballooning (no passthrough). Reclaim 8192→4096 under host
  # pressure (>80%); floor 4096 covers MariaDB buffer pool + gunicorn peak so the
  # guest OOM killer never fires. Also makes the Proxmox RAM gauge accurate.
  balloon_minimum = 4096
  disk_size       = 50
  storage_pool    = "vm-fast"
  disk_interface  = "scsi0"
  cpu_type        = "x86-64-v2-AES"
  bios_type       = "seabios"
  bridge          = "vmbr0"
  vlan_id         = 20
  ip_address      = "10.10.20.50/24"
  gateway         = "10.10.20.1"
  ssh_public_key  = var.ssh_public_key
  tags            = ["erp", "production"]
  # vga_type omitted intentionally — inherits module default "std", which matches
  # forge-erp's effective current Proxmox state (vga unset on Proxmox = std default).
  create_from_template = false
  scsi_hardware        = "virtio-scsi-single"
  disk_iothread        = true
  disk_cache           = "writeback"
  disk_format          = "qcow2"
}

# ---------------------------------------------------------------------------
# forge-brizza — VMID 104
# Ubuntu 26.04, Brizza AI assistant (Hermes Agent bridge; LangGraph graduation planned)
# VLAN 50 (AI), 10.10.50.20
# ---------------------------------------------------------------------------

module "forge_brizza" {
  source = "./modules/proxmox-vm"

  vm_id       = 104
  name        = "forge-brizza"
  description = "Brizza AI assistant — Hermes Agent bridge (Discord + dashboard)"
  node_name   = var.proxmox_node
  cores       = 4
  memory      = 16384
  # FORGE-83: enable ballooning (no passthrough). Reclaim 16384→4096 under host
  # pressure; floor 4096 is generous for the lightly-loaded Hermes bridge (could
  # be lowered for more reclaim). Makes the Proxmox RAM gauge accurate too.
  balloon_minimum     = 4096
  disk_size           = 100
  storage_pool        = "vm-fast"
  disk_interface      = "scsi0"
  cpu_type            = "x86-64-v2-AES"
  bios_type           = "ovmf"
  bridge              = "vmbr0"
  vlan_id             = 50
  ip_address          = "10.10.50.20/24"
  gateway             = "10.10.50.1"
  ssh_public_key      = var.ssh_public_key
  cloud_init_password = var.cloud_init_password
  tags                = ["ai", "brizza"]
}

