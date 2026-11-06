# Token usage at API prices

What Claude Code, Codex and Antigravity use under a flat subscription would cost if it were billed by the token. All three log every request's token counts on the machine that ran them. `token-usage.py` reads Claude Code's and Codex's logs, prices each token type at its own list rate, and writes a summary and an HTML report. `to-langfuse.py` sends Codex's and Antigravity's to LangFuse, where Claude Code's already arrive through LangFuse's own plugin (#1334).

This runs on the workstation, not the fleet. The data is the local session history. The report reads from and writes to no host; `to-langfuse.py` writes only to LangFuse's ingestion endpoint.

## Run it

```bash
scripts/token-usage/token-usage.py
scripts/token-usage/token-usage.py --json /tmp/token-usage.json --html /tmp/token-usage.html
```

The first prints a summary. The second also writes the data and a self-contained page: `page.html` is the template, and the script inlines the data into a copy of it. **Write the outputs outside the repository.** They carry session titles and project names, and this repository is public.

| Option | Default |
|---|---|
| `--claude-dir` | `~/.claude/projects` |
| `--codex-dir` | `~/.codex/sessions` |
| `--json PATH` | not written |
| `--html PATH` | not written |

Days are counted in the machine's local timezone.

## What the report shows

- The total at API prices, per day, stacked by model.
- Share of tokens against share of cost, by token type. In agent sessions, cache reads are nearly all the tokens and most of the cost, because every step resends the whole conversation.
- How much conversation each call carried, as a histogram.
- Cost by project (the directory each session started in), and the twelve costliest sessions by title.
- Codex's runs, tokens and cost, and the highest share of the plan's 5-hour and weekly windows that any run reported.

## Send Codex and Antigravity to LangFuse

```bash
scripts/token-usage/to-langfuse.py --dry-run   # what would be sent, and its cost
scripts/token-usage/to-langfuse.py             # send what changed since the last run
```

Each session becomes one LangFuse trace, tagged `codex` or `antigravity`, and each model call one generation carrying the model, its tokens and its cost at API prices. **Nothing a session said is sent**: no prompt, reply, tool call or file content, only counts, the model, the time, the project's name and, for Codex, the working directory.

| Option | Default |
|---|---|
| `--codex-dir` | `~/.codex/sessions` |
| `--antigravity-dir` | `~/.gemini/antigravity/conversations` |
| `--dry-run` | send |
| `--all` | only files changed since the last run |
| `--show-spans N` | with `--dry-run`, print the first N spans as they would be sent |

The keys are a LangFuse API key pair for the project, read from `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_BASE_URL`, or from `~/.config/agent-usage/langfuse.env` as `KEY=value` lines. The script refuses that file unless only its owner can read it. What was sent is recorded in `~/.local/state/agent-usage/sent.json`, down to each call, so a session that has grown sends only its new calls. Trace and span ids are derived from each session and call, so sending a call again replaces it in LangFuse rather than adding to it, but only once ClickHouse next merges the table; until then LangFuse's totals count both copies. `--all` re-sends everything, and its totals read double until that merge.

Antigravity's files are read without a published schema. The script's header says which fields it takes for tokens and time, and why. A row it cannot read is reported and skipped.

## Keeping it right

- **Prices.** `CLAUDE_PRICES` and `CODEX_PRICES` in `token-usage.py`, and `GEMINI_PRICES` in `to-langfuse.py`, are copied from the providers' pricing pages, and `PRICES_FETCHED` and `GEMINI_PRICES_FETCHED` record when. Gemini's prices carry the date each applies from, because Google has announced the rise on 2027-01-01. A model missing from a table is reported on stderr and left out rather than guessed at; add it and re-run.
- **History.** Claude Code deletes transcripts after `cleanupPeriodDays` in its settings, 30 by default. The report can only go back as far as the transcripts do.
- **Not counted.** Codex's image generation is billed separately and is not in its token counts. Gemini's cache storage is billed by the hour and is not in Antigravity's. Subscription usage limits are not in Claude Code's transcripts. Clients that keep no comparable log cannot be included.
