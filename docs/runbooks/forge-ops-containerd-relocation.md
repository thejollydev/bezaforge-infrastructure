# Runbook — Move containerd's Data Root onto the Docker LV (forge-ops)

This runbook moves containerd's content store and overlayfs snapshots from the
150 G root LV onto `forge--ops--vg-docker`, the 300 G volume that exists for
exactly this data.

Written for #982. It is an **offline** move: every container on forge-ops stops
for the duration, which is every service the network depends on — AdGuard (DNS
for all VLANs), Traefik, Gitea, OpenProject, Grafana. Budget a maintenance
window; do not run this because you happened to notice a disk alert.

---

## Why the disk filled

Docker 29 uses the containerd image store. `docker info` reports:

```
Storage Driver: overlayfs
 driver-type: io.containerd.snapshotter.v1
```

Pulled images therefore land under **containerd's** root, not under
`/var/lib/docker`. There is no `/etc/docker/daemon.json` on the host and the
stock `/etc/containerd/config.toml` leaves `root` commented out, so containerd
took its default of `/var/lib/containerd` — on the root LV.

The host was partitioned on the older assumption that images live in
`/var/lib/docker`. As measured 2026-09-02:

| volume | size | used | holds |
|---|---|---|---|
| `forge--ops--vg-root` | 150 G | 119 G (85 %) | OS **+ 112 G of `/var/lib/containerd`** |
| `forge--ops--vg-docker` | 300 G | 13 G (5 %) | `/var/lib/docker` — volumes only |
| `forge--ops--vg-bezaforge` | 400 G | 11 G (3 %) | `/opt/bezaforge` |

`/var/lib/containerd` was 112.4 G of the 119 G: 81.8 G of overlayfs snapshots
and 30.6 G of content store. Root went 70.6 % → 79.0 % → 85.1 % over the thirty
days to 2026-09-02, roughly 0.5 %/day.

A prune on 2026-09-02 reclaimed 76.57 G of images plus 2.57 G of build cache
(120 images → 38, of which 26 in use) and took root to 32 %. **That bought
time, it did not fix the mismatch.** Images still land on the wrong volume and
still grow.

---

## Why the node-exporter fix must land first

**Do not skip this. Doing the move first leaves the disk alert silently
watching the wrong volume.**

`node-exporter` on forge-ops is the containerised one (the other four hosts run
the native package). It bind-mounts `/` at `/rootfs` but, until #982, never
passed `--path.rootfs=/rootfs`. The filesystem collector therefore read device
and fstype labels from the host's `/proc/mounts` while calling `statfs` on each
path **inside the container's own namespace**.

The symptom, measured before the fix:

```
mountpoint  device                            size
/           /dev/mapper/forge--ops--vg-root   158.2 GB
/tmp        tmpfs                             158.2 GB
/run        tmpfs                             158.2 GB
```

Three filesystems, all reporting 158.2 GB. The host's `/tmp` is 16 G and `/run`
is 3.2 G — all three were reading the container's overlay. `/boot`,
`/var/lib/docker`, `/opt/bezaforge` and both NFS mounts did not appear at all.

The `Disk Space Low` alert was correct only by coincidence: overlay `statfs`
passes through to the upperdir, and the upperdir lived on the root LV. Confirm
it for yourself with:

```bash
docker run --rm alpine df -h /     # reports the root LV, not a container size
```

Move containerd to the docker LV and that coincidence breaks. `/` would report
the 300 G volume at ~5 % while still labelled
`device=/dev/mapper/forge--ops--vg-root`, and the alert would go quiet
permanently on a volume nobody is watching.

---

## Prerequisites

- The PR carrying `--path.rootfs=/rootfs` (roles/monitoring) is **merged and
  deployed**, and step 1 below verifies it on the live host.
- Free space on `/var/lib/docker` greater than the current size of
  `/var/lib/containerd`, with headroom. Check both before starting.
- Console or management-VLAN access to forge-ops. You are stopping AdGuard, so
  DNS for the whole network goes down; do not rely on anything that resolves a
  name mid-run, including `ssh forge-ops` if your workstation needs DNS for it.
  Use `ssh joseph@10.10.20.20`.
- Root on forge-ops (`sudo`, password — `joseph` has no passwordless sudo).

---

## Steps

### 1. Verify node-exporter now reports real filesystems

After deploying the monitoring role, confirm the metric is no longer the
container's overlay:

```bash
curl -sG http://prometheus:9090/api/v1/query \
  --data-urlencode 'query=node_filesystem_size_bytes{instance="forge-ops",fstype=~"ext4|xfs"}' \
  | jq -r '.data.result[] | "\(.metric.mountpoint)\t\(.metric.device)\t\(.value[1])"'
```

You must see **`/`, `/boot`, `/var/lib/docker` and `/opt/bezaforge` with four
different sizes** — roughly 158 GB, 989 MB, 316 GB, 422 GB. If `/tmp` and `/run`
still match `/`, the flag is not live; stop and fix that before going further.

### 2. Record the before state

```bash
df -h / /var/lib/docker
sudo du -sh /var/lib/containerd
docker images -q | sort > /tmp/images-before.txt
wc -l < /tmp/images-before.txt
docker ps --format '{{.Names}}' | sort > /tmp/containers-before.txt
wc -l < /tmp/containers-before.txt
```

Keep the `du` figure: step 7 checks against it.

### 3. Stop Docker and containerd

`docker.socket` must go down too, or socket activation restarts the daemon
underneath you.

```bash
sudo systemctl stop docker.socket docker.service containerd.service
sudo systemctl status containerd.service --no-pager | head -3   # expect inactive
docker ps 2>&1 | head -2                                        # expect a connection error
```

Confirm no shims survived:

```bash
pgrep -a containerd-shim || echo "no shims running"
```

### 4. Copy the data

`rsync`, not `mv` — the source stays intact as the rollback until you are
satisfied. `-aHAX --numeric-ids` preserves hardlinks, ACLs and xattrs, all of
which the overlayfs snapshotter relies on. Omitting `-H` in particular inflates
the copy and can break layer sharing.

```bash
sudo mkdir -p /var/lib/docker/containerd
sudo rsync -aHAX --numeric-ids --info=progress2 \
  /var/lib/containerd/ /var/lib/docker/containerd/
```

Verify the copy landed. Compare **apparent** size, not disk usage:

```bash
sudo du -sh --apparent-size /var/lib/containerd /var/lib/docker/containerd  # must match
sudo du -sh /var/lib/containerd /var/lib/docker/containerd                  # copy may be larger
ls /var/lib/docker/containerd                                               # io.containerd.* dirs present
```

The copy can legitimately take more disk than the source. On 2026-09-19 it was
53 G against 46 G, while apparent size was 50 G on both sides, with identical
file counts (805,070) and hardlink counts (20,917). The difference was sparse
files — core dumps in a snapshot's writable layer — which `rsync` writes out as
real blocks unless `--sparse` is passed. `--sparse` is not in the command above
because it is the slower path and correctness does not depend on it; if the
destination is tight, add it and expect a longer run.

### 5. Set the host variable

The variable is set in `ansible/inventory/host_vars/forge-ops/vars.yml` on the
`forge-ops-containerd-relocation-apply` branch, whose pull request stays open
until this runbook is done. Check that branch out on the machine running
Ansible:

```bash
git switch forge-ops-containerd-relocation-apply
grep '^docker_containerd_data_root' ansible/inventory/host_vars/forge-ops/vars.yml
# docker_containerd_data_root: /var/lib/docker/containerd
```

It stays off `main` until the copy exists, because the guard in
`roles/docker` refuses to repoint containerd at a directory that does not
already hold the content store. Merged early, it would fail every routine
`site.yml` run against forge-ops.

### 6. Apply the role

```bash
ansible-playbook ansible/site.yml --tags docker --limit forge-ops --check --diff
ansible-playbook ansible/site.yml --tags docker --limit forge-ops
```

This writes `/etc/containerd/config.toml` from the template and fires the
`restart containerd and docker` handler, bringing both services back on the new
root.

**If the containers come up dead, do not panic.** On 2026-09-19 they did:
`roles/docker` then started Docker (task "Enable and start Docker") *before* it
installed `config.toml`, so the play brought all 30 containers up on the OLD
data root, and the end-of-play handler restarted containerd onto the NEW one
while those containers' shims were still alive holding their tasks. Every
container exited 128:

```
failed to create task for container: AlreadyExists: task <id>: already exists
```

#1237 fixed the role: it now installs `config.toml` before starting Docker, and
the handler stops Docker before it restarts containerd, so no shim outlives the
containerd that spawned it. The containers should come straight back. If they
do not, the recovery below is what worked on the old role.

The containers are fine; the runtime state in `/run/containerd` is stale.
Clear it:

```bash
sudo systemctl stop docker.socket docker.service containerd.service
pgrep -a containerd-shim            # leftovers from the old root, expect ~30
sudo systemctl start containerd.service
sleep 3
sudo systemctl start docker.service docker.socket
sleep 45
docker ps --format '{{.Names}}' | wc -l
```

Stopping the services lets the orphaned shims go, and the restart policies
bring every container back on the new root. Verified on 2026-09-19: all 30
returned, none unhealthy.

If a `io.containerd.runtime.v2.task` directory came across in the rsync, move
it aside rather than deleting it — it is runtime state and belongs on tmpfs:

```bash
sudo mv /var/lib/docker/containerd/io.containerd.runtime.v2.task{,.stale-982}
sudo mkdir -p /var/lib/docker/containerd/io.containerd.runtime.v2.task
```

### 7. Verify

```bash
sudo grep '^root' /etc/containerd/config.toml     # /var/lib/docker/containerd
docker info | grep -A1 'Storage Driver'
docker images -q | sort | diff /tmp/images-before.txt - && echo "same images, nothing re-pulled"
docker ps --format '{{.Names}}' | sort > /tmp/containers-after.txt
diff /tmp/containers-before.txt /tmp/containers-after.txt && echo "all containers back"
docker ps --filter health=unhealthy --format '{{.Names}}'   # expect empty
```

Then check DNS actually came back, since AdGuard was down:

```bash
dig +short git.bezaforge.dev @10.10.20.20
```

And confirm the metrics followed the data:

```bash
df -h / /var/lib/docker
```

`/var/lib/docker` should have grown by about the step 2 `du` figure. `/` should
not have moved: step 4 copied the data rather than moving it, and the original
stays on the root LV until step 8.

Give Prometheus a scrape interval, then re-run the step 1 query. `/` must still
report ~158 GB. If `/` has become ~317 GB, `--path.rootfs` is not in effect and
you are back in the silent-failure case — roll back or fix the exporter before
leaving the host.

Once all of this passes, merge the pull request so `main` matches the host.

Also check the services from off the host, since Traefik and AdGuard both
restarted:

```bash
dig +short git.bezaforge.dev @10.10.20.20
for u in git pm grafana; do curl -s -o /dev/null -w "$u %{http_code}\n" "https://$u.bezaforge.dev"; done
```

### 8. Reclaim the old root, but not today

> **This step moved.** #1244 found a corrupt image on disk after this copy and
> folded a full re-pull of every image into the same outage, because both need
> the host offline and the old root stops being a useful rollback once the
> images have been replaced. Run
> [`forge-ops-image-repull.md`](forge-ops-image-repull.md) instead; its step 8
> is this one, in its proper place at the end.

Leave `/var/lib/containerd` in place until the host has run a few days and
survived a reboot. Then:

```bash
sudo mv /var/lib/containerd /var/lib/containerd.old-982
sudo systemctl reboot
# verify again after boot, then:
sudo rm -rf /var/lib/containerd.old-982
```

Renaming before deleting is the point — if anything still resolves the old
path, you find out with the data recoverable.

---

## Rollback

At any point before step 8's `rm`:

```bash
sudo systemctl stop docker.socket docker.service containerd.service
# switch back to main (or, once merged, re-comment docker_containerd_data_root), then:
ansible-playbook ansible/site.yml --tags docker --limit forge-ops
```

The role rewrites `config.toml` with `root = "/var/lib/containerd"`, the
original data is still there untouched, and the handler restarts both services
on it. The copy under `/var/lib/docker/containerd` can then be removed.

---

## What this does not fix

The move buys 300 G of headroom instead of 150 G; on its own it does not slow
the growth that filled the volume. `roles/docker-prune` handles that separately
— a weekly reclaim of unused images older than 30 days, on forge-ops and
forge-erp both — and the two changes are independent: either is useful without
the other.
