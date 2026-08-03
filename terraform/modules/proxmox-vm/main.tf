terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  vm_id               = var.vm_id
  name                = var.name
  description         = var.description
  node_name           = var.node_name
  tags                = var.tags
  scsi_hardware       = var.scsi_hardware
  reboot_after_update = false

  # All three default to bpg's own defaults, so declaring them is a no-op for the
  # existing fleet. They exist for passthrough-contending / agentless guests — see
  # each variable's description.
  started         = var.started
  on_boot         = var.on_boot
  stop_on_destroy = var.stop_on_destroy

  dynamic "clone" {
    for_each = var.create_from_template ? [1] : []
    content {
      vm_id = var.template_id
      full  = true
    }
  }

  dynamic "efi_disk" {
    for_each = var.has_efi_disk ? [1] : []
    content {
      datastore_id      = var.storage_pool
      type              = "4m"
      pre_enrolled_keys = false
    }
  }

  agent {
    enabled = var.agent_enabled
  }

  bios    = var.bios_type
  machine = "q35"

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory
    # floating < dedicated → balloon device + reclaim to this floor under host
    # pressure. 0 → ballooning disabled (fixed; required for passthrough VMs).
    floating = var.balloon_minimum
  }

  disk {
    datastore_id = var.storage_pool
    interface    = var.disk_interface
    size         = var.disk_size
    discard      = "on"
    file_format  = var.disk_format
    iothread     = var.disk_iothread
    cache        = var.disk_cache
    # "" is the provider's own default and passes validation (validators.FileID
    # skips empty), so this is a no-op for every VM that doesn't set it.
    import_from = var.disk_import_from
  }

  network_device {
    bridge  = var.bridge
    vlan_id = var.vlan_id
    model   = "virtio"
  }

  vga {
    type   = var.vga_type
    memory = var.vga_memory
  }

  operating_system {
    type = "l26"
  }

  dynamic "usb" {
    for_each = var.usb_devices
    content {
      mapping = usb.value.mapping
      usb3    = usb.value.usb3
    }
  }

  dynamic "hostpci" {
    for_each = var.hostpci_devices
    content {
      device = "hostpci${hostpci.key}"
      # Exactly one of these is set; the other is null and omitted. `id` only works
      # for root+password auth, so token-authenticated creates must use `mapping`.
      id      = hostpci.value.id
      mapping = hostpci.value.mapping
      pcie    = hostpci.value.pcie
      rombar  = hostpci.value.rombar
      xvga    = hostpci.value.xvga
    }
  }

  dynamic "initialization" {
    for_each = var.create_from_template ? [1] : []
    content {
      datastore_id = var.cloud_init_datastore
      ip_config {
        ipv4 {
          address = var.ip_address
          gateway = var.gateway
        }
      }
      user_account {
        username = "joseph"
        password = var.cloud_init_password
        keys     = [var.ssh_public_key]
      }
    }
  }

  lifecycle {
    # `clone` and `initialization` are create-time-only blocks. Terraform applies
    # them when the VM is first built, but Proxmox doesn't round-trip them cleanly,
    # and their attributes are force-replacement. Ignoring drift on both lets a
    # once-cloned VM (e.g. forge-brizza) be re-declared create_from_template=false
    # — and lets the template_id default move — without destroying the live VM.
    # `started` is deliberately NOT reconciled after create. Power state here is an
    # OPERATIONAL fact, not a declarative one: the RX 7900 XT is mutually exclusive
    # between forge-ai and forge-arcade, so handing the card over means stopping one VM
    # by hand. Without this, the next `apply` reads that stop as drift and powers the VM
    # back on — which is exactly what happened 2026-08-02: an apply restarted forge-ai
    # mid-handoff and VM 105 then failed to start because the GPU was taken.
    # Terraform still sets the initial state at create (`started = false` for 105).
    ignore_changes = [initialization, clone, started]
  }
}
