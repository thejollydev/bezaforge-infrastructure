# Runbook — Restore forge-ops Networking on a Rebuild

This runbook covers bringing a freshly-imaged **forge-ops** back onto the correct VLANs. Follow it before any other Ansible role runs against a rebuilt host.

Written for #628, which codified `/etc/network/interfaces` into `roles/network`. Before that it was hand-written and unmanaged, so a rebuild returned forge-ops with no VLAN 20 interface at all — no production IP, no AdGuard, and therefore **no DNS for any VLAN on the network**.

---

## Why this must go first

forge-ops's two addresses are not interchangeable, and almost everything else assumes the production one already exists:

| interface | tagging | address | role |
|---|---|---|---|
| `enp44s0` | **untagged** = VLAN 10 Management | `10.10.10.20` | management, NFS to the hypervisor |
| `enp44s0.20` | **tagged** = VLAN 20 Production | `10.10.20.20` | every service, **holds the default route** |

There is **no `enp44s0.10`**. Six docs claimed the reverse arrangement until 2026-08-07; if you are reading an older guide that names `enp44s0.10`, it is wrong. Router side: **ER7412-M2 port 2**, Native VLAN `Management(10)`. Full port map: vault `design/architecture.md` § *Physical port map*.

Run `roles/network` (and reboot) **before** `common`, `docker`, `traefik`, `adguard`, or `services`:

- `roles/common`'s UFW rules and `roles/dns-client`'s `resolved.conf` both reference `10.10.20.20`. (Resolver config moved out of `common` into `dns-client` on 2026-08-08, #638 — `site.yml` orders `dns-client` immediately after `network` and before `common`.)
- AdGuard binds and serves DNS on `10.10.20.20`; the whole fleet points at it.
- Traefik and every compose service assume the production IP is up.

`site.yml` already orders `network` first in the `docker_hosts` play, so an unscoped run does the right thing — this ordering matters if you deviate with `--tags`.

---

## Prerequisites

- Debian on the rebuilt host (this role is **ifupdown**, not netplan — it does not apply to the Ubuntu VMs).
- SSH reachable at *some* address. Port 2's native (untagged) VLAN is `Management(10)`, and VLAN 10 does serve DHCP from roughly `.100` upward (both TINY-WIN at `10.10.10.102` and the EAP723 at `10.10.10.100` were leased there), so a fresh Debian install should come up somewhere in that range. Find it from the Omada controller's client list or by ARP. If it does not appear, you need console access — do not assume a lease.
- `ansible_host` in `inventory/host_vars/forge-ops/vars.yml` is `10.10.20.20` — the **post-restore** address. Until the host is on VLAN 20, target it with an override (step 2).

---

## Steps

### 1. Confirm the host vars still match the intended arrangement

`inventory/host_vars/forge-ops/vars.yml`:

```yaml
network_manage_interfaces: true
network_mgmt_interface: enp44s0
network_prod_interface: enp44s0.20
network_prod_gateway: 10.10.20.1
management_ip: 10.10.10.20
production_ip: 10.10.20.20
```

⚠️ **The NIC name is hardware-dependent.** `enp44s0` is a PCI-path name — replacing the board or NIC changes it, and the template would then write a stanza for an interface that does not exist, leaving the host with no network after reboot. Check the real name first:

```bash
ip -br link          # on the rebuilt host
```

If it differs, update `network_mgmt_interface` and `network_prod_interface` (`<nic>.20`) before applying.

### 2. Apply the network role only

```bash
cd ~/Projects/bezaforge-infrastructure/ansible
ansible-playbook site.yml -l forge-ops --tags network \
  --ask-become-pass --ask-vault-pass \
  -e ansible_host=<current-dhcp-address>
```

Drop the `-e` override once the host is already at `10.10.20.20`.

Expect `changed=1` on a rebuilt host (the file differs from Debian's stock one). The role also installs `ifupdown` and **`vlan`** — without `vlan`, `enp44s0.20` never comes up, so the file alone is not enough.

### 3. Prove the file parses BEFORE you reboot

This is the step that catches a typo while it is still cheap. `ifquery` reads the file and prints the derived config **without touching any interface**:

```bash
/sbin/ifquery enp44s0
/sbin/ifquery enp44s0.20
```

Expected:

```
# enp44s0
address: 10.10.10.20
dns-search: bezaforge.dev
broadcast: 10.10.10.255
netmask: 255.255.255.0

# enp44s0.20
address: 10.10.20.20
gateway: 10.10.20.1
vlan-raw-device: enp44s0
broadcast: 10.10.20.255
netmask: 255.255.255.0
```

(`broadcast` and `netmask` are derived by `ifquery`, not written in the file.)

If either command errors or prints the wrong address, **fix the template before rebooting** — otherwise the failure is silent until the host comes back without a network.

### 4. Reboot

```bash
sudo systemctl reboot
```

A reboot is preferred over `systemctl restart networking` on this host: the restart tears down the NIC carrying your SSH session *and* AdGuard mid-flight, and a partial failure leaves you with neither a shell nor DNS. A reboot fails the same way but at least ends in a known state — and on bare metal you will want physical access available either way.

### 5. Verify

```bash
ssh joseph@10.10.20.20 '
  ip -br addr show enp44s0
  ip -br addr show enp44s0.20
  ip route show default
'
```

Expected: `enp44s0` UP at `10.10.10.20/24`, `enp44s0.20` UP at `10.10.20.20/24`, and `default via 10.10.20.1 dev enp44s0.20`.

Then confirm DNS is serving the fleet again — this is the thing whose absence looks like a network fault:

```bash
ssh joseph@10.10.20.20 'resolvectl query --cache=no grafana.bezaforge.dev'
dig +short @10.10.20.20 grafana.bezaforge.dev     # from another host
```

### 6. Continue the rebuild

With networking correct, run the rest normally:

```bash
ansible-playbook site.yml -l forge-ops --ask-become-pass --ask-vault-pass
```

---

## Notes and gotchas

- **The file is Ansible-managed and its header says so.** Hand-edits are reverted on the next run. Change `roles/network/templates/interfaces.j2` instead.
- **No handler restarts networking.** This is deliberate — see the role header. Applying a change to the template does *not* activate it; step 4 does.
- **`backup: true`** means every change leaves a timestamped copy in `/etc/network/`, so recovery from a rescue shell is a single `mv`.
- **DNS on this host has a subtlety.** *(Updated 2026-08-08, #638.)* Resolver config now lives in `roles/dns-client`, which sets `DNS=10.10.20.20 10.10.10.10` — AdGuard on forge-ops plus dnsmasq on forge-hypervisor, **both internal-aware**, which is what makes a second server safe here. The old `FallbackDNS=1.1.1.1` is gone: it was **inert** whenever `DNS=` is set (see `resolved.conf(5)`) while the repo claimed it caught AdGuard outages.

  The `dns-nameservers 1.1.1.1` line **was removed 2026-08-09** (#638, Piece 4), after the failover test in `dns-failover-test.md` proved the replacement. It had been the *pre-#638* accidental fallback and #628 deliberately kept it; it is gone now because the real secondary is proven, and because that line gave forge-ops a **second DNS scope** claiming `bezaforge.dev` while holding a public resolver that answers NXDOMAIN for internal names. One scope with two internal-aware servers is the invariant. Do not reinstate it.
- **forge-hypervisor is deliberately NOT covered.** Proxmox owns its `/etc/network/interfaces` (its own banner says so) and stages changes through `interfaces.new`. Codifying it would fight PVE, and `vmbr0` is what every VM hangs off. If the hypervisor is ever rebuilt, recreate `vmbr0` through the Proxmox UI — vault `design/architecture.md` carries the values.

## Related

- `roles/network/` — the role itself; its `tasks/main.yml` header carries the design rationale.
- Vault `design/architecture.md` § *Physical port map — ER7412-M2* — verified port-by-port 2026-08-07.
- Vault `design/ip-allocation.md` — VLANs, addresses, firewall matrix.
- `docs/runbooks/dr-restore-drill.md` — data restore, once the host is back on the network.
