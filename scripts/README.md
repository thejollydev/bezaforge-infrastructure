# Scripts

Automation scripts for BezaForge infrastructure management.

> **Status:** In progress — scripts will be added as Phase 2 automation work proceeds.

## Planned Scripts

- `bootstrap-service.sh` — Initialize a new Docker service directory with standard structure
- `backup-verify.sh` — Verify ZFS snapshot integrity and test restore
- `cert-check.sh` — Check certificate expiry for all services
- `health-check.sh` — Quick status check across all services and VMs

Phase 2 will replace these with proper Ansible roles and Terraform modules.
