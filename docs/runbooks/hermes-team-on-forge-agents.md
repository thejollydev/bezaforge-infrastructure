# Runbook — The agent team on forge-agents

Brizza ADR 0014: the team is named Hermes agents, each its own profile with
its own memory, Discord bot and credentials. This runbook covers the first
three (#1218), what you have to do by hand, and the tests the step owes.

| Piece | Where | Owner |
|---|---|---|
| Hermes | `~joseph/.hermes/hermes-agent`, newest release | `roles/hermes-team`, then the nightly updater |
| On `PATH` | `~joseph/.local/bin/hermes`, plus `<name>` per profile | the installer |
| A profile | `~joseph/.hermes/profiles/<name>/` | the role |
| A soul | that profile's `SOUL.md` | copied from the role card in the private brizza repository (`team/souls/`) |
| The roster | `team/roster.yml` in the private brizza repository: every agent, its role card, model and approval | **you, in brizza**, through a PR |
| Credentials | that profile's `.env` | **you, by hand** |
| The gateway | `hermes-gateway.service`, `systemd --user`: **one for the whole team**, run from the default profile `~joseph/.hermes` (Brizza ADR-0024) | the role |
| Approval | `gateway.parked` in a profile the roster has not approved; the gateway skips it | the role, from the roster |

## Three things the role will not do

**It writes no Discord token.** Not in git, not ansible-vault'd, not
templated. Every other secret in this fleet lives in
`group_vars/all/vault.yml`, and this one deliberately does not: step 5 asks
that the role never hold a token in git, and encrypted-in-git is still in
git. The credential reaches the host through `hermes setup` or your own hand,
and the role's only job is to notice whether it is there.

**It starts no agent.** ADR 0014 principle 2 — nothing runs until you approve
its first run. One gateway serves every profile on the host (Brizza
ADR-0024), so an agent is kept from running by **parking** it: the role puts
a `gateway.parked` marker in every profile whose roster entry does not say
`approved: true`, and the gateway skips any profile carrying one. An approved
agent is unparked, and it has a bot to answer with once its token is in its
`.env`. Everything else gets a profile and waits, which is the normal state
between one Discord application and the next.

The gateway rescans profiles every 30 seconds, so parking, unparking and a
newly placed token all take effect without a restart.

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
application, place the token, set your user ID, set `approved: true` in the
roster, run the role again.

### Every new agent needs its own channel overwrite

The agent channels are private: `@everyone` is denied **View Channel**, and
the one role allowed in is the agent's own. That role is created by Discord
when the bot is invited, so it does not exist until the invite goes through —
and nothing grants the new agent its own channel until you say so.

**Invite first, then open the channel to the new role.** In the agent's
channel → Edit Channel → Permissions:

- the new agent's role → View Channel **allow**
- every other agent's role → no overwrite, or an explicit deny

Both end in the same place, because falling through to `@everyone` is already
a denial; an explicit deny only states it. Agents do not read each other's
channels — they coordinate through the board (ADR 0020) and Bot Mode rooms.

Malachi hit this on 2026-09-20: his channel carried an allow for *Brizza's*
role, left from when she was the only agent, and nothing for his own. He
would have come online unable to see the one channel he was for.

**The invite's permission integer barely matters here.** `@everyone` in the
Forge Agents server grants a superset of everything the bot roles carry, so
every agent's effective permissions come out the same whatever you tick —
Brizza and Samuel were in fact invited with different sets and behave
identically. Discord's consent screen also hides permissions `@everyone`
already grants, so it will list fewer than you expect. That is cosmetic. The
channel overwrite is the part that decides what an agent can actually reach.

**Paid-provider keys are refused.** If a profile's `.env` ever holds
`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or `NOUS_API_KEY`,
the run fails. That is deliberate: a misrouted request can only bill if there
is a key to bill with.

## Converting to one gateway (once)

Until Hermes v2026.9.24 each agent ran its own gateway,
`hermes-gateway-<name>.service`. That release serves every profile from one
gateway per host and refuses `hermes -p <name> gateway install` (rc 78), so
the team moved to one (Brizza ADR-0024). A host converts once, by hand,
**before** the role is deployed; the role refuses to run while any
`hermes-gateway-<name>.service` remains, because that gateway and the shared
one would both answer the same bot.

On forge-agents, in your own terminal, as `joseph`:

```bash
hermes gateway migrate --multiplex
```

It checks first (no two profiles share a bot token, every profile's config
loads), writes a manifest to `~/.hermes/gateway_migration.json`, sets
`gateway.multiplex_profiles: true` in the root config, stops, disables and
deletes each `hermes-gateway-<name>.service`, then installs and starts
`hermes-gateway.service` and waits up to 90 seconds for it to serve every
profile. It asks before acting when it has a terminal. If it is interrupted,
run it again: it resumes from the manifest. Then deploy the role, which moves
the board's caps to the root config, writes the timeouts to the root `.env`
and removes the board settings the profiles no longer use.

Until that deploy the board runs on Hermes' defaults (no per-agent cap, a
global cap of 8). It is minutes, and nothing is lost.

A newly built host needs none of this: the role installs
`hermes-gateway.service` itself.

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
> which is why `Write the dispatcher key for the host, default or not`
> exists beside the loop. A key absent from `DEFAULT_CONFIG` prints nothing
> and exits 1; one present there but null prints `null` and exits 0.

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
  `hermes config migrate` on every profile, and restarts
  `hermes-gateway.service` if it is running. Parked agents stay parked.
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

## How the agents reach the vault

Each profile carries one MCP server, `never4ga`, written into its
`config.yaml` by the role (#1217, Brizza ADR 0016):

```yaml
mcp_servers:
  never4ga:
    command: /usr/local/bin/never4ga-mcp
    args: [--vault, /home/joseph/Vaults/never-knowledge, --actor, hermes-<agent>/<model>]
    tools:
      exclude: [never4ga_work_create, never4ga_work_update, never4ga_work_comment]
    enabled: true
```

- **`--actor`** names the agent, so a document it writes into the vault
  records who wrote it rather than `mcp/never4ga`.
- **The three tracker-writing tools are excluded** (ADR 0020): OpenProject is
  written by the sync (Build 7) and by Joseph, not by an agent directly.
  Reading the tracker, and reading and writing the vault, stay.
- **Written with `config set`, not `hermes mcp add`**, which prompts for tool
  selection and for overwriting and has no flag for either. The entry is
  compared whole and replaced whole, so an interactive edit is undone on the
  next run rather than lingering.
- **Tested on every run** with `hermes -p <agent> mcp test never4ga`, which
  starts the server as the gateway would. A change here restarts the
  gateway, as any profile setting does.

```bash
ssh joseph@forge-agents '~/.local/bin/brizza mcp list; ~/.local/bin/brizza mcp test never4ga'
```

## Giving the team work

Tell Brizza, in `#brizza`, in plain words:

> Have Samuel find out what our ChatGPT Plus plan allows on Codex, and have
> Malachi check it.

She puts it on the board as a card assigned to Samuel, whose work goes to
Malachi for review. Because she created the card from your chat, she is woken
when it finishes and brings you the result and Malachi's verdict there. No
CLI is involved.

That rests on two things the role sets up. Brizza has the `kanban` toolset on
Discord, and she is the only one who does: the roster's `orchestrates` key.
Her role card also says to route another agent's work to the board rather
than do it herself. Talking to Samuel or Malachi directly still works, and it
gets you a quick answer in chat that is off the board and unreviewed.

**After a change to an agent's toolsets, send `/reset` in its channel.** The
gateway restart reloads the configuration, but a conversation already under
way keeps the tool schemas it started with. A Brizza who says she cannot
create tasks, the first time after this was deployed, is that.

To watch the board from the host:

```bash
ssh joseph@forge-agents 'hermes kanban list'
```

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

## Renaming an agent

`hermes profile rename <old> <new>` does most of it. It moves
`~/.hermes/profiles/<old>/` to `<new>/`, so memory, sessions, the `.env` token,
the Codex login and a `gateway.parked` marker travel with the profile. It also
replaces the `<old>` wrapper on `PATH` and moves Hermes' own session and
routing state to the new name. Nothing has to be copied across by hand.

In order:

1. **In brizza**, set the agent's roster entry to `approved: false` and
   deploy, which parks it. The agent goes offline here and stays offline
   until step 6.
2. **On forge-agents**, as the admin user: `hermes profile rename <old> <new>`.
3. **In brizza**, the roster entry and the role card carry the new name, still
   `approved: false`. Land it and have the laptop's brizza checkout on that
   commit, because the role reads the checkout, not the remote.
4. **Deploy the role.** It writes the new soul and replaces the Never4gA
   server entry, so the agent writes as `hermes-<new>/<model>` from then on.
   What it wrote before keeps `hermes-<old>`.
5. **On Discord**, rename the application, the bot's username, its channel
   and its role. The token does not change, and the channel's permission
   overwrite follows the role, not its name.
6. **Set `approved: true`** in the roster and deploy again. The role unparks
   the profile and the gateway serves it within 30 seconds.

## When something goes wrong

**`hermes-update.service` is failed.** The nightly update could not move to
the newest release and rolled back. Its journal says which step failed:

```bash
ssh joseph@forge-agents 'journalctl --user -u hermes-update.service -n 50'
```

**The gateway will not start.** It is a `systemd --user` unit, so it needs the
user manager, which needs lingering. One unit serves the whole team, so when
it is down every agent is.

```bash
ssh joseph@forge-agents 'systemctl --user status hermes-gateway.service'
ssh joseph@forge-agents 'journalctl --user -u hermes-gateway.service -n 50'
```

**One approved agent does not answer.** Look for a park marker, then for the
gateway saying it skipped the profile:

```bash
ssh joseph@forge-agents 'ls ~/.hermes/profiles/*/gateway.parked'
ssh joseph@forge-agents 'journalctl --user -u hermes-gateway.service -n 200 | grep -i parked'
```

A marker on an approved agent means the roster the role last read did not
approve it; deploy again from an up-to-date brizza checkout. `hermes -p <name>
gateway stop` also parks a profile, and `hermes -p <name> gateway start`
unparks it, but the role puts the roster's answer back on its next run.

**Two agents fight over one identity.** Two profiles must never share a bot
token: `hermes gateway migrate` refuses to run while they do. Never point two processes at one profile either — both write memory
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

**Cards sit in `ready` and nothing picks them up.** The gateway dispatches the
whole machine's board, reading `kanban.dispatch_in_gateway` from the ROOT
config, where the role writes it as `true`. Check that the gateway is up and
that it took the lock:

```bash
ssh joseph@forge-agents 'journalctl --user -u hermes-gateway.service -n 500 | grep "kanban dispatcher" | tail -5'
```

`holding singleton dispatcher lock` is the line you want. `another gateway
already holds the dispatcher lock` means a second gateway is running on the
host, which should not exist: look for a leftover per-agent unit. The board
itself is machine-global at `~/.hermes/kanban.db`, shared by every profile on
purpose, and the dispatcher spawns each worker as the task's assignee, so one
dispatcher is not one agent doing all the work.

**A setting has no effect.** Check which file it belongs in. Since ADR-0024
the gateway runs from the default profile, so the root `~/.hermes/config.yaml`
and `.env` are its own:

- **Per agent**, read from `~/.hermes/profiles/<name>/` on each turn: model
  and fallback, `agent.max_turns`, memory approval, MCP servers, toolsets, and
  the Discord settings and token in `.env`.
- **Host-wide**, read from the root only: `kanban.*`,
  `group_sessions_per_user`, and the process environment, which is where a
  served turn reads `HERMES_API_TIMEOUT` and `HERMES_STREAM_READ_TIMEOUT`.
  Board workers are separate processes and read those two from their
  profile's `.env`, so the role writes them in both places.

Measured in the v2026.9.24 source on 2026-09-30, for #1345.

## What was in the root config, and what it cost

> **History, from before ADR-0024.** Everything below assumes no gateway
> read the root file, which stopped being true when the team moved to one
> gateway run from the default profile. The audit still explains what the
> root file is; the trim is not to be repeated.

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

A one-off, done on 2026-09-20, and **not to be run again**: its header comment
is wrong since ADR-0024, and the role now manages some of this file's keys.

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
