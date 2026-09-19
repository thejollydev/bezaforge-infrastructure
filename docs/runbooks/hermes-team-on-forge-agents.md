# Runbook — The agent team on forge-agents

Brizza ADR 0014: the team is named Hermes agents, each its own profile with
its own memory, Discord bot and credentials. This runbook covers the first
three (#1218), what you have to do by hand, and the tests the step owes.

| Piece | Where | Owner |
|---|---|---|
| Hermes | `~joseph/.hermes/hermes-agent`, newest release | `roles/hermes-team`, then the nightly updater |
| On `PATH` | `~joseph/.local/bin/hermes`, plus `<name>` per profile | the installer |
| A profile | `~joseph/.hermes/profiles/<name>/` | the role |
| A soul | that profile's `SOUL.md` | templated from the role card |
| Credentials | that profile's `.env` | **you, by hand** |
| A gateway | `hermes-gateway-<name>.service`, `systemd --user` | the role, started only on approval |

## Three things the role will not do

**It writes no Discord token.** Not in git, not ansible-vault'd, not
templated. Every other secret in this fleet lives in
`group_vars/all/vault.yml`, and this one deliberately does not: step 5 asks
that the role never hold a token in git, and encrypted-in-git is still in
git. The credential reaches the host through `hermes setup` or your own hand,
and the role's only job is to notice whether it is there.

**It starts no agent.** ADR 0014 principle 2 — nothing runs until you approve
its first run. A gateway starts only for an agent whose `host_vars` entry says
`approved: true` *and* whose token is present. Everything else gets a profile
and waits, which is the normal state between one Discord application and the
next.

**It does not run `hermes setup`.** That is interactive, and it asks for a
model and tokens — one of which the role has opinions about and the other of
which it refuses to hold.

## Before the first run: create Brizza's Discord application

In the [Discord developer portal](https://discord.com/developers/applications),
one application per agent. **Enable both privileged intents:**

- **Message Content Intent** — without it the bot receives message events
  whose text is empty. It is not a degraded mode; the bot literally cannot
  see what you typed.
- **Server Members Intent** — username resolution and role checks.

Then put the token on the host. The `.env` already exists — the role writes
the non-secret settings into it (`DISCORD_ALLOWED_USERS`, the backfill and
bot settings, the timeouts) and leaves one line for you. **Add a
`DISCORD_BOT_TOKEN=` line and change nothing else**; the role edits only its
own keys and never touches that line.

```bash
ssh joseph@forge-agents
nano ~/.hermes/profiles/brizza/.env    # add: DISCORD_BOT_TOKEN=...
```

Also set `hermes_discord_allowed_users` in `host_vars` to your Discord user ID.
Without it every agent denies every message, yours included, and the role
refuses to start an approved agent rather than let it come up silent.

The profile has to exist first, so the order is: run the role once, create the
application, place the token, set your user ID and `approved: true`, run the
role again.

**Paid-provider keys are refused.** If a profile's `.env` ever holds
`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or `NOUS_API_KEY`,
the run fails. That is deliberate: a misrouted request can only bill if there
is a key to bill with.

## Deploying it

```bash
cd ~/Projects/bezaforge-infrastructure/ansible
ansible-playbook site.yml --limit forge-agents --tags hermes-team --ask-become-pass --ask-vault-pass
```

Run it twice; the second reports no changes.

> **Watch the second run for one task.** `Set what differs` depends on
> `hermes config get`, which the documentation does not show and which could
> not be verified before Hermes existed anywhere. If that task reports
> `changed` on a converged host, the subcommand is not there, and the fix is
> to read `config.yaml` directly instead. That is the known weak point of
> this role.

### Staying current

**Hermes follows its newest published release, automatically.** Nothing in
the role names a version. Joseph chose this on 2026-09-18 over pinning (which
falls behind) and over following upstream's `main` (a hundred-plus unreleased
commits a day).

- **Nightly at 04:00** `hermes-update.timer` runs
  `~/.local/bin/hermes-update-release`. `Persistent=true`, so a night the host
  was off is caught up at the next boot.
- **Every deploy** runs the same script, so a deploy is also an update and
  there is one definition of "current".
- **What it does:** asks GitHub for the newest release; if Hermes is already
  on it, exits. Otherwise fetches that release, reinstalls dependencies
  exactly as the installer does (`uv sync --locked`, which checks every
  package against the SHA-256 in that release's lockfile), runs
  `hermes config migrate` on every profile, and restarts agents that were
  already running. Agents that are not running stay stopped.
- **If any step fails, it rolls back** to the previous version and exits
  non-zero. The unit is left failed, and the fleet's failed-unit alert
  reports it — a night the update did not happen is never silent.

Why not `hermes update`: it follows a branch (fetches `origin/<branch>` and
resets to it), so it cannot target a release, and upstream keeps no branch
that tracks releases.

```bash
ssh joseph@forge-agents 'systemctl --user list-timers hermes-update.timer'
ssh joseph@forge-agents 'journalctl --user -u hermes-update.service -n 30'
```

The installer runs only for a first install, fetched fresh from upstream at
the newest release with no checksum: a recorded hash of a script upstream
edits routinely was a version pin in disguise.

## The tests this step owes

None of these can be automated in the role — they need Discord applications
and a person. They are the step's done-when, so they are a checklist rather
than a suggestion.

**Done when:**

- [ ] You ask Brizza for something in Discord and get it.
- [ ] A research task goes Samuel → Malachi → you on the studio board.

**Owed from the design (ADR 0015):**

- [ ] Whether `DISCORD_HISTORY_BACKFILL` includes **other bots'** replies.
      Default on, 50 messages. ADR 0015 relies on this for several agent bots
      in one server, and says to test it before relying on it.
- [ ] A Bot Mode room with three agents.
- [ ] An agent-to-agent message across profiles.

## When something goes wrong

**`hermes-update.service` is failed.** The nightly update could not move to
the newest release and rolled back. Its journal says which step failed:

```bash
ssh joseph@forge-agents 'journalctl --user -u hermes-update.service -n 50'
```

**A gateway will not start.** It is a `systemd --user` unit, so it needs the
user manager, which needs lingering.

```bash
ssh joseph@forge-agents 'systemctl --user status hermes-gateway-brizza.service'
ssh joseph@forge-agents 'journalctl --user -u hermes-gateway-brizza.service -n 50'
```

**Two agents fight over one identity.** If two profiles are given the same bot
token, the second gateway is blocked with an error naming the conflicting
profile. Never point two processes at one profile either — both write memory
automatically and they corrupt each other. The role refuses a repeated name in
`hermes_agents` for that reason.

## What ADR 0015 says, and what upstream now says

The role sets `DISCORD_ALLOW_BOTS=none`, which is both Hermes' default and
ADR 0015's decision: the ADR found bot-to-bot conversation unusable because
`mentions` made two bots loop, Discord auto-mentioning the author on every
reply.

Upstream now documents bot-to-bot handoffs at `mentions` or `all`, with
`DISCORD_BOTS_REQUIRE_INLINE_MENTION` (default `true`) requiring an explicit
tag rather than a reply ping — which is a guard against exactly that loop.
That is ADR 0015's own stated revisit condition. It is Joseph's to rule on,
and until he does, the agents coordinate through the board and Bot Mode rooms
as decided.
