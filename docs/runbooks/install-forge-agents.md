# Runbook — Install forge-agents (the M920Q) from scratch

Wipes the Lenovo ThinkCentre M920Q (formerly `forge-k3s-worker`) and installs
Ubuntu Server 26.04 LTS as **forge-agents**, the Brizza agent team's host, at
**10.10.50.20 on VLAN 50 (AI)**. Decided 2026-09-14: Brizza ADR 0018 and
BezaForge ADR 0011 (vault).

Everything here is done by Joseph at the machine or from the laptop. Nothing
on the old install is kept: it is a Proxmox VE 9.2 that was never used and
never reachable.

---

## Before you start

- [ ] An 8 GB or larger USB stick you can erase.
- [ ] A monitor and keyboard on the M920Q (it has no remote console).
- [ ] The laptop on the network, with `~/.ssh/id_ed25519.pub` (the key every
      managed host trusts for `joseph`).

### 1. Re-profile gateway port 4 in Omada

The M920Q is on **ER7412-M2 port 4**. Its old profile was for the K3s plan
(native VLAN Management, 10). Change it in the Omada controller UI **before**
installing, or the installer's network step will land on the wrong VLAN, which
is exactly how the old Proxmox install became invisible.

- Devices → ER7412-M2 → Ports → port 4 → profile with **native VLAN AI (50)**,
  no tagged VLANs.
- Omada is hand-managed by design (#122); there is nothing to commit for this
  step. Note the change in the vault's `ip-allocation.md` port map afterwards.

### 2. Write the installer USB (laptop)

```bash
cd ~/Downloads && curl -LO https://releases.ubuntu.com/26.04/ubuntu-26.04.1-live-server-amd64.iso && curl -LO https://releases.ubuntu.com/26.04/SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS
```

Find the stick (`lsblk`; it is the removable one, **not** an nvme device),
then, with `sdX` replaced:

```bash
sudo dd if=~/Downloads/ubuntu-26.04.1-live-server-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

If a newer 26.04.x point release exists, use it; the steps do not change.

---

## Install

### 3. Boot the USB

Power on with the stick inserted and press **F12** for the boot menu (**F1**
enters Setup if you need it: UEFI boot on, Secure Boot may stay on, Ubuntu
supports it). Pick the USB's UEFI entry.

### 4. Walk the installer

| Screen | Choose |
|---|---|
| Language, keyboard | English (US) |
| Type of install | **Ubuntu Server** (not minimized) |
| Network | Select the wired interface (`enp0s31f6` on this model, but read it off the screen), **Edit IPv4 → Manual**: subnet `10.10.50.0/24`, address `10.10.50.20`, gateway `10.10.50.1`, name servers `10.10.20.20,10.10.10.10`, search domain `bezaforge.dev`. Leave IPv6 automatic. |
| Proxy | none |
| Mirror | default |
| Storage | **Use an entire disk**, the 256 GB NVMe. Leave LVM on. Then on the summary screen edit `ubuntu-lv` and set its size to the **maximum**; the default leaves half the disk unallocated. Confirm the destructive action: this is the wipe. |
| Profile | Your name `Joseph`, server name **`forge-agents`**, username **`joseph`**, a password you will keep (sudo needs it until Ansible runs). |
| Ubuntu Pro | skip |
| SSH | **Install OpenSSH server**, import identity **from GitHub**, username `thejollydev`. Allow password auth over SSH: **no**. |
| Snaps | none |

When it says *Install complete*, remove the stick and **Reboot Now**.

### 5. First contact (laptop)

The old K3s addresses left stale host keys; clear them first.

```bash
ssh-keygen -R 10.10.50.20; ssh-keygen -R forge-agents.bezaforge.dev; ssh-keygen -R 10.10.10.30; ssh-keygen -R 10.10.20.30
```

```bash
ssh joseph@10.10.50.20 'hostnamectl hostname; ip -br addr; resolvectl status | grep -A3 "Link.*enp"; df -h /'
```

Expect the hostname `forge-agents`, `10.10.50.20/24` on the wired interface,
DNS `10.10.20.20`, and a root filesystem near the full disk. If the host does
not answer, it is almost always port 4's VLAN (step 1); check the Omada client
list before touching the install.

---

## After the install

Nothing else is done by hand. The rest is the Ansible role and the build
plan, in this order:

1. Inventory PR: `forge-agents` under `assistant_hosts` in `hosts.yml`, its
   `host_vars`, the DNS rewrite renamed from `forge-brizza` to `forge-agents`
   (→ 10.10.50.20), the terraform reservation comment closed, VMID 104
   released.
2. `ansible-playbook site.yml --limit forge-agents` for the base roles.
   **Merged is not deployed**: the run is the deployment, and its output is
   the proof.
3. The team runtime role (Hermes profiles, Never4gA, Syncthing, backups),
   per the Brizza build plan.

## Rollback

None needed. Until step 4's storage confirmation the disk is untouched; after
it, there is nothing on the machine anyone wants back.
