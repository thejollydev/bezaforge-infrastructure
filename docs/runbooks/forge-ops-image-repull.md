# Runbook — Re-pull Every Image on forge-ops, and Reclaim the Old containerd Root

This runbook removes every container and every image on forge-ops, re-pulls the
images from their registry digests, brings the stack back through `site.yml`,
and then finishes #982 by reclaiming `/var/lib/containerd`.

Written for **#1244**, which folds into **#982 step 8**. Both need the same
outage, and doing them in one window is the point: once every image has been
re-pulled and verified, the old data root has no remaining value as a rollback.

It is an **offline** run. Every container on forge-ops stops, which is every
service the network depends on — AdGuard (DNS for all VLANs), Traefik, Gitea,
OpenProject, Grafana. Budget a maintenance window. It ends in a reboot.

---

## Why every image has to go, not just ClickHouse's

On 2026-09-21, after a Docker restart, `langfuse-clickhouse` crash-looped with
exit 246:

```
Code: 246. DB::Exception: Calculated checksum of the executable
(F95BAFCF65C840F2445530E99245C643) does not correspond to the reference
checksum stored in the executable (D51826DE8EECDF82AC843206F7842BB1).
```

`/usr/bin/clickhouse` was corrupt **on disk**. ClickHouse had been serving for
two days from memory; only re-reading the binary at restart exposed it.
Removing the container and the image and re-pulling fixed it.

**ClickHouse verifies its own executable. Almost nothing else does.** The other
25 images in use on this host — AdGuard, Gitea, OpenProject, Traefik, Outline,
Postgres — would run on damaged bytes until something happened to read them.
There is no way to find out which are affected short of re-pulling, because
nothing local can be trusted to check local content.

The suspected cause is the #982 relocation on 2026-09-19, which rsync'd 46 G of
containerd root onto the docker LV. That is **not proven**; it is the only
thing known to have written those snapshots.

### A plain `docker pull` is not enough

`docker pull` of an image whose content is already in the local content store
re-uses the local blobs and the local snapshots. It will happily "pull" a
corrupt image and report it up to date. **The image has to be removed first**,
which means the container referencing it has to be removed first.

---

## What is not at risk

Data lives in named volumes (`docker volume ls` — 23 volumes, 97.6 G) and in
bind mounts under `/opt/bezaforge`. Neither is touched by removing containers
and images. `docker compose down` **without `-v`** keeps named volumes.

Verified before writing this: no compose file on forge-ops uses `build:`, so
every image has a registry to come back from.

---

## Four images are not digest-pinned

The deploy is CURRENT (58/58 host/role pairs match `main`), so everything
re-pulls to the digest the repository pins. Four references carry no digest and
may therefore come back as different content:

| image | pinned as | what a re-pull does |
|---|---|---|
| `cgr.dev/chainguard/minio:latest` | tag only | **will change** — Chainguard rebuilds `:latest` daily, and the free tier publishes no other tag |
| `langfuse/langfuse:3.187.0` | version tag | same content in practice; a re-pushed tag would not be detected |
| `langfuse/langfuse-worker:3.187.0` | version tag | as above |
| `outlinewiki/outline:1.7.1` | version tag | as above |
| `openproject/openproject:17.6.0` | version tag via `OPENPROJECT_RELEASE` | as above |

Step 2 records the digests these resolve to now, and step 7 diffs them. An
unexpected move on a version tag is worth knowing about; the MinIO move is
expected and is not a fault.

---

## Prerequisites

- **Console or management-VLAN access.** You are stopping AdGuard, so DNS for
  the whole network goes down. Do not rely on anything that resolves a name
  mid-run, including `ssh forge-ops`. Use `ssh joseph@10.10.20.20`.
- **Registry access without AdGuard.** forge-ops resolves through
  `10.10.20.20` (AdGuard, on this host) then `10.10.10.10` (the hypervisor's
  dnsmasq). The backstop is what carries the pulls. Confirm it answers for a
  public name before you stop anything — step 1.
- **Root on forge-ops** (`sudo`, password — `joseph` has no passwordless sudo).
  Only steps 3, 5 and 8 need it; `joseph` is in the `docker` group, so every
  `docker` and `docker compose` command below runs unprivileged.
- **An Ansible control host that is not forge-ops**, checked out on `main`,
  with both the become password and the vault password to hand. Step 6 asks
  for both.
- **`tmux` on the control host if you are driving it remotely.** Step 6 pulls
  about 40 G; a dropped SSH session from a phone kills the play partway, with
  the network's services half up.
- Roughly 40 G of egress and the time to pull it.

---

## Steps

### 1. Confirm the DNS backstop before stopping anything

If this does not answer, the pulls in step 6 will fail with every service
already down.

```bash
dig +short registry-1.docker.io @10.10.10.10
dig +short ghcr.io @10.10.10.10
dig +short cgr.dev @10.10.10.10
```

Three non-empty answers, or stop here and fix the backstop.

### 2. Record the before state

```bash
ssh joseph@10.10.20.20 'mkdir -p /tmp/repull-1244
docker ps --format "{{.Names}}\t{{.Image}}" | sort > /tmp/repull-1244/containers-before.txt
docker ps -q | xargs docker inspect --format "{{.Config.Image}} {{.Image}}" | while read ref id; do
  printf "%s\t%s\n" "$ref" "$(docker image inspect "$id" --format "{{index .RepoDigests 0}}")"
done | sort -u > /tmp/repull-1244/digests-before.txt
docker images --format "{{.Repository}}:{{.Tag}}\t{{.ID}}" | sort > /tmp/repull-1244/images-before.txt
docker volume ls -q | sort > /tmp/repull-1244/volumes-before.txt
docker compose ls --format json > /tmp/repull-1244/projects-before.json
df -h / /var/lib/docker /opt/bezaforge > /tmp/repull-1244/df-before.txt
wc -l /tmp/repull-1244/*.txt'
```

Expected at the time of writing: 30 containers, 41 images, 23 volumes,
14 compose projects, root 37 %, `/var/lib/docker` 24 %.

### 3. Preserve what the #1236 core dumps are worth

**This step destroys evidence if it is skipped.** Overlayfs snapshot 1977 holds
Outline/hocuspocus core dumps from 2026-09-06, 15 G on disk, and
#1236 is open on explaining that crash. Removing every image removes the
snapshot with them.

The dumps are in a superseded layer and they are sparse. Preserve a
**manifest and one representative dump**, not 15 G:

```bash
ssh joseph@10.10.20.20
S=/var/lib/docker/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/1977/fs
D=/opt/bezaforge/_evidence/1236-hocuspocus-cores
sudo mkdir -p "$D"
sudo find "$S/app" "$S/opt/hocuspocus" -maxdepth 1 -name 'core.*' \
  -printf '%p\t%s\t%b\t%TY-%Tm-%Td %TH:%TM:%TS\t%U\n' | sort > /tmp/cores.tsv
sudo cp /tmp/cores.tsv "$D/manifest.tsv"
wc -l "$D/manifest.tsv"
# the largest dump, sparse-preserving
LARGEST=$(sort -t"$(printf '\t')" -k2 -rn "$D/manifest.tsv" | head -1 | cut -f1)
echo "$LARGEST"
sudo cp --sparse=always "$LARGEST" "$D/"
sudo du -sh "$D"
```

Do not look for the `node` binary in the snapshot. 1977 is a container's
**writable** layer: it holds what the process wrote, the dumps, and none of the
image's files. The binary lives in a lower, read-only image layer, and that
layer goes in step 5 with the rest. A core without its exact binary is close
to unreadable, so if the Outline version running on the day of the crash is
the one pinned now, take `node` from the re-pulled image after step 6
(`docker cp outline:/usr/local/bin/node …`). If the version has moved since,
the binary is gone and #1236 should say so.

On 2026-09-22 this found 16 dumps and kept `core.388`, 1.45 G apparent and
826 M on disk.

Then note in #1236 that the snapshot is gone and what survived.

If Joseph has said the dumps are not worth keeping, skip this step and record
that decision on #1236 instead. Do not decide it here.

### 4. Stop every stack

`down`, not `stop`: the containers have to be **removed**, or they keep
references on the images and `docker rmi` refuses.

```bash
ssh joseph@10.10.20.20
for p in $(docker compose ls --format json | python3 -c \
  'import sys,json;[print(p["ConfigFiles"]) for p in json.load(sys.stdin)]'); do
  echo "== $p"; docker compose -f "$p" down --remove-orphans
done
docker ps -aq | wc -l        # expect 0
docker volume ls -q | wc -l  # expect 23 — unchanged
```

If any container survives, remove it by hand before going on. A leftover
container pins its image and turns step 5 into a partial job, which is the one
outcome this runbook exists to avoid.

### 5. Remove every image

```bash
docker image prune -af
docker images -q | wc -l   # expect 0
docker system df           # Images 0, Containers 0, Local Volumes 23
```

`docker images -q` must be **0**. Anything left is still referenced by
something, and it is exactly the image you cannot vouch for.

With no containers and no images, nothing references the content store, so any
remaining overlayfs snapshots or blobs are orphans. Clearing them is safe
**only here**, with Docker's own database holding no containers and no images,
so the check refuses to go on otherwise:

```bash
sudo bash -c '
R=/var/lib/docker/containerd
SNAP=$R/io.containerd.snapshotter.v1.overlayfs
CONT=$R/io.containerd.content.v1.content
c=$(docker ps -aq | wc -l); i=$(docker images -q | wc -l)
[ "$c" -eq 0 ] && [ "$i" -eq 0 ] || { echo "REFUSING: $c containers, $i images"; exit 1; }
n=$(ls "$SNAP/snapshots" 2>/dev/null | wc -l)
b=$(find "$CONT/blobs" -type f 2>/dev/null | wc -l)
echo "snapshots: $n  blobs: $b  root: $(du -sh "$R" | cut -f1)"
[ "$n" -eq 0 ] && [ "$b" -eq 0 ] && { echo "nothing orphaned"; exit 0; }
systemctl stop docker.socket docker.service containerd.service
rm -rf "$SNAP" "$CONT"
systemctl start containerd.service; sleep 3
systemctl start docker.service docker.socket
echo "cleared; root now $(du -sh "$R" | cut -f1)"'
```

### 6. Re-pull and bring the stack back

From the Ansible control host, on `main` — the `deploy-stamp` role records the
commit the play ran from, so a run from a branch stamps a commit `main` does
not have:

```bash
cd ~/Projects/bezaforge-infrastructure && git switch main && git pull --ff-only
tmux new -s repull 'cd ansible && ansible-playbook site.yml -l forge-ops --ask-become-pass --ask-vault-pass 2>&1 | tee -a /tmp/repull-1244-site.log; exec zsh'
```

`docker_compose_v2` runs `docker compose up -d`; with no images present,
compose pulls each one from the pinned digest before starting it. Expect this
to take a while — roughly 40 G over the wire.

Do **not** use `--tags`. Every role that owns a stack has to run, or a stack
stays down: `traefik`, `adguard`, `monitoring` (prometheus, grafana, loki),
`services` (gitea, uptime-kuma, netbox, langfuse, homepage, open-webui,
calibre-web), `outline`, `openproject`.

If the play fails partway, note that **when every host in a play fails the
playbook stops there** — later plays never start and are simply absent from the
recap. Fix and re-run; the roles are idempotent.

**Expect the first run to fail at `adguard : Read AdGuard's live rewrite
table`** with `HTTP Error 404`. On 2026-09-22 it did: the task ran within a
couple of seconds of the container starting, before AdGuard had registered its
`/control` handlers, and the role does not wait for the API. A moment later the
same URL answered 401. Re-run the same command. Traefik and AdGuard are already
up by then, so DNS is back while the rest pulls.

### 7. Verify

Counts and content first:

```bash
ssh joseph@10.10.20.20
docker ps --format "{{.Names}}\t{{.Image}}" | sort > /tmp/repull-1244/containers-after.txt
diff /tmp/repull-1244/containers-before.txt /tmp/repull-1244/containers-after.txt \
  && echo "same 30 containers on the same image refs"
docker ps --filter health=unhealthy --format '{{.Names}}'   # expect empty
docker volume ls -q | sort | diff /tmp/repull-1244/volumes-before.txt - \
  && echo "all 23 volumes intact"
```

Then the digests, which is the actual point of the run:

```bash
docker ps -q | xargs docker inspect --format "{{.Config.Image}} {{.Image}}" | while read ref id; do
  printf "%s\t%s\n" "$ref" "$(docker image inspect "$id" --format "{{index .RepoDigests 0}}")"
done | sort -u > /tmp/repull-1244/digests-after.txt
diff /tmp/repull-1244/digests-before.txt /tmp/repull-1244/digests-after.txt
```

Go through each container's image **ID**, never its tag. An image pulled by
digest carries no local tag, so `docker image inspect postgres:15-alpine`
finds nothing after the re-pull — or, before it, finds whatever stale image
last held that tag, which need not be the one the container runs. On
2026-09-22 the tag lookup reported `postgres:15-alpine` as `5fe8ca7f…` while
the containers ran the pinned `f7d23353…`.

Every digest-pinned image must be **identical**. `cgr.dev/chainguard/minio` is
expected to differ. A version-tagged image that differs is a re-pushed tag —
record it on #1244 and check the service, do not wave it through.

ClickHouse is the one image that checks itself, so let it say so:

```bash
docker logs langfuse-clickhouse --tail 20 | grep -i checksum || echo "no checksum complaint"
curl -s -o /dev/null -w "langfuse %{http_code}\n" https://langfuse.bezaforge.dev
```

Then from **off** the host, since AdGuard and Traefik both restarted:

```bash
dig +short git.bezaforge.dev @10.10.20.20
for u in git pm grafana docs; do
  curl -s -o /dev/null -w "$u %{http_code}\n" "https://$u.bezaforge.dev"
done
```

And confirm the deploy still matches `main`:

```bash
python3 scripts/deploy-drift-check.py   # RESULT: CURRENT
```

Leave it here for a few hours and watch Uptime Kuma and the Discord alerts
before going on to step 8.

### 8. Reclaim the old containerd root (#982 step 8)

Only once step 7 is clean. The rename is the point — if anything still resolves
the old path, you find out with the data recoverable.

```bash
ssh joseph@10.10.20.20
sudo du -sh /var/lib/containerd
sudo mv /var/lib/containerd /var/lib/containerd.old-982
sudo systemctl reboot
```

forge-ops has not rebooted since the relocation on 2026-09-19 (uptime at the
time of writing: 12 days, since 2026-09-09). **This reboot is the first proof
that the host comes up on the new data root**, which is why #982 waited for it.

After it comes back:

```bash
ssh joseph@10.10.20.20
uptime -s
grep '^root' /etc/containerd/config.toml       # /var/lib/docker/containerd
docker ps --format '{{.Names}}' | sort | diff /tmp/repull-1244/containers-before.txt - \
  || docker ps --format '{{.Names}}' | wc -l   # expect 30
docker ps --filter health=unhealthy --format '{{.Names}}'
dig +short git.bezaforge.dev @10.10.20.20
df -h / /var/lib/docker
```

`/` will **not** have dropped yet: the rename stays on the same filesystem and
frees nothing (on 2026-09-25 it read 37 % before and after, with 46 G renamed).
It drops by about the `du` figure only at the `rm` below. Give Prometheus a
scrape interval and confirm the exporter still reports real filesystems — `/`
at ~158 GB, not ~317 GB:

Prometheus publishes no port on the host and `prometheus` resolves only on
the Docker network, so ask from inside its container (`jq` runs on the host):

```bash
docker exec prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=node_filesystem_size_bytes%7Binstance%3D%22forge-ops%22%2Cfstype%3D~%22ext4%7Cxfs%22%7D' \
  | jq -r '.data.result[] | "\(.metric.mountpoint)\t\(.metric.device)\t\(.value[1])"'
```

Only then, and not the same day:

```bash
sudo rm -rf /var/lib/containerd.old-982
```

Then `df -h /` should have dropped by about the `du` figure.

---

## Rollback

**There is no rollback once step 5 has run.** The images are gone and the only
copy is the registry's. That is deliberate — the local copy is the thing under
suspicion. If the pulls cannot proceed, the recovery is to fix connectivity and
pull again, not to restore anything.

Before step 5, the run is abandonable at any point: bring the stacks back with
step 6's `ansible-playbook` command and nothing has changed.

The old `/var/lib/containerd` stays in place until step 8's `rm`, but it is a
rollback for the **relocation**, not for the images — and after a clean step 7
it is a copy of exactly the data this run existed to replace.

---

## What this does not fix

It does not explain the corruption. It removes it. If images on forge-ops are
found damaged again, the rsync theory is wrong and the cause is live — treat a
second occurrence as a hardware question (the docker LV, its PV) and not as a
repeat of this.

It does not touch forge-erp, forge-ai or forge-agents. Nothing suggests they
are affected: the #982 copy happened only here.

It does not answer #1236. The crash of 2026-09-06 stays unexplained; step 3
decides how much of the evidence outlives this run.
