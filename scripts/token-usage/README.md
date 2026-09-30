# Token usage at API prices

What Claude Code and Codex use under a flat subscription would cost if it were
billed by the token. Both clients already log every request's token counts on
the machine that ran them; `token-usage.py` reads those logs, prices each token
type at its own list rate, and writes a summary and an HTML report (#1334).

This runs on the workstation, not the fleet. The data is the local session
history, and nothing here reads from or writes to a host.

## Run it

```bash
scripts/token-usage/token-usage.py
scripts/token-usage/token-usage.py --json /tmp/token-usage.json --html /tmp/token-usage.html
```

The first prints a summary. The second also writes the data and a
self-contained page: `page.html` is the template, and the script inlines the
data into a copy of it. **Write the outputs outside the repository.** They
carry session titles and project names, and this repository is public.

| Option | Default |
|---|---|
| `--claude-dir` | `~/.claude/projects` |
| `--codex-dir` | `~/.codex/sessions` |
| `--json PATH` | not written |
| `--html PATH` | not written |

Days are counted in the machine's local timezone.

## What the report shows

- The total at API prices, per day, stacked by model.
- Share of tokens against share of cost, by token type. In agent sessions,
  cache reads are nearly all the tokens and most of the cost, because every
  step resends the whole conversation.
- How much conversation each call carried, as a histogram.
- Cost by project (the directory each session started in), and the twelve
  costliest sessions by title.
- Codex's runs, tokens and cost, and the highest share of the plan's 5-hour
  and weekly windows that any run reported.

## Keeping it right

- **Prices.** `CLAUDE_PRICES` and `CODEX_PRICES` are copied from the providers'
  pricing pages, and `PRICES_FETCHED` records when. A model missing from either
  table is reported on stderr and left out of the totals rather than guessed at;
  add it and re-run.
- **History.** Claude Code deletes transcripts after `cleanupPeriodDays` in its
  settings, 30 by default. The report can only go back as far as the transcripts
  do.
- **Not counted.** Codex's image generation is billed separately and is not in
  its token counts. Subscription usage limits are not in Claude Code's
  transcripts. Clients that keep no comparable log cannot be included.
