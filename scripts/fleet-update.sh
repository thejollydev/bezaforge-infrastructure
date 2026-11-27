#!/usr/bin/env bash
# fleet-update.sh — the one weekly command (#1378).
#
#   scripts/fleet-update.sh                  pull main, then run the whole pass
#   scripts/fleet-update.sh --this-checkout  run the pass from this checkout as it is
#   scripts/fleet-update.sh --skip-ai        leave forge-ai out instead of borrowing the GPU
#
# Anything else on the command line goes to ansible-playbook unchanged, so
# `scripts/fleet-update.sh --tags resolver,health` is the after-reboot check.
#
# Works from any directory. It asks for the sudo password and the vault
# password, so it needs a real terminal.
#
# What it does before ansible/update.yml takes over:
#
#   1. Refuses anything but a clean main. Renovate merges into main on GitHub
#      during the week, so the pass has to deploy main as GitHub has it; a
#      branch or a stale checkout would put images back on old pins.
#   2. git pull --ff-only, to bring those merges down.
#   3. git push origin main, so everywhere origin pushes to has them too. A
#      failure there is reported and does not stop the pass.
#
# --this-checkout skips all three and tells the playbook to skip its own
# check. It is for testing a change to the pass from its branch.
#
# forge-ai is on demand (#103): forge-arcade holds the RX 7900 XT by default,
# and forge-ai can only run while it has the card. So when forge-ai is off the
# pass borrows the card: `gpu-handoff.sh ai` before the playbook, and
# `gpu-handoff.sh arcade` after it, whether the pass passed, failed or was
# interrupted. That adds about five minutes before the password prompts.
# It refuses while somebody is streaming from forge-arcade, read from the
# last CLIENT CONNECTED / DISCONNECTED line in Sunshine's log.
#
# Not borrowed, and forge-ai left out with --limit '!forge-ai' instead, when
#   - --skip-ai is given;
#   - a --limit/-l is given, which is a deliberately narrower pass;
#   - a stream is open (the pass stops and says so; rerun later or --skip-ai).
# Leaving it out matters: the VM play runs serial: 1, and a batch whose only
# host is unreachable ends the whole run before forge-erp and forge-ops.
#
# A host that fails does not stop the others. Ansible abandons the rest of
# the playbook when every host in a play has failed, and almost every play
# here has one host, so one failure used to end the whole pass: on 2026-11-22
# forge-ai's failure meant forge-erp, forge-files and forge-ops were never
# configured and nothing was health-checked. Now, when a pass stops before
# its last play, it runs again without the hosts that failed, up to four
# passes in all, and ends by naming them. The hosts already done converge a
# second time, which changes nothing. A run with --limit, --tags,
# --skip-tags or --start-at-task is a deliberately narrower pass and is not
# repeated. The two passwords are asked for once, kept in files only this
# user can read under $XDG_RUNTIME_DIR, and removed when the script ends.
#
# forge-arcade (Bazzite) is not in Ansible: it updates itself with uupd, and a
# new image takes effect at its next boot. A borrowed pass boots it fresh on
# the way back; otherwise the pass ends by saying if an image is waiting.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo}"

this_checkout=false
skip_ai=false
limited=false
narrowed=false
args=()
exclude=()
for arg in "$@"; do
    case "${arg}" in
        --this-checkout) this_checkout=true ;;
        --skip-ai) skip_ai=true ;;
        -l | --limit | -l* | --limit=*) limited=true; args+=("${arg}") ;;
        -t | --tags | -t* | --tags=* | --skip-tags | --skip-tags=* | --start-at-task | --start-at-task=*)
            narrowed=true; args+=("${arg}") ;;
        *) args+=("${arg}") ;;
    esac
done

# One place cleans up, whatever else the run set up.
secrets_dir=""
borrowed=false
cleanup() {
    [[ -n "${secrets_dir}" ]] && rm -rf "${secrets_dir}"
    if [[ "${borrowed}" == true ]]; then
        echo
        echo "Handing the GPU back to forge-arcade..."
        "${repo}/scripts/gpu-handoff.sh" arcade || echo "WARNING: hand-back failed; run scripts/gpu-handoff.sh arcade." >&2
    fi
}
trap cleanup EXIT

# forge-arcade has no DNS name; 10.10.40.125 is reserved for its MAC in Omada.
ARCADE="${ARCADE:-10.10.40.125}"
SUNSHINE_LOG='~/.var/app/dev.lizardbyte.app.Sunshine/config/sunshine/sunshine.log'

if [[ "${this_checkout}" == true ]]; then
    echo "Deploying this checkout as it is: $(git rev-parse --abbrev-ref HEAD) at $(git rev-parse --short HEAD)."
    args+=(-e update_require_main=false)
else
    branch="$(git rev-parse --abbrev-ref HEAD)"
    if [[ "${branch}" != "main" ]]; then
        echo "On ${branch}, not main. Switch to main, or pass --this-checkout to deploy this branch on purpose." >&2
        exit 1
    fi
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        echo "Tracked files are modified. Commit or stash them, or pass --this-checkout to deploy them on purpose." >&2
        exit 1
    fi
    git pull --ff-only origin main
    if ! git push origin main; then
        echo "WARNING: 'git push origin main' failed. Carrying on; run it again afterwards." >&2
    fi
fi

# forge-ai: borrow the card, or leave it out (see the top of this file).
ai_state="$(ssh -o BatchMode=yes -o ConnectTimeout=10 root@forge-hypervisor qm status 101 2>/dev/null | awk '{print $2}')" || true
if [[ "${ai_state}" != running ]]; then
    if [[ "${skip_ai}" == true || "${limited}" == true ]]; then
        echo "forge-ai is ${ai_state:-unknown}; leaving it out of this pass."
        [[ "${limited}" == true ]] || exclude+=(forge-ai)
    else
        last_client="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${ARCADE}" \
            "grep -o 'CLIENT \(DIS\)\?CONNECTED' ${SUNSHINE_LOG} 2>/dev/null | tail -1" 2>/dev/null)" || true
        if [[ "${last_client}" == "CLIENT CONNECTED" ]]; then
            echo "Somebody is streaming from forge-arcade, so the GPU is not borrowed for forge-ai." >&2
            echo "Close the stream and run this again, or pass --skip-ai to update everything else." >&2
            exit 1
        fi
        echo "forge-ai is ${ai_state:-unknown}; borrowing the GPU from forge-arcade for this pass."
        borrowed=true
        "${repo}/scripts/gpu-handoff.sh" ai
    fi
fi

# Every run is kept, and what it changed is printed last. The recap gives a
# count per host and nothing else; on a second run, or on a phone, the count
# is useless without the names of the tasks behind it.
log_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/fleet-update"
mkdir -p "${log_dir}"
chmod 700 "${log_dir}"
log="${log_dir}/$(date +%Y-%m-%d_%H%M%S).log"
( umask 077 && : > "${log}" )

# Both passwords once, for every pass.
secrets_dir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/fleet-update.XXXXXX")"
chmod 700 "${secrets_dir}"
read -rsp "BECOME password: " become_pass; echo
read -rsp "Vault password: " vault_pass; echo
( umask 077
  printf '%s\n' "${become_pass}" > "${secrets_dir}/become"
  printf '%s\n' "${vault_pass}" > "${secrets_dir}/vault" )
unset become_pass vault_pass

# The hosts a pass reports as failed or unreachable, from its PLAY RECAP.
failed_hosts() {
    sed -n 's/^.*| \([^ ]*\) *: ok=[0-9]* *changed=[0-9]* *unreachable=\([0-9]*\) *failed=\([0-9]*\).*$/\1 \2 \3/p' \
        | awk '$1 != "localhost" && ($2 > 0 || $3 > 0) { print $1 }'
}

rc=0
left_out=()
pass=0
while :; do
    pass=$((pass + 1))
    limit_args=()
    if (( ${#exclude[@]} > 0 )); then
        pattern="$(printf '!%s:' "${exclude[@]}")"
        limit_args=(--limit "${pattern%:}")
    fi
    start=$(wc -l < "${log}")
    rc=0
    ANSIBLE_LOG_PATH="${log}" ansible-playbook ansible/update.yml \
        --become-password-file "${secrets_dir}/become" \
        --vault-password-file "${secrets_dir}/vault" \
        "${limit_args[@]}" "${args[@]}" || rc=$?

    (( rc == 0 )) && break
    [[ "${limited}" == true || "${narrowed}" == true ]] && break
    this_pass="$(tail -n +"$((start + 1))" "${log}")"
    # Reached its last play: the failures are in the recap, nothing was skipped.
    grep -q 'PLAY \[Summarise which hosts need a reboot\]' <<< "${this_pass}" && break
    new=()
    while read -r host; do
        [[ -z "${host}" ]] && continue
        [[ " ${exclude[*]} " == *" ${host} "* ]] || new+=("${host}")
    done < <(failed_hosts <<< "${this_pass}")
    (( ${#new[@]} > 0 )) || break
    (( pass < 4 )) || break
    echo
    echo "The pass stopped at a failure on: ${new[*]}."
    echo "Running it again without them, so every other host is still updated and checked."
    echo
    exclude+=("${new[@]}")
    left_out+=("${new[@]}")
done

echo
echo "What changed (the task, then the hosts):"
awk '
    / (TASK|RUNNING HANDLER) \[/ { sub(/^.* (TASK|RUNNING HANDLER) \[/, ""); sub(/\] \**$/, ""); task = $0 }
    / changed: \[/ {
        host = $0; sub(/^.* changed: \[/, "", host); sub(/\].*$/, "", host)
        if (!((task, host) in seen)) { seen[task, host] = 1; hosts[task] = hosts[task] " " host }
        if (!(task in order)) { order[task] = ++n; name[n] = task }
    }
    END {
        if (n == 0) print "  nothing"
        for (i = 1; i <= n; i++) printf "  %s:%s\n", name[i], hosts[name[i]]
    }
' "${log}"
echo "Full log: ${log}"

if (( ${#left_out[@]} > 0 )); then
    echo
    echo "LEFT OUT after failing: ${left_out[*]}. Every other host was updated and checked."
    echo "The error is in the log above each host's first fatal: line. Once it is fixed:"
    echo "  scripts/fleet-update.sh --limit $(IFS=,; echo "${left_out[*]}")"
    (( rc == 0 )) && rc=1
fi

if [[ "${borrowed}" != true ]]; then
    # rpm-ostree exits 77 when a downloaded image is waiting for a boot.
    arcade_rc=0
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${ARCADE}" rpm-ostree status --pending-exit-77 >/dev/null 2>&1 || arcade_rc=$?
    case "${arcade_rc}" in
        0) echo "forge-arcade: on its newest image." ;;
        77) echo "forge-arcade: a new Bazzite image is waiting; it takes effect when forge-arcade next boots." ;;
        *) echo "forge-arcade: not reachable, so its image was not checked." ;;
    esac
fi
exit "${rc}"
