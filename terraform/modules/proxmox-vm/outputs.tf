output "vm_id" {
  description = "Proxmox VM ID"
  value       = proxmox_virtual_environment_vm.vm.vm_id
}

output "ip_address" {
  description = "VM IP address"
  value       = var.ip_address
}