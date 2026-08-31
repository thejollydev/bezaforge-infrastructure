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
# forge-brizza — VMID 104 — RETIRED 2026-08-30, IDENTITY RESERVED
#
# Brizza v1 was torn down whole (VM, Hermes agent, brizza-postgres on
# forge-ops, the Ollama fallback model on forge-ai, the ~/.hermes
# backups). The module is removed rather than commented out, because a
# commented module is not state — Terraform would still have destroyed
# the VM on the next apply either way, and dead HCL only invites someone
# to uncomment a v1 shape into a v2 world.
#
# ⚠️ VMID 104, 10.10.50.20 and forge-brizza.bezaforge.dev are RESERVED,
# not freed — Brizza v2 is being built and will take them. Same
# treatment as forge-dev (VMID 102). Do not hand any of the three to
# another host.
#
# v2 will not be a copy of this: the shape under discussion is multiple
# Hermes clients or an agent swarm, possibly orchestrated from the
# laptop, so its resources (4 cores / 16 GB / 100 GB here) should be
# sized against that design rather than inherited from this one.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# forge-arcade — VMID 105
# Bazzite (KDE desktop image) gaming VM, RX 7900 XT passthrough
# VLAN 40 (Home), DHCP — same subnet as the living-room TV
#
# VARIANT DECISION (2026-08-02): plain `bazzite`, NOT `bazzite-deck`. The deck image is
# documented as "intended for controller-oriented setups" and boots straight into Steam
# Game Mode, whose first-run wizard cannot be driven without a controller — it deadlocked
# setup here. Controller play does NOT depend on it: every Bazzite variant ships Steam +
# Proton + Sunshine, and Moonlight forwards controller input over the network. If Game
# Mode is ever wanted, rebasing is officially supported and reversible:
#   rpm-ostree rebase ostree-image-signed:docker://ghcr.io/ublue-os/bazzite-deck:stable
# (Don't rebase across desktop environments; both of these are KDE, so that's fine.)
#
# ⚠️ MUTUALLY EXCLUSIVE WITH forge-ai (101): both declare hostpci 0000:2f:00.
# Proxmox happily holds both *configs*, but only one may RUN at a time. Hand the
# card over by shutting forge-ai down first. Proven safe end-to-end 2026-07-31
# (#103): forge-ai → release → another VM → release → forge-ai, no host reboot.
# Proxmox logs "Inappropriate ioctl for device" on every start — BENIGN, vfio-pci
# then does its own secondary-bus reset. Do not chase it.
#
# Provisioning shape differs from every other VM here: Bazzite is an atomic bootc
# image with no cloud-init, so it is NOT cloned from template 9002. The root disk is
# a qcow2 seed built by bootc-image-builder from ghcr.io/ublue-os/bazzite-deck:stable
# and staged to local:import/. The disk is only a seed — the OS updates itself from
# the registry via bootc, so this is not a hand-built pet.
# ---------------------------------------------------------------------------

module "forge_arcade" {
  source = "./modules/proxmox-vm"

  vm_id       = 105
  name        = "forge-arcade"
  description = "Bazzite gaming VM — RX 7900 XT (mutually exclusive with forge-ai); Sunshine → Moonlight on the living-room TV"
  node_name   = var.proxmox_node
  cores       = 8
  cpu_type    = "host"
  memory      = 16384
  # balloon_minimum intentionally omitted → module default 0 = ballooning DISABLED.
  # Required for PCI passthrough: the guest's RAM must be pinned for DMA.

  disk_size      = 250
  storage_pool   = "vm-fast"
  disk_interface = "scsi0"
  scsi_hardware  = "virtio-scsi-single"
  disk_iothread  = true
  disk_format    = "qcow2"
  # Import the pre-built Bazzite seed instead of creating a blank disk. `size` above
  # grows it past the image's native size in the same step — the upstream-sanctioned
  # pattern (bpg's own centos-qcow2 example sets import_from + size together).
  disk_import_from = "local:import/bazzite-stable-2026-08-02.qcow2"

  bios_type    = "ovmf"
  has_efi_disk = true

  bridge  = "vmbr0"
  vlan_id = 40
  # ⚠️ INERT for this VM: the module only emits an `initialization` (cloud-init) block
  # when create_from_template = true. Bazzite has no cloud-init, so these two values
  # are documentation, not configuration — the guest takes DHCP from the VLAN 40 pool
  # (10.10.40.100-250). Add an Omada reservation if a stable address is wanted.
  # Source of truth for this subnet: design/ip-allocation.md.
  ip_address     = "10.10.40.105/24"
  gateway        = "10.10.40.1"
  ssh_public_key = var.ssh_public_key # also inert without cloud-init; the key is baked
  # into the image by bootc-image-builder's config.toml.

  create_from_template = false

  # ⚠️ TEMPORARY — SETUP MODE (2026-08-02). Flip both this and hostpci xvga back before
  # this VM is considered done; see the marker on hostpci_devices below.
  #
  # Steady state is vga_type = "none": the passthrough GPU drives the real monitor, and
  # the LG UltraFine keeps HPD + EDID asserted even while switched to another input
  # (verified 2026-07-31), so the guest always sees a real 3840x2160 output.
  #
  # But "none" + x-vga=1 means there is NO Proxmox console, which made first-run setup
  # depend entirely on USB passthrough — and the passed-through Logitech receivers reach
  # QEMU (they appear in `info usb`) yet produce no input in the guest. Rather than debug
  # that blind, with no shell, run setup on an emulated display so noVNC gives a reliable
  # keyboard and mouse; then restore the steady state and debug USB with SSH available.
  vga_type = "std"

  tags = ["gaming", "gpu", "desktop"]

  # Uses the cluster resource mapping, NOT a raw PCI id: Proxmox refuses raw hostpci for
  # API-token auth ("only root can set 'hostpci0' config for non-mapped devices"), and a
  # root@pam token still counts as not-root. The mapping's path is 0000:2f:00 with no
  # function suffix, so both the GPU and its HDMI audio function come across — same as
  # forge-ai's raw id. Create it with:
  #   pvesh create /cluster/mapping/pci --id rx7900xt \
  #     --map 'node=forge-hypervisor,path=0000:2f:00,id=1002:744c,subsystem-id=1eae:7905,iommugroup=32'
  # ⚠️ TEMPORARY — SETUP MODE (2026-08-02): GPU fully detached.
  # Demoting it (xvga = false) was not enough: with a real card present and a live EDID on
  # the LG, the graphical session lands on the AMD GPU and noVNC shows only a bare VT.
  # Removing it leaves exactly ONE display, so noVNC is guaranteed — and KDE runs fine on
  # the emulated adapter, unlike gamescope, which needs Vulkan.
  # It also means **forge-ai keeps the card and stays up** through the whole install.
  # STEADY STATE (restore together with usb_devices above and vga_type = "none"):
  #   hostpci_devices = [
  #     {
  #       mapping = "rx7900xt" # path 0000:2f:00 → GPU + its HDMI audio function
  #       pcie    = true
  #       rombar  = false
  #       xvga    = true       # primary display; makes Proxmox ignore `vga` entirely
  #     }
  #   ]
  hostpci_devices = []

  # Keyboard + mouse for the guest. WITHOUT THIS THE VM HAS NO INPUT DEVICE AT ALL:
  # x-vga=1 makes the passthrough card primary, which disables the Proxmox console, so
  # there is no other way to type into the guest before Sunshine is configured.
  #
  # BOTH receivers are required — the peripherals are split across them:
  #   logi-bolt     046d:c548  → MX Keys S keyboard
  #   logi-unifying 046d:c52b  → M510 mouse
  # Determined by raw event capture on 2026-08-02, NOT by device name: while typing and
  # moving the mouse, event2 (Bolt kbd iface) took 1728 B and event6 (M510) 23952 B, while
  # event7 — the node the kernel calls "Logitech K350" — took ZERO. hid-logitech-dj
  # materialises an input node for every slot in a Unifying receiver's stored pairing
  # table, so that K350 is a phantom for hardware no longer in use. Never identify these
  # by name; capture events.
  #
  # This also removes a real hazard: on 2026-08-02 the keyboard was still bound to the
  # HOST while the guest displayed Steam's "connect a keyboard" wizard, so a Ctrl+Alt+Del
  # aimed at the guest hit the Proxmox console instead and rebooted the hypervisor.
  # ⚠️ While VM 105 runs the host has NO local input; administer it over SSH.
  # ✅ RESTORED 2026-08-04 (#103) — phase 1 of 2, deliberately ahead of the GPU.
  #
  # These are restored while `hostpci_devices` stays empty and `vga_type` stays "std",
  # which is the whole point: whether USB passthrough delivers input to this guest is the
  # one genuinely UNPROVEN thing left (on 2026-08-02 both receivers reached QEMU — they
  # appeared in `info usb` — yet produced nothing in the guest). The GPU half is already
  # proven, so restoring both at once would change two variables against one symptom, and
  # would do it in the exact configuration that has NO console.
  #
  # Restoring USB alone keeps three things true while that unknown is settled:
  #   - noVNC still works (vga_type = "std")            → fallback input
  #   - SSH still works (10.10.40.x, DHCP)              → fallback shell
  #   - forge-ai keeps the card                         → NO Ollama outage while debugging
  # Once input is confirmed in-guest, phase 2 restores hostpci + vga_type = "none".
  usb_devices = [
    { mapping = "logi-bolt" },    # usb0 — MX Keys S keyboard
    { mapping = "logi-unifying" } # usb1 — M510 mouse
  ]

  # Occasional-use + contends for the GPU, so all three differ from the fleet default:
  #   started         — do NOT power on at apply; forge-ai still holds the card.
  #   on_boot         — do NOT autostart with the hypervisor, or it races forge-ai every reboot.
  #   stop_on_destroy — graceful shutdown needs the guest agent, which this image lacks.
  started         = false
  on_boot         = false
  stop_on_destroy = true

  # Bazzite ships no qemu-guest-agent. Leaving this true makes bpg block waiting for an
  # agent that never answers — the documented ~15-minute plan/apply hang. Flip to true
  # only after `qm agent 105 ping` actually answers.
  agent_enabled = false
}

