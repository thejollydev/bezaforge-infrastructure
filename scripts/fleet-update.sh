#!/usr/bin/env bash
# fleet-update.sh — the one weekly command (#1378).
#
#   scripts/fleet-update.sh                  pull main, then run the whole pass
#   scripts/fleet-update.sh --this-checkout  run the pass from this checkout as it is
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

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo}"

this_checkout=false
args=()
for arg in "$@"; do
    if [[ "${arg}" == "--this-checkout" ]]; then
        this_checkout=true
    else
        args+=("${arg}")
    fi
done

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

exec ansible-playbook ansible/update.yml --ask-become-pass --ask-vault-pass "${args[@]}"
