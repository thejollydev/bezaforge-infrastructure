# Runbook — Install forge-agents (the M920Q) from scratch

Wipes the Lenovo ThinkCentre M920Q (formerly `forge-k3s-worker`) and installs
Ubuntu Server 26.04 LTS as **forge-agents**, the Brizza agent team's host, at
**10.10.50.20 on VLAN 50 (AI)**, then brings it under Ansible. Decided
2026-09-14: Brizza ADR 0018 and BezaForge ADR 0011 (the host).

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
| Network | Select the wired interface (it showed as `eno2` on this machine, altname `enp0s31f6`; read it off the screen), **Edit IPv4 → Manual**: subnet `10.10.50.0/24`, address `10.10.50.20`, gateway `10.10.50.1`, name servers `10.10.20.20,10.10.10.10`, search domain `bezaforge.dev`. Leave IPv6 automatic. |
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
ssh joseph@10.10.50.20 'hostnamectl hostname; ip -br addr; resolvectl dns; df -h /'
```

Expect the hostname `forge-agents`, `10.10.50.20/24` on the wired interface,
DNS `10.10.20.20`, and a root filesystem near the full disk. If the host does
not answer, it is almost always port 4's VLAN (step 1); check the Omada client
list before touching the install.

---

## Bring it under Ansible (build step 2, #1215)

The pull request puts forge-agents in the inventory (`assistant_hosts`,
`host_vars/forge-agents.yml`) with its own `site.yml` play, renames the DNS
record from `forge-brizza` to `forge-agents`, releases VMID 104, adds the
Prometheus target, and adds sanoid and restic entries for a backup dataset.
**Merged is not deployed**: each run below is the deployment, and its output
is the proof. Run them from the laptop in this order, on a pulled `main`.

Done when the forge-agents play is idempotent on a second run, Prometheus
scrapes the host, Uptime Kuma sees it, and the dataset exists with its policy.

Every `ansible-playbook` command below prompts for passwords, so it needs your
own terminal.

### 6. Select classic sudo on forge-agents (once)

Ubuntu 26.04 makes sudo-rs the default, and no released ansible-core can drive
it (FORGE-36, see `roles/common`). `common` keeps classic sudo selected from
then on, but the first run cannot escalate far enough to select it. It prompts
for your password:

```bash
ssh -t joseph@10.10.50.20 'sudo update-alternatives --set sudo /usr/bin/sudo.ws && readlink -f /usr/bin/sudo'
```

Expect `/usr/bin/sudo.ws`.

### 7. Create the backup dataset (forge-hypervisor)

Every bezapool dataset is created by hand. This one is root-only (`0700`, where
the other backup datasets are `755`) because the nightly archive it will hold
carries the agents' credentials. It is not shared: bezapool has
`sharenfs=off`, and no `/etc/exports` stanza is added. Create it **before**
step 9, because sanoid errors on a dataset it cannot find.

```bash
ssh root@10.10.10.10 'zfs create bezapool/forge-agents-backup && chmod 0700 /bezapool/forge-agents-backup && zfs get -H -o property,value compression,sharenfs,mountpoint bezapool/forge-agents-backup && stat -c "%U:%G %a" /bezapool/forge-agents-backup'
```

Expect `lz4`, `off`, `/bezapool/forge-agents-backup`, then `root:root 700`.

### 8. DNS: the record follows the name

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && ansible-playbook site.yml -l forge-ops,forge-hypervisor --tags adguard,dnsmasq --ask-become-pass --ask-vault-pass
```

dnsmasq's file is rendered whole, so `forge-brizza` leaves it. AdGuard is
different: the `adguard` role adds `forge-agents` but **prunes nothing unless
told to**, so the old `forge-brizza` rewrite stays. Read the role's *rewrite
reconciliation plan* output. If `forge-brizza.bezaforge.dev` is the only
unmanaged extra, remove it:

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && ansible-playbook site.yml -l forge-ops --tags adguard -e adguard_rewrites_prune=true --ask-become-pass --ask-vault-pass
```

If the plan lists anything else, stop and look first: pruning deletes every
extra it lists. Then check both resolvers agree:

```bash
dig +short forge-agents.bezaforge.dev @10.10.20.20; dig +short forge-agents.bezaforge.dev @10.10.10.10; ~/Projects/bezaforge-infrastructure/scripts/dns-parity-check.sh
```

Expect `10.10.50.20` twice and the parity check passing.

### 9. Backup policy (forge-hypervisor)

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && ansible-playbook site.yml -l forge-hypervisor --tags sanoid,restic-gcs --ask-vault-pass
```

```bash
ssh root@10.10.10.10 'grep -A2 "^\[bezapool/forge-agents-backup\]" /etc/sanoid/sanoid.conf; grep -c forge-agents-backup /usr/local/bin/bezaforge-restic-backup.sh'
```

Expect the dataset's sanoid block with `use_template = forge_agents_backup`,
then `1`. Its first daily snapshot appears after midnight
(`zfs list -t snapshot bezapool/forge-agents-backup`).

### 10. forge-agents, twice

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && ansible-playbook site.yml -l forge-agents --ask-become-pass --ask-vault-pass
```

Run the same command a second time. Its recap must read `changed=0` for
forge-agents; anything else is a finding, not noise. Then look for failed
units, since the node_exporter packages bring `openipmi` along and this board
has no BMC:

```bash
ssh joseph@10.10.50.20 'systemctl --failed --no-legend; sudo ufw status | head -12'
```

Expect no failed units, and UFW active with 22 allowed from the laptop's
addresses and 9100 from `10.10.20.20`. If `openipmi.service` is listed, mask it
through `systemd_masked_units` in `host_vars/forge-agents.yml`, as
`host_vars/forge-hypervisor/vars.yml` does.

### 11. Prometheus scrapes it (forge-ops)

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && ansible-playbook site.yml -l forge-ops --tags monitoring --ask-become-pass --ask-vault-pass
```

```bash
curl -s https://prometheus.bezaforge.dev/api/v1/query --data-urlencode 'query=up{instance="forge-agents"}' | jq -r '.data.result[].value[1]'
```

Expect `1`. Then `~/Projects/bezaforge-infrastructure/scripts/deploy-drift-check.py --hosts`
should list forge-agents, which proves step 10's deploy stamps arrive through
the scrape.

### 12. Uptime Kuma sees it (by hand)

Kuma's monitors live in its UI, not in this repository. At
<https://uptime.bezaforge.dev> add a **Ping** monitor named `forge-agents` for
`10.10.50.20`, with the same notification as forge-ai's monitor, and confirm it
goes green. UFW on Ubuntu answers ping by default.

### 13. Health

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && ansible-playbook health.yml -l forge-agents --ask-become-pass --ask-vault-pass
```

## What comes next

Step 3 of the Brizza build plan onward: Syncthing and the vault, Never4gA,
Hermes and the team, and then the nightly backup push into step 7's dataset
and the restore drill.

## Rollback

For the install: none needed. Until step 4's storage confirmation the disk is
untouched; after it, there is nothing on the machine anyone wants back.

For bringing it under Ansible: the play only adds configuration to an empty
host. The DNS change is undone by reverting the pull request and re-running
step 8. The dataset stays empty until the backup push exists; to remove it,
take its rows out of `roles/sanoid` and `roles/restic-gcs`, redeploy step 9,
then `zfs destroy bezapool/forge-agents-backup`.
