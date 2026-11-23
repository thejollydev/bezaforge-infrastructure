# ---------------------------------------------------------------------------
# forge-files — CTID 104
# Debian 13 LXC, File Browser Quantum (the web view of the file share, #49)
# VLAN 20 (Production), 10.10.20.60
#
# The fleet's first container. It exists to keep a web login off the
# hypervisor itself while still reading the share's files directly: the
# share (and its live Google Drive mount) is bind-mounted in from the host,
# so there is no SMB or NFS hop.
#
# ⚠️ Terraform owns the container, NOT its bind mounts or its ID mapping.
# Proxmox only lets root@pam set bind mounts and raw lxc.* keys, and an API
# token never counts as root@pam (the same rule forge-arcade's hostpci hit).
# roles/forge-files-host, run on the hypervisor, writes both into
# /etc/pve/lxc/104.conf and restarts the container when they change. The
# `lifecycle` block below keeps an apply from undoing that work.
#
# Created stopped on purpose: the ID mapping has to be in place before the
# container's first boot, so roles/forge-files-host starts it.
# ---------------------------------------------------------------------------

resource "proxmox_download_file" "debian_13_lxc" {
  node_name    = var.proxmox_node
  datastore_id = "local"
  content_type = "vztmpl"
  url          = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
  # From Proxmox's own appliance index (pveam), so a corrupted or replaced
  # download fails here instead of becoming a container.
  checksum           = "4c0c27ca6ceab5ef0b84db57825a00f26157ef1854bafe97297813e1cbe8ecb8cc9c453cab6b3b0efe1ba193a50c47ece1e41d950e411b8730b835b71e9e754b"
  checksum_algorithm = "sha512"
}

resource "proxmox_virtual_environment_container" "forge_files" {
  node_name    = var.proxmox_node
  vm_id        = 104
  description  = "File Browser Quantum — web view of the file share"
  tags         = ["files", "web"]
  unprivileged = true

  # systemd in an unprivileged Debian 13 container needs nesting.
  features {
    nesting = true
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 1024
    swap      = 512
  }

  disk {
    datastore_id = "vm-fast"
    size         = 8
  }

  operating_system {
    template_file_id = proxmox_download_file.debian_13_lxc.id
    type             = "debian"
  }

  initialization {
    hostname = "forge-files"

    # The same two internal-aware resolvers every guest uses
    # (roles/dns-client's defaults): AdGuard on forge-ops, then the
    # hypervisor's dnsmasq backstop. Proxmox writes these into the
    # container's resolv.conf, which is why this host runs no dns-client.
    dns {
      domain  = "bezaforge.dev"
      servers = ["10.10.20.20", "10.10.10.10"]
    }

    ip_config {
      ipv4 {
        address = "10.10.20.60/24"
        gateway = "10.10.20.1"
      }
    }

    # Root only, by key, like forge-hypervisor. No password is set.
    user_account {
      keys = [var.ssh_public_key]
    }
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr0"
    vlan_id = 20
  }

  started       = false
  start_on_boot = true

  lifecycle {
    # mount_point and idmap: written by roles/forge-files-host as raw lxc.*
    # lines, which only root@pam may set (see the header).
    # started: power state is the hypervisor role's job after create, as it
    # is for the VMs (`ignore_changes = [started]` in modules/proxmox-vm).
    # initialization: create-time only, as for the VMs.
    ignore_changes = [mount_point, idmap, started, initialization]
  }
}
