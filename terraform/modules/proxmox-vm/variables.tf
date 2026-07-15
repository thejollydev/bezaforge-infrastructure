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
  description = "List of PCI devices to pass through. Empty = no passthrough."
  type = list(object({
    id     = string
    pcie   = bool
    rombar = bool
    xvga   = bool
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
