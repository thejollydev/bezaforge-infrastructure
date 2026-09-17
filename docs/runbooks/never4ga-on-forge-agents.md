# Runbook — Never4gA on forge-agents

The agent host reads the knowledge vault through Never4gA, the same way every
other harness does (Brizza ADR 0016). This runbook covers the first
deployment (#1217), the tests that prove it, and what to do when something
goes wrong.

| Piece | Where | Owner |
|---|---|---|
| The package | `/opt/never4ga/venv`, root-owned | `roles/never4ga` |
| On `PATH` | `/usr/local/bin/never4ga`, `never4ga-mcp` | symlinks into the venv |
| Configuration | `~joseph/.config/never4ga/config.toml` | templated |
| Index and databases | `~joseph/.local/share/never4ga/` | the service |
| State | `~joseph/.local/state/never4ga/` | the service |
| The service | `never4ga.service`, `systemd --user` as `joseph` | unit templated, control by `systemctl --user` |

Two properties are worth stating before anything else, because both are
easy to undo by accident.

- **The vault on this host is a replica.** It arrives by Syncthing and the
  laptop is the only git actor (ADR 0019). `repair --apply` is never run
  here: a repair written on a replica races the laptop over the same
  documents and lands on it as a `.sync-conflict` copy. Fix doctor findings
  on the laptop and let them sync down.
- **The derived databases live outside the vault**, which is where
  Never4gA puts them by default and no configuration key moves. The role
  asserts it on every run, because the failure is silent: an index inside
  the vault would sync to all three copies and they would fight over one
  write-ahead log.

## Why the install is a wheel and not a clone

Never4gA is unreleased — `0.1.0.dev0` — in a private repository, and this
host holds no credential for it and is not given one. So the artifact is a
wheel built on the laptop and pushed by Ansible from there.

The wheel is **not committed to this repository**, which is public. The
`never4ga_wheel` variable is a path on the machine running
`ansible-playbook`.

Build it first:

```bash
cd ~/Projects/never4ga && python -m build --wheel
```

`--force-reinstall` is used on the host deliberately. Every build carries the
same `0.1.0.dev0`, so pip would find that version already installed and do
nothing; the wheel's bytes changing is the signal, not its version string.

## Deploying it

Every `ansible-playbook` command prompts for a become password and the vault
password.

```bash
cd ~/Projects/bezaforge-infrastructure/ansible
ansible-playbook site.yml --limit forge-agents --tags never4ga --check --diff --ask-become-pass --ask-vault-pass
ansible-playbook site.yml --limit forge-agents --tags never4ga --ask-become-pass --ask-vault-pass
```

Run it twice. The second run reports no changes, which is the role's
idempotence test.

### What the first run does that later ones do not

- Installs `python3.14-venv`. Ubuntu keeps `ensurepip` in that package
  rather than the standard library, so `python3 -m venv` fails without it
  with `ModuleNotFoundError: No module named 'ensurepip'`.
- Enables lingering for `joseph` (`loginctl enable-linger`). Nobody logs
  into this host, so without it the user manager never starts and the unit
  would be enabled against a manager that does not exist.

## The tests

Step 4 of the Brizza build plan owes two, and the role runs both read-only
at the end of every converged run rather than once at acceptance.

**1. `doctor` is clean.** The role fails if it is not.

```bash
ssh joseph@forge-agents never4ga doctor
```

**2. `context startup` from a mapped repository returns the Brizza pack.**

```bash
ssh joseph@forge-agents 'cd /home/joseph/Projects/brizza && never4ga --actor <client>/<model> context startup --client <client> --cwd "$PWD"'
```

> **This one cannot pass yet, and the role skips it rather than pretending.**
> There is no checkout of any project repository on this host, and no
> credential to make one: the repositories are private and `git ls-remote`
> over HTTPS from the host answers `could not read Username`. Filling
> `never4ga_mappings` and `never4ga_verify_repo` in `host_vars` turns the
> check on the moment that is resolved. Until then step 4 is half proven:
> Never4gA is installed and reads the vault, and no repository resolves to a
> workspace from this host.

## What is deliberately absent

- **No vault-commit timer.** The laptop's 15-minute commit picks up whatever
  this host writes. A committer here would race it over a working tree
  Syncthing is writing underneath both of them — and `.git` is in the ignore
  patterns, so this copy has no git identity to commit with anyway.
- **No MCP registration.** `never4ga adapters mcp` registers with the
  clients it detects, and its client descriptors are data rather than code:
  the shipped three live in the package and a machine's own live in the
  vault's `50_System/Integrations/`. A descriptor for the agent runtime
  needs that runtime installed to measure its `mcp add` command against, and
  that arrives in build step 5. See the note in the tracker item.
- **No `repair --apply`.** As above. It is not a default that can be
  overridden in `host_vars`; the role simply never calls it.

## When something goes wrong

**The role refuses with "has no index.md".** The vault has not finished
syncing, or `syncthing@joseph` is not running. That refusal is deliberate:
Never4gA would read an empty directory as a new vault and initialise it.

```bash
ssh joseph@forge-agents systemctl status syncthing@joseph
```

**The service will not start.** The unit is a `systemd --user` one, so it
needs the user manager, which needs lingering.

```bash
ssh joseph@forge-agents 'systemctl --user status never4ga.service; loginctl show-user joseph -p Linger'
ssh joseph@forge-agents 'journalctl --user -u never4ga.service -n 50'
```

**`doctor` reports findings.** Fix them on the laptop. They sync down.

The first run is where this is found out: `doctor` has never been run against
a replica of this vault before, so if it reports something that is a fact
about *this host* rather than about the vault — a mapping to a repository that
is not here, a client pointer that was never deployed — that is a finding
about the check, not a fault to repair. Record it and narrow the assertion
rather than running `repair --apply` to make it quiet.

**Searches miss a document another machine wrote.** The service owns the
index and reconciles what its watcher sees; on this host documents arrive by
sync rather than from a local editor, which is the reason the service runs
here at all. Check it is up before reaching for `never4ga index`.
