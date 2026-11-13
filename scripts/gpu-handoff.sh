#!/usr/bin/env bash
# gpu-handoff.sh — move the RX 7900 XT between forge-ai and forge-arcade (#103).
#
#   scripts/gpu-handoff.sh arcade   stop forge-ai (Ollama, ComfyUI), start forge-arcade
#   scripts/gpu-handoff.sh ai       stop forge-arcade, start forge-ai, wait for Ollama
#
# Both VMs declare the same card (the `rx7900xt` cluster mapping). Proxmox holds
# both configs but only one VM may run with it, so the hand-off is: stop the
# holder, confirm it is stopped, start the other. Proven with no host reboot on
# 2026-07-31; Proxmox logs "Inappropriate ioctl for device" on every start, which
# is benign (vfio-pci does its own secondary-bus reset).
#
# Why a script and not a role: it changes which VM is running, which is an
# operational act run by hand, not configuration. Terraform ignores both VMs'
# power state for the same reason (`ignore_changes = [started]`).
#
# Runs on the workstation, over SSH to forge-hypervisor as root. It writes to
# the hypervisor (VM power state), so it is run by Joseph, never by an agent.
#
# Shutting forge-arcade down: Bazzite has no guest agent, so the stop is an ACPI
# power-button press. KDE may answer it with its logout screen, so the script
# waits SHUTDOWN_TIMEOUT seconds and then forces the stop. Powering off from
# inside Bazzite first is the gentler way; the script then finds it stopped.
#
# While forge-ai is off, Grafana's Host Down and Ollama Down alerts fire in
# Discord. That is expected for a gaming session.

set -euo pipefail

HYPERVISOR="${HYPERVISOR:-root@forge-hypervisor}"
AI_VMID=101
ARCADE_VMID=105
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-180}"
OLLAMA_WAIT="${OLLAMA_WAIT:-300}"

usage() {
    echo "usage: $(basename "$0") arcade|ai" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage
case "$1" in
    arcade) from_vmid=$AI_VMID; from_name=forge-ai; to_vmid=$ARCADE_VMID; to_name=forge-arcade ;;
    ai) from_vmid=$ARCADE_VMID; from_name=forge-arcade; to_vmid=$AI_VMID; to_name=forge-ai ;;
    *) usage ;;
esac

hv() { ssh -o BatchMode=yes "${HYPERVISOR}" "$@"; }

status() {
    # `qm status` prints "status: running"; anything else is reported as it is.
    hv qm status "$1" | awk '{print $2}'
}

to_status="$(status "${to_vmid}")"
from_status="$(status "${from_vmid}")"
echo "now: ${from_name} ${from_status}, ${to_name} ${to_status}"

if [[ "${to_status}" == running ]]; then
    echo "${to_name} already has the card; nothing to do."
    exit 0
fi

case "${from_status}" in
    running)
        echo "stopping ${from_name} (up to ${SHUTDOWN_TIMEOUT}s, then forced)..."
        hv qm shutdown "${from_vmid}" --timeout "${SHUTDOWN_TIMEOUT}" --forceStop 1
        ;;
    stopped) ;;
    *)
        echo "${from_name} is '${from_status}', not running or stopped; stopping here." >&2
        exit 1
        ;;
esac

from_status="$(status "${from_vmid}")"
if [[ "${from_status}" != stopped ]]; then
    echo "${from_name} is still '${from_status}'; not starting ${to_name}." >&2
    exit 1
fi

echo "starting ${to_name}..."
hv qm start "${to_vmid}"
to_status="$(status "${to_vmid}")"
if [[ "${to_status}" != running ]]; then
    echo "${to_name} is '${to_status}' after start." >&2
    exit 1
fi

if [[ "${to_name}" == forge-ai ]]; then
    echo "waiting up to ${OLLAMA_WAIT}s for Ollama on forge-ai..."
    deadline=$((SECONDS + OLLAMA_WAIT))
    until ssh -o BatchMode=yes -o ConnectTimeout=5 forge-ai systemctl is-active --quiet ollama 2>/dev/null; do
        if ((SECONDS >= deadline)); then
            echo "Ollama is not active after ${OLLAMA_WAIT}s; check forge-ai." >&2
            exit 1
        fi
        sleep 10
    done
    echo "done: forge-ai running, Ollama active."
else
    echo "done: forge-arcade running with the card. It takes its address from DHCP on VLAN 40;"
    echo "its MAC is $(hv qm config "${to_vmid}" | sed -n 's/^net0: virtio=\([^,]*\),.*/\1/p')."
fi
