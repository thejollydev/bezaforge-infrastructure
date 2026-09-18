# Runbook — The agent team on forge-agents

Brizza ADR 0014: the team is named Hermes agents, each its own profile with
its own memory, Discord bot and credentials. This runbook covers the first
three (#1218), what you have to do by hand, and the tests the step owes.

| Piece | Where | Owner |
|---|---|---|
| Hermes | `~joseph/.hermes/hermes-agent`, pinned tag | `roles/hermes-team` |
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

### The installer, and why it is fetched rather than piped

Upstream's documented install is `curl -fsSL … | bash`. This role fetches the
script to a file with a recorded SHA-256 and runs that, following
`roles/ollama` — a streamed script executes with no way to notice upstream
changed it. **When upstream edits the installer, the fetch fails and the run
stops.** That is the intended behaviour: read the diff, then update
`hermes_installer_sha256`.

The version is pinned twice over. `hermes_version` is the tag `--branch`
asks for; `hermes_commit` is the SHA that proves the tag still points where it
did. A moved tag fails the run rather than installing something else.

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

**The fetch fails on a checksum mismatch.** Upstream changed the installer.
That is the gate doing its job — diff it, then update the recorded hash.

**`Require the pinned commit` fails.** The tag moved, or someone changed the
checkout by hand. Do not deploy agents from it until that is explained.

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
