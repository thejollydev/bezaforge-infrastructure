# Runbook — DNS Failover Test (AdGuard-down exercise)

Proves that fleet DNS survives AdGuard being unavailable, by taking it away and watching what happens. Written for **#638**.

**This runbook is the acceptance criterion for #638, not a nice-to-have.** The ticket's "done when" is that every host's behaviour during an AdGuard outage is *known and intentional*. A config diff cannot establish that. The mechanism under test — whether `systemd-resolved` actually rotates to the second server when the first stops answering — is an assumption until it is measured on these machines.

> **Read this whole file before starting.** Phase B removes AdGuard from the whole network. Since 2026-08-09 the workstation has its own secondary and survives that (measured), but the runbook is still written to be followed with **no assistant and no name resolution** — every command targets an IP address, never a hostname. Assume nothing about what will still be reachable.

---

## What this proves, and what it does not

| Proves | Does not prove |
|---|---|
| resolved rotates to the secondary when the primary stops answering | That the secondary can carry sustained production load |
| Internal `*.bezaforge.dev` names still resolve during the outage | Anything about AdGuard's *own* recovery behaviour |
| External names still resolve during the outage | That ad-blocking survives — **it does not**, by design |
| How long failover takes, per host | Behaviour of clients that are not in the fleet (phones, TVs) |

Two distinct failure shapes are tested separately, because resolved may treat them differently and only one of them resembles a stopped container:

- **REFUSED** — the host is up, nothing is listening on :53. This is what a stopped AdGuard container actually looks like. Expect fast failover.
- **BLACKHOLE** — packets vanish, no reply at all. This is what a dead forge-ops or a severed link looks like. Expect failover only after a timeout.

If failover works for REFUSED but not BLACKHOLE, that is a real and useful finding, not a failed test. Record it.

---

## Prerequisites

1. **`roles/dnsmasq` and `roles/dns-client` are deployed and verified.** Do not run this against a fleet that has not had them applied.
2. **The secondary answers, and answers the same as the primary.** This is the single most important precondition — if it fails, stop; the rest of the test is meaningless:

   ```
   scripts/dns-parity-check.sh
   ```
   → expect `RESULT: PASS`, exit `0`.

   Exit `1` means the resolvers disagree: during the outage those names would resolve differently than they do today. Exit `2` means one of them did not answer at all — that is **not** a pass and not a parity failure; fix the resolver first.

   Also confirm external resolution, which the parity check does not cover:
   ```
   dig +short @10.10.10.10 example.com
   ```
   → expect a public address (values vary)

3. **Two terminals** — the Phase A block commands are self-timing and hold their terminal, so measurement happens in the other. (In practice a second machine can do the measuring over SSH instead; the block only needs to hold *a* terminal.)
4. **Physical or Proxmox-console access is available** if something goes badly. forge-ops is bare metal — it has no Proxmox console. The VMs (forge-ai 101, forge-erp 103) do, at `https://10.10.10.10:8006`.

### Host reference (use IPs — DNS is the thing being broken)

| host | address | resolver method |
|---|---|---|
| forge-ops | `10.10.20.20` | resolved global (`DNS=`) |
| forge-ai | `10.10.50.10` | netplan link scope |
| forge-erp | `10.10.20.50` | netplan link scope |
| forge-hypervisor | `10.10.10.10` | static resolv.conf → own dnsmasq |
| Joseph's laptop | `10.10.40.99` | NetworkManager → resolv.conf **and** systemd-resolved (nsswitch `resolve` is first) |
| Proxmox UI | `https://10.10.10.10:8006` | — |

---

## Phase A — per-host failover, with **no fleet impact**

Phase A blocks a *single host's* path to AdGuard with a local firewall rule. AdGuard keeps running and every other machine — including your laptop and this session — is completely unaffected. Run Phase A on all four hosts and get it passing **before** considering Phase 4's real outage.

Each block command **clears itself automatically after 120 seconds**. That is deliberate: if you lose the SSH session, close the laptop, or walk away, the host un-blocks itself rather than sitting cut off.

### A1. Open terminal 1 — apply the block

SSH into the host under test first, then run the block there. Start with **forge-erp** (`10.10.20.50`) — it is the least critical host on the list.

**REFUSED variant** (models a stopped AdGuard container):

```
sudo bash -c '
set -e
iptables -I OUTPUT -d 10.10.20.20 -p udp --dport 53 -j REJECT --reject-with icmp-port-unreachable
iptables -I OUTPUT -d 10.10.20.20 -p tcp --dport 53 -j REJECT --reject-with tcp-reset
echo "BLOCKED (refused) — auto-clears in 120s at $(date -d "+120 seconds" +%H:%M:%S)"
sleep 120
iptables -D OUTPUT -d 10.10.20.20 -p tcp --dport 53 -j REJECT --reject-with tcp-reset
iptables -D OUTPUT -d 10.10.20.20 -p udp --dport 53 -j REJECT --reject-with icmp-port-unreachable
echo "CLEARED"
'
```

Expected end state while it runs: this host cannot reach AdGuard on :53 and gets an immediate rejection. Nothing else on the network changes.

### A2. In terminal 2 — measure

SSH into the **same** host, then:

```
sudo resolvectl flush-caches
time resolvectl query --cache=no grafana.bezaforge.dev
time resolvectl query --cache=no example.com
resolvectl status | head -20
```

**Pass looks like:** both queries return answers, `grafana.bezaforge.dev` is still `10.10.20.20`, and `resolvectl status` shows `Current DNS Server: 10.10.10.10`.

**Fail looks like:** either query returns a resolution error, or `grafana.bezaforge.dev` comes back `NXDOMAIN`. Record the exact output and stop — do not proceed to Phase B.

Write down the elapsed time from `time`. That number is the answer to "how long is DNS degraded during a docker restart".

### A3. Repeat with the BLACKHOLE variant

Same as A1 but with `DROP`, which sends nothing back:

```
sudo bash -c '
set -e
iptables -I OUTPUT -d 10.10.20.20 -p udp --dport 53 -j DROP
iptables -I OUTPUT -d 10.10.20.20 -p tcp --dport 53 -j DROP
echo "BLOCKED (blackhole) — auto-clears in 120s at $(date -d "+120 seconds" +%H:%M:%S)"
sleep 120
iptables -D OUTPUT -d 10.10.20.20 -p tcp --dport 53 -j DROP
iptables -D OUTPUT -d 10.10.20.20 -p udp --dport 53 -j DROP
echo "CLEARED"
'
```

Re-run the A2 measurements. Failover here will be slower — that is expected, and the number matters.

### A4. Repeat A1–A3 on the remaining hosts

Order: **forge-erp** → **forge-ai** → **forge-ops**.

forge-ops is last and deserves care: it is where AdGuard runs.

⚠️ **AdGuard is a bridged container** (`172.18.0.19`, port 53 published to `10.10.20.20:53`), so locally-generated queries are DNAT'd in `nat OUTPUT` *before* `filter OUTPUT` sees them. A block matching only `-d 10.10.20.20` therefore **leaks on this host** — that produced a false 5s reading on 2026-08-09. Block both destinations:

```
for d in 10.10.20.20 172.18.0.19; do
  iptables -I OUTPUT -d $d -p udp --dport 53 -j DROP
  iptables -I OUTPUT -d $d -p tcp --dport 53 -j DROP
done
```

### A5. Confirm no rule was left behind

On every host tested:

```
sudo iptables -S OUTPUT | grep -- "--dport 53" || echo "clean — no leftover rules"
```

→ expect `clean — no leftover rules`. If anything remains, delete it with the matching `-D` form from the block command above.

---

## Phase B — the real outage

Only run Phase B once **every host passed Phase A**. This is the end-to-end confirmation.

> **From here on, DNS is down for the whole network** — every device that has no secondary. Phones, TVs and anything else on DHCP get AdGuard only and **will lose DNS** for the duration. The fleet hosts and the workstation have a proven secondary and keep working (measured 2026-08-09), so this no longer costs you the session. Everything below is still IP-only so it works either way.

### B1. Confirm the workstation has a working secondary

*(Rewritten 2026-08-09. This step used to stage a manual `/etc/resolv.conf` swap as an "escape hatch" — that is obsolete. The workstation now has a real secondary, verified by the same failover test as the fleet, so it survives the outage on its own.)*

The workstation's NetworkManager profiles (`The Bunker` x2, `BezaForgeWG`) carry both servers plus `ipv4.dns-search bezaforge.dev` and `timeout:2,attempts:1`. Confirm before proceeding:

```
resolvectl status | head -6
```
→ expect `DNS Servers: 10.10.20.20 10.10.10.10`.

⚠️ **`Current DNS Server` must read `10.10.20.20`.** If it already says `10.10.10.10`, the workstation has previously failed over and never failed back — running the test in that state proves nothing about it, because it is already off AdGuard. Reset first:

```
sudo systemctl restart systemd-resolved
```

Measured 2026-08-09: with AdGuard stopped, the workstation resolved an uncacheable probe name in 83 ms via the secondary, and lost nothing.

### B2. Stop AdGuard

SSH into forge-ops first (`ssh joseph@10.10.20.20`), then:

```
cd /opt/bezaforge/adguard
sudo docker compose stop
```

**Expected end state:** the `adguard` container is `Exited`. Nothing else on forge-ops stops — Traefik and every other service keep running. Fleet DNS is now served **only** by dnsmasq on `10.10.10.10`.

Confirm the container really is down:

```
sudo docker ps -a --filter name=adguard --format '{{.Names}}\t{{.Status}}'
```
→ expect `adguard   Exited (...)`

### B3. Verify resolution from every host

From each host in turn (SSH by IP), run:

```
sudo resolvectl flush-caches
resolvectl query --cache=no grafana.bezaforge.dev
resolvectl query --cache=no example.com
resolvectl status | head -20
```

And from the laptop:

```
getent hosts pm.bezaforge.dev
getent hosts github.com
```

Also confirm a real service still works end to end — this tests the whole path, not just the resolver:

```
curl -sSk -o /dev/null -w '%{http_code}\n' https://grafana.bezaforge.dev
```
→ expect `200` or `302`

### B4. Restore AdGuard

Still on forge-ops:

```
cd /opt/bezaforge/adguard
sudo docker compose start
```

**Expected end state:** container `Up`. Confirm it is answering again:

```
dig +short @10.10.20.20 grafana.bezaforge.dev
```
→ expect `10.10.20.20`

### B5. Restore the laptop

```
sudo cp /root/resolv.conf.pre-638-test /etc/resolv.conf
cat /etc/resolv.conf
```

→ expect exactly:

```
# Generated by NetworkManager
search bezaforge.dev
nameserver 10.10.20.20
```

(74 bytes. Captured from the live file 2026-08-08 — this is the byte-accurate original, not a reconstruction.)

---

## If it goes wrong

**Symptom: a host has no DNS at all after the test.**
Check for a leftover firewall rule first (`sudo iptables -S OUTPUT | grep 53`), then confirm AdGuard is running (`dig +short @10.10.20.20 grafana.bezaforge.dev` from anywhere). Restart the resolver last: `sudo systemctl restart systemd-resolved`.

**Symptom: the laptop has no DNS and NetworkManager overwrote resolv.conf.**
```
printf '# Temporary\nsearch bezaforge.dev\nnameserver 10.10.10.10\n' | sudo tee /etc/resolv.conf
```
Then restore per B5 once AdGuard is back.

**Symptom: AdGuard will not start.**
```
cd /opt/bezaforge/adguard && sudo docker compose logs --tail 50
```
Fleet DNS still works via `10.10.10.10` in the meantime — that is the entire point of #638, and this situation is the test passing, not failing.

**Symptom: dnsmasq is not answering on the hypervisor.**
```
ssh root@10.10.10.10
systemctl status dnsmasq
dnsmasq --test
ss -lnup 'sport = :53'
```
→ expect a listener on `127.0.0.1:53` and `10.10.10.10:53`.

---

## Record the results

Failover times are the deliverable. Fill this in and paste it into #638:

**Results — measured 2026-08-09 (#638). Every host passed; no internal name ever returned NXDOMAIN.**

| host | REFUSED failover | BLACKHOLE failover | internal | external | notes |
|---|---|---|---|---|---|
| forge-erp | **71 ms** | **10.18 s** | ✅ | ✅ | single link scope, networkd |
| forge-ops | discarded | **10.20 s** | ✅ | ✅ | first REFUSED run used a leaking block (container DNAT); the link-scoped `1.1.1.1` never answered once |
| forge-ai | ✅ (Phase B) | not run | ✅ | ✅ | structurally identical to forge-erp |
| laptop | **83 ms** (Phase B) | not run | ✅ | ✅ | uncacheable probe name, so not a cache hit |

**The two numbers that matter.** A *stopped container* refuses immediately → failover in **under 100 ms**, which is the case you actually hit on every `--tags adguard` deploy. A *dead or unreachable host* has to time out → **~10.2 s** on the first query, then normal. Both are recoveries, not outages.

⚠️ **Phase B leaves every host on the secondary and they do not fail back.** The same is true after *any* AdGuard bounce — a `--tags adguard` deploy, a forge-ops reboot, an `update.yml` pass. The "DNS Not Using Primary" Grafana alert catches the fleet; remediate with:

```bash
cd ~/Projects/bezaforge-infrastructure/ansible
ansible forge-ops,forge-ai,forge-erp -i inventory/hosts.yml \
  -m systemd -a "name=systemd-resolved state=restarted" \
  --become --ask-become-pass --ask-vault-pass
```

⚠️ **The workstation needs a second, manual step — and nothing will remind you.** It carries the same resolver pair (`ansible-arch` `roles/networking`) and parks on the secondary identically, but it is **not in this inventory**, so the command above skips it; and it does **not** run `roles/dns-client`, so it emits no `bezaforge_dns_primary_in_use` textfile metric and the alert is blind to it. On the workstation:

```bash
sudo systemctl restart systemd-resolved
```

Confirm both with `resolvectl status | grep 'Current DNS Server'` — expect `10.10.20.20`. Caught for real on the 2026-08-09 fleet update: all four fleet hosts came back on the primary and the workstation sat on `10.10.10.10` unnoticed, because the only remediation written down was the four-host one.

**Then close the loop:** whatever the result, #638's "done when" requires that no doc or comment claims protection that is not there. If failover did **not** work on some host, that outcome gets written down as an accepted, documented dependency — a known gap is a pass for this ticket; an *unknown* one is not.
