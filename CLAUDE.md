# CLAUDE.md — bezaforge-infrastructure

**`AGENTS.md` is authoritative.** Read it first and follow it; everything
harness-neutral lives there on purpose, so nothing is repeated here. Only
genuinely Claude-Code-specific notes belong in this file.

## Handing over a command

`AGENTS.md` forbids writing to a `forge-*` host and requires one command per
handover message. In Claude Code that means Joseph runs it himself with the `!`
prefix, which takes exactly one command and gives it a real TTY — necessary
because `--ask-become-pass` and `--ask-vault-pass` both prompt.

Put the command in its own block, unwrapped. Never pre-wrap it as
`ssh host '…'` for him to paste.

## Never4gA is available as MCP tools

The `never4ga_*` MCP tools cover startup context, search and checkpoints without
shelling out. The CLI in `AGENTS.md` works identically; prefer whichever is
already loaded rather than doing both.
