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

Run it twice; the second reports no changes. Verified on 2026-09-20: a
converged host reports `ok=65 changed=0`, with `Set what differs` skipping
every item on all three profiles.

> **`hermes config get` is real, and it resolves rather than reads.** The
> role's read-then-set loop depends on it, and upstream's documentation still
> does not show it — it was carried as this role's known weak point until the
> run above. One thing to know about it: it prints the *effective* value,
> defaults included, not what is in `config.yaml`. A key sitting at its
> default therefore reads as already set while being absent from the file,
> which is why `Write the dispatcher key, default or not` exists alongside
> the loop. A key absent from `DEFAULT_CONFIG` prints nothing and exits 1;
> one present there but null prints `null` and exits 0.

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

**An agent answers, then fails its first tool call** with "The model
provider failed after retries." Look for HTTP 500 `no user query found in
messages` in the profile's `logs/errors.log`. That is a context-length
failure wearing a misleading error: Ollama's OpenAI-compat `/v1` endpoint
serves whatever `num_ctx` the model was built with, truncates the prompt
from the front until the user turn falls off the end, and then complains
there is no user turn.

The context CANNOT be set by the client — Hermes' `extra_body`
`{options: {num_ctx: ...}}` is accepted and ignored on `/v1`. It lives in
the `gemma4:26b-64k` Modelfile variant on forge-ai. Check the server is
serving what you think:

```bash
ssh joseph@forge-ai 'ollama ps'          # CONTEXT column, not the model's max
```

Hermes needs 64,000 tokens minimum for tool use. If `CONTEXT` reads 4096 or
32768, the variant was not built or an agent is pointed at the base model.

**An approved agent starts but every turn fails at the provider.** Its Codex
login is missing. The role refuses to start an approved agent in that state,
so this means the login was revoked after a deploy:

```bash
ssh joseph@forge-agents '~/.local/bin/hermes -p <name> auth status openai-codex'
ssh -t joseph@forge-agents '~/.local/bin/hermes auth add openai-codex'
```

**⚠️ NO `-p` ON THE SECOND ONE, AND THAT IS NOT A TYPO.** Codex is a
single-use-refresh provider (with `anthropic` and `xai-oauth`): each refresh
invalidates the previous token, so two profiles refreshing one grant would
kill each other. Hermes therefore keeps ONE grant at the root and strips
per-profile copies on read — `strip_cloned_single_use_oauth_grants` deletes
the profile's rows so `read_credential_pool` falls back to the root slice.

A per-profile `hermes -p brizza auth add openai-codex` APPEARS to work: it
prints "Added openai-codex OAuth credential #1", writes `active_provider`,
and then the grant is gone the next time anything reads it. One root sign-in
covers every profile, present and future.

Two smaller details: a non-interactive `ssh` does not source the profile that
puts `~/.local/bin` on PATH, so a bare `hermes` answers "command not found";
and `auth add` is interactive, so it needs `ssh -t`. Over SSH it prints an
authorization URL and waits for the code pasted back.

**One credential for the whole team.** Revoking it in the OpenAI account
stops all three agents at once — they are less independent than their
per-profile Discord tokens suggest.

**Everything is suddenly slower and dumber at once.** All three agents share
ONE ChatGPT account, so they exhaust the Codex allowance together and fall
back to forge-ai together. That is the design — a shared local fallback
rather than one model each, because only one ~16 GiB model fits the card and
per-agent fallbacks would evict each other. Confirm with `ollama ps` on
forge-ai showing `gemma4:26b-64k` loaded.

**Cards sit in `ready` and nothing picks them up.** One process dispatches the
whole machine's board, and it is named rather than raced for: exactly one
entry in `hermes_agents` carries `dispatch: true`, which the role writes to
that profile as `kanban.dispatch_in_gateway`. Brizza holds it. Check that her
gateway is up and that it took the lock:

```bash
ssh joseph@forge-agents 'grep "kanban dispatcher" ~/.hermes/profiles/brizza/logs/gateway.log | tail -5'
```

`holding singleton dispatcher lock` is the line you want. `another gateway
already holds the dispatcher lock` on Brizza means something else took it
first — that gateway will not retry, so restart Brizza's *after* stopping the
other. The board itself is machine-global at `~/.hermes/kanban.db`, shared by
every profile on purpose, and the dispatcher spawns each worker as the task's
assignee, so one dispatcher is not one agent doing all the work.

**A setting in `~/.hermes/config.yaml` has no effect.** It would not. Each
gateway runs with `HERMES_HOME` pointed at its own profile directory, and
Hermes reads `config.yaml` from there with no root file layered beneath it.
The root config is read only by a bare `hermes` invocation with no profile.
Settings that must reach an agent belong in
`~/.hermes/profiles/<name>/config.yaml`, which is what the role's `config set`
tasks write.

## What was in the root config, and what it cost

The whole root file was audited on 2026-09-20 (#1218), key by key, against
`hermes_cli.config.DEFAULT_CONFIG`. It is worth knowing what it turned out to
be, because the shape is what made the trap convincing.

**Sixty-nine of its ~100 leaf keys were byte-identical to the defaults** —
the entire `terminal:`, `compression:`, `tool_loop_guardrails:`, `memory:`,
`stt:`, `browser:`, `cron:`, `database:` and `runtime:` blocks, and
`kanban.review_dispatch: true`. That file was never a set of choices. An
older `hermes setup` serialised the whole default schema into it, and it has
looked load-bearing ever since. Modern Hermes would not write it:
`save_config` defaults to `strip_defaults=True`, so "schema defaults are not
written unless the user explicitly set them". Which is also why the file
stays clean once trimmed.

Of the rest, `model.*` was already written per-profile by the role,
`platform_toolsets.*` and `plugins.enabled: []` were wizard bookkeeping whose
absence equals their value, and `code_execution.timeout` /
`code_execution.max_tool_calls` were not schema keys at all — nothing reads
them, in the root file or anywhere else.

**Two keys were load-bearing and missing from every profile:**

| Key | Root said | Agents actually ran |
|---|---|---|
| `agent.max_turns` | `500` | unset, and unset is **unlimited** — `resolve_turn_limit` returns `sys.maxsize` |
| `group_sessions_per_user` | `true` | `true`, the gateway default — while ADR 0015 says `false` |

`agent.max_turns` is the one that cost something: three agents sharing one
Ollama with no iteration cap, and `tool_loop_guardrails.hard_stop_enabled`
false, so a run that stops making progress was narrated rather than stopped.
The role now writes it to every profile.

`group_sessions_per_user` changes nothing today and is left unset — see the
amendment proposed against ADR 0015.

### Trimming the root file

A one-off, not a converging task; nothing in the role manages this file.

```bash
ssh joseph@forge-agents 'cp ~/.hermes/config.yaml ~/.hermes/config.yaml.bak && cat > ~/.hermes/config.yaml' <<'EOF'
# NO GATEWAY READS THIS FILE.
#
# Every hermes-gateway-<name>.service sets HERMES_HOME to its own profile
# directory, and get_config_path() is get_hermes_home()/config.yaml with no
# root layer beneath it. Settings for an agent go in that agent's
# ~/.hermes/profiles/<name>/config.yaml, written by roles/hermes-team.
#
# What is left here governs a bare `hermes` invocation with no profile —
# you, on this host, at a prompt. Nothing else.
#
# Trimmed 2026-09-20 (#1218): the ~90 keys removed were either byte-identical
# to DEFAULT_CONFIG or read by nothing. Hermes will not put them back —
# save_config strips schema defaults on write.
model:
  # So an ad-hoc `hermes` run here stays on forge-ai's Ollama. A model name
  # without provider+base_url is the shape ADR 0014 principle 3 exists to
  # prevent: it falls through to a metered API without an error.
  default: qwen3.8:27b
  provider: custom
  base_url: http://10.10.50.10:11434/v1
updates:
  # The nightly hermes-update-release does its own snapshot and rollback.
  pre_update_backup: false
_config_version: 44
EOF
```

Then check a bare run still resolves the model, and that the agents are
untouched:

```bash
ssh joseph@forge-agents 'hermes config get model.default && hermes -p brizza config get agent.max_turns'
```

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
