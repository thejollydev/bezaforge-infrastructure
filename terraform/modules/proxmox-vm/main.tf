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
    enabled = true
  }

  bios    = var.bios_type
  machine = "q35"

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id  = var.storage_pool
    interface     = var.disk_interface
    size          = var.disk_size
    discard       = "on"
    file_format   = var.disk_format
    iothread      = var.disk_iothread
    cache         = var.disk_cache
  }

  network_device {
    bridge  = var.bridge
    vlan_id = var.vlan_id
    model   = "virtio"
  }

  operating_system {
    type = "l26"
  }

  dynamic "hostpci" {
    for_each = var.hostpci_devices
    content {
      device = "hostpci${hostpci.key}"
      id     = hostpci.value.id
      pcie   = hostpci.value.pcie
      rombar = hostpci.value.rombar
      xvga   = hostpci.value.xvga
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
    ignore_changes = [initialization]
  }
}
