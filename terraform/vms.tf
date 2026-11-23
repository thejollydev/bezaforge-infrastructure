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
  cores                = 8     # raised by hand in Proxmox and never declared; declared 2026-09-13 on the owner's instruction
  memory               = 32768 # 2026-09-13: 24576 -> 32768 for ComfyUI's Qwen-Image (#1188), whose release step moves a 14.4 GB model into RAM beside its 7.9 GB text encoder and exhausted 24 GB. Passthrough pins all of it on the host; takes effect on `qm reboot 101`
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

  # On demand since 2026-11-14 (#103): forge-arcade holds the card by default
  # and starts with the hypervisor; forge-ai is started by `scripts/gpu-handoff.sh ai`
  # when Ollama or ComfyUI is wanted. Starting both at boot would race for the card.
  # Power state is not reconciled after create (`ignore_changes = [started]`), so this
  # changes nothing about whether forge-ai is running now.
  on_boot = false
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
# VMID 104 — FREE
#
# Was forge-brizza (Brizza v1, retired 2026-08-30), released 2026-09-14 when
# v2 went to bare metal as forge-agents (BezaForge ADR 0011), which is
# absent from this file because it is not a Proxmox guest.
#
# Borrowed on 2026-10-09 for forge-agents-drill, the throwaway VM of the
# agent team's first restore drill, and destroyed the same day. The block
# for it is in docs/runbooks/dr-restore-drill.md, Drill G, which was retired
# with the agent team on 2026-10-21.
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
  cores       = 12
  cpu_type    = "host"
  memory      = 24576
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

  # Steady state (restored 2026-11-13, #103): no emulated display. The passthrough GPU
  # drives the real monitor, and the LG UltraFine keeps HPD + EDID asserted even while
  # switched to another input (verified 2026-07-31), so the guest always sees a real
  # 3840x2160 output for Sunshine to capture.
  #
  # "none" + x-vga=1 means there is NO Proxmox console. The shell is SSH (the key is baked
  # into the image), Sunshine is set up over SSH and its web UI, and play is a controller
  # over Moonlight. The USB keyboard/mouse test the August setup mode was waiting on was
  # skipped on 2026-11-13: desk play with keyboard and mouse stays unproven. For a
  # console again, set vga_type = "std" and hostpci_devices = [] (the 2026-08-02 setup
  # mode); demoting the card with xvga = false is not enough, because the session lands
  # on the AMD GPU and noVNC shows only a bare VT.
  vga_type = "none"

  tags = ["gaming", "gpu", "desktop"]

  # Uses the cluster resource mapping, NOT a raw PCI id: Proxmox refuses raw hostpci for
  # API-token auth ("only root can set 'hostpci0' config for non-mapped devices"), and a
  # root@pam token still counts as not-root. The mapping's path is 0000:2f:00 with no
  # function suffix, so both the GPU and its HDMI audio function come across — same as
  # forge-ai's raw id. Create it with:
  #   pvesh create /cluster/mapping/pci --id rx7900xt \
  #     --map 'node=forge-hypervisor,path=0000:2f:00,id=1002:744c,subsystem-id=1eae:7905,iommugroup=32'
  #
  # Holding the card in this config does not take it from forge-ai: Proxmox only claims it
  # when the VM starts, and refuses to start a second holder. scripts/gpu-handoff.sh moves
  # it between the two.
  hostpci_devices = [
    {
      mapping = "rx7900xt" # path 0000:2f:00 → GPU + its HDMI audio function
      pcie    = true
      rombar  = false
      xvga    = true # primary display; makes Proxmox ignore `vga` entirely
    }
  ]

  # Keyboard + mouse for the guest, for desk play only. Without them the guest has no
  # local input: x-vga=1 disables the Proxmox console, so input is SSH, Sunshine's web UI
  # and Moonlight. Left detached by default — see the 2026-09-27 marker below.
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
  # (Phase 2 went ahead on 2026-11-13 without the input test.)
  #
  # ⛔ DETACHED 2026-09-27 — this broke every backup of this VM for 48 nights.
  # A stopped VM is backed up by starting it paused with its full hardware, and
  # Proxmox refuses to start one whose mapped USB device is absent ("USB Mapping
  # invalid (hardware probably changed)"). Both receivers were unplugged from the
  # hypervisor around 2026-08-10, so the nightly job failed for VM 105 every night
  # until 2026-09-27, silently (#1285). The last good backup was 2026-08-09.
  #
  # Steady-state play is a controller over Moonlight, which needs neither receiver.
  # To try desk play, plug both receivers into the hypervisor, restore the two
  # entries below for that session, and remove them again afterwards. A VM
  # whose backups depend on a dongle staying plugged in will fail again the next
  # time one is borrowed.
  # The receivers are attached by hand as usb1 and usb2 (see the runbook *Gaming on
  # forge-arcade*); usb0 is the Bluetooth adapter below.
  #
  # Bluetooth for the DualSense (2026-11-14, #103): forge-hypervisor's onboard Intel
  # AX200, whose Bluetooth half is USB 8087:0029. Paired through the TV, stick input
  # reached the guest about 12 times a second; paired to the guest through this adapter
  # it arrives about 125 times a second from the couch. Nothing on the host uses
  # Bluetooth, so the guest has it permanently. Unlike the receivers it is soldered to
  # the motherboard and cannot be borrowed, so the missing-device failure above does not
  # apply. Mapping, created by hand as root like rx7900xt:
  #   pvesh create /cluster/mapping/usb --id ax200-bluetooth \
  #     --map 'node=forge-hypervisor,id=8087:0029'
  usb_devices = [
    { mapping = "ax200-bluetooth" } # usb0
  ]

  # Holds the card by default since 2026-11-14 (#103); forge-ai is on demand.
  #   started         — not reconciled after create, so this only ever mattered at creation.
  #   on_boot         — starts with the hypervisor; forge-ai has on_boot = false, so they
  #                     never race for the card.
  #   stop_on_destroy — a destroy stops the VM outright rather than waiting on a shutdown.
  started         = false
  on_boot         = true
  stop_on_destroy = true

  # The guest agent is on (2026-11-15). Bazzite now ships qemu-guest-agent, installed and
  # enabled in the image; it was off here because the image lacked it in August. Without
  # it, Proxmox's Shutdown and Reboot press the virtual power button, KDE answers with its
  # logout prompt, and with no mouse or keyboard in the living room nobody can click it,
  # so both time out ("VM quit/powerdown failed - got timeout"). With it, Proxmox shuts
  # the guest down through the agent and the desktop is never asked.
  #
  # ⚠️ The agent's virtio-serial channel only appears on a cold start. Apply this with
  # the VM stopped, then start it: applied to a running VM, bpg waits for an agent that
  # cannot answer until the next stop and start (the ~15-minute plan/apply hang).
  # Check with `qm agent 105 ping` on forge-hypervisor; no output means it answered.
  agent_enabled = true
}

