variable "vm_id" {
  description = "Proxmox VM ID"
  type        = number
}

variable "name" {
  description = "VM hostname"
  type        = string
}

variable "node_name" {
  description = "Proxmox node to deploy on"
  type        = string
}

variable "cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "memory" {
  description = "Memory in MB"
  type        = number
  default     = 2048
}

variable "balloon_minimum" {
  description = <<-EOT
    Minimum memory in MB for VirtIO ballooning (Proxmox 'floating'/balloon value).
    0 (default) = ballooning DISABLED, fixed allocation — REQUIRED for PCI-passthrough
    VMs (e.g. forge-ai), whose RAM must be pinned for DMA. Set a value < `memory` to
    attach the balloon device and let Proxmox reclaim down to this floor when host RAM
    pressure exceeds ~80%; below that pressure the guest keeps full `memory`. Also makes
    the Proxmox RAM gauge accurate. Set the floor >= the guest's real peak working set
    or the in-guest OOM killer may fire under pressure. Attaching/removing the device
    requires a VM reboot for the guest to (un)load virtio_balloon.
  EOT
  type        = number
  default     = 0
}

variable "disk_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 32
}

variable "storage_pool" {
  description = "Proxmox storage pool — no default, must be specified explicitly to prevent silent misplacement"
  type        = string
}

variable "bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag"
  type        = number
}

variable "ip_address" {
  description = "Static IP address with prefix (e.g. 10.10.50.20/24)"
  type        = string
}

variable "gateway" {
  description = "Default gateway"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for cloud-init"
  type        = string
}

variable "template_id" {
  description = "VMID of the cloud-init template to clone (ubuntu-26.04-cloud). Only used when create_from_template = true."
  type        = number
  default     = 9002
}

variable "tags" {
  description = "List of tags to apply to the VM"
  type        = list(string)
  default     = []
}

variable "description" {
  description = "VM description shown in Proxmox UI"
  type        = string
  default     = ""
}

variable "cpu_type" {
  description = "CPU type exposed to the VM (host or x86-64-v2-AES)"
  type        = string
  default     = "x86-64-v2-AES"
}

variable "disk_interface" {
  description = "Disk interface type (scsi0 or virtio0)"
  type        = string
  default     = "scsi0"
}

variable "bios_type" {
  description = "BIOS type: ovmf (UEFI) or seabios"
  type        = string
  default     = "ovmf"
}

variable "hostpci_devices" {
  description = <<-EOT
    List of PCI devices to pass through. Empty = no passthrough.

    Supply EITHER `id` (raw PCI path, e.g. "0000:2f:00" — omit the function to hand over
    every function of the device) OR `mapping` (the name of a Proxmox cluster resource
    mapping, e.g. "rx7900xt"). Not both.

    ⚠️ `id` CANNOT BE USED WITH AN API TOKEN. Proxmox rejects it with "only root can set
    'hostpci0' config for non-mapped devices" — and it counts a `root@pam!token` as
    not-root regardless of privilege separation, so this is not fixable by granting
    privileges. bpg documents the same constraint: `id` "requires the root username and
    password configured in the proxmox provider."

    Since this provider authenticates with `var.proxmox_api_token`, any NEWLY CREATED
    passthrough VM must use `mapping`. `id` survives here only because forge-ai predates
    Terraform and is managed as an import — the provider reads its hostpci but never
    creates it. Create mappings with:
      pvesh create /cluster/mapping/pci --id <name> --map 'node=...,path=...,id=vendor:device'
  EOT
  type = list(object({
    id      = optional(string)
    mapping = optional(string)
    pcie    = bool
    rombar  = bool
    xvga    = bool
  }))
  default = []
}

variable "usb_devices" {
  description = <<-EOT
    List of USB devices to pass through. Empty (default) = none.

    Only `mapping` (a cluster USB resource-mapping name) is supported — raw `host=`
    values are NOT usable with token auth. `check_usb_perm` in PVE::API2::Qemu dies with
    "only root can set 'usbN' config for real devices" unless the value is `spice` or a
    mapping, exactly mirroring the hostpci restriction (see `hostpci_devices`).

    Create mappings with:
      pvesh create /cluster/mapping/usb --id <name> --map 'node=<node>,id=<vendor:product>'
    Prefer id-only over a bus-port `path`: USB device enumeration shifts across reboots,
    so an id follows the device to whatever port it lands in.
  EOT
  type = list(object({
    mapping = string
    usb3    = optional(bool, false)
  }))
  default = []
}

variable "create_from_template" {
  description = "Set to true for new VMs (clones template), false for imported existing VMs"
  type        = bool
  default     = true
}

variable "scsi_hardware" {
  description = "SCSI controller type (virtio-scsi-single or virtio-scsi-pci)"
  type        = string
  default     = "virtio-scsi-pci"
}

variable "disk_iothread" {
  description = "Enable iothread for disk I/O performance (recommended with virtio-scsi-single)"
  type        = bool
  default     = false
}

variable "disk_cache" {
  description = "Disk cache mode (none, writeback, writethrough)"
  type        = string
  default     = "none"
}

variable "has_efi_disk" {
  description = "Whether the VM has an EFI disk (UEFI boot). Required for bios_type = ovmf."
  type        = bool
  default     = false
}

variable "cloud_init_datastore" {
  description = "Storage pool for the cloud-init drive"
  type        = string
  default     = "vm-fast"
}

variable "disk_format" {
  description = "Disk file format (raw for new VMs, qcow2 for imported VMs with existing disks)"
  type        = string
  default     = "raw"
}

variable "cloud_init_password" {
  description = "Password for the cloud-init user account"
  type        = string
  sensitive   = true
  default     = ""
}

variable "vga_type" {
  description = "Virtual VGA card. 'std' (default) gives a 16 MB stdvga sufficient for GDM/X11 on Linux guests; 'none' for true headless VMs that won't run a desktop session. Other valid values: qxl, qxl2-4, vmware, virtio, virtio-gl, serial0-3."
  type        = string
  default     = "std"
}

variable "vga_memory" {
  description = "VGA memory in MB. 16 is the Proxmox default for std/qxl and works for a desktop session."
  type        = number
  default     = 16
}

variable "disk_import_from" {
  description = <<-EOT
    Proxmox volume ID of a pre-built disk image to import as the root disk, in the form
    `<datastore>:import/<file>.qcow2` (the datastore must carry the `import` content type;
    `local` does). Empty (default) = Proxmox creates a blank disk, the behaviour every
    existing VM here relies on.

    For VMs whose OS is built OUTSIDE Proxmox rather than cloned from the cloud-init
    template — e.g. the Bazzite gaming VM (#103), whose qcow2 comes from
    bootc-image-builder. Set `disk_format = "qcow2"` alongside it.

    Create-time only, and safe: bpg declares it `ForceNew: false` with "changes after
    creation are ignored", and the provider knows PVE never returns `import-from` on read
    (see disk.go). So unlike the `clone` block, this needs NO `ignore_changes` guard and
    will not silently schedule a destroy/recreate on a later apply.

    `size` may be set alongside it to grow the disk past the image's native size — that is
    the upstream-sanctioned pattern (see the provider's own centos-qcow2 example).
  EOT
  type        = string
  default     = ""
}

variable "started" {
  description = <<-EOT
    Whether Terraform keeps this VM running. True (default) matches bpg's own default and
    every VM here today.

    Set FALSE for a VM that must not be powered on automatically — notably the gaming VM
    (#103), which competes for the RX 7900 XT with forge-ai. With the default, `apply`
    would try to start it the moment it is created, while forge-ai still holds the card.
  EOT
  type        = bool
  default     = true
}

variable "on_boot" {
  description = <<-EOT
    Whether Proxmox starts this VM when the hypervisor boots. True (default) matches bpg's
    default and the always-on fleet.

    Set FALSE for occasional-use VMs that contend for a passthrough device — otherwise the
    gaming VM would race forge-ai for the GPU on every single host reboot.
  EOT
  type        = bool
  default     = true
}

variable "stop_on_destroy" {
  description = <<-EOT
    Whether `destroy` hard-stops the VM instead of requesting a graceful shutdown.
    False (default) = graceful, which RELIES ON THE GUEST AGENT and will hang without it.

    Set TRUE for any guest without qemu-guest-agent (bpg's own cloud-image example carries
    exactly this caveat). Pairs with `agent_enabled = false`.
  EOT
  type        = bool
  default     = false
}

variable "agent_enabled" {
  description = <<-EOT
    Whether Proxmox should expect the QEMU guest agent in this VM. True (default) matches
    every cloud-init VM here, which bakes the agent into template 9002.

    Set FALSE for any guest that does not ship qemu-guest-agent. Terraform does not merely
    lose the guest's IP — bpg BLOCKS waiting for an agent that never answers, which is the
    documented ~15-minute `plan`/`apply` hang (see the ubuntu-26.04 template notes; the
    agent must be baked before `qm template` for exactly this reason).
  EOT
  type        = bool
  default     = true
}
