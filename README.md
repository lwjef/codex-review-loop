# review-loop

A Claude Code plugin that adds an automated code review loop to your workflow.

## What it does

When you use `/review-loop`, the plugin creates a two-phase lifecycle:

1. **Task phase**: You describe a task, Claude implements it
2. **Review phase**: When Claude finishes, the stop hook automatically runs [Codex](https://github.com/openai/codex) for an independent code review, then asks Claude to address the feedback

The result: every task gets an independent second opinion before you accept the changes.

## Review coverage

The Codex review covers:

- **Code quality** — organization, modularity, DRY, naming
- **Test coverage** — new tests, edge cases, test quality
- **Security** — input validation, injection, secrets, OWASP top 10
- **Documentation & agent harness** — AGENTS.md, CLAUDE.md symlinks, telemetry, type system, agent guardrails
- **UX & design** (for UI projects) — E2E tests, visual quality, accessibility

## Requirements

- [Claude Code](https://claude.ai/code) (CLI)
- `jq` — `brew install jq` (macOS) / `apt install jq` (Linux)
- [Codex CLI](https://github.com/openai/codex) (recommended) — `npm install -g @openai/codex`. Without Codex, the plugin falls back to asking Claude to self-review.

## Installation

From the CLI:

```bash
claude plugin marketplace add hamelsmu/claude-review-loop
claude plugin install review-loop@hamel-review
```

Or from within a Claude Code session:

```
/plugin marketplace add hamelsmu/claude-review-loop
/plugin install review-loop@hamel-review
```


## Usage

### Start a review loop

```
/review-loop Add user authentication with JWT tokens and test coverage
```

Claude will implement the task. When it finishes, the stop hook:
1. Runs `codex exec` for an independent review
2. Writes findings to `reviews/review-<id>.md`
3. Blocks Claude's exit and asks it to address the feedback
4. Claude addresses items it agrees with, then stops

### Cancel a review loop

```
/cancel-review
```

### What happens if Codex isn't installed?

The plugin gracefully falls back to asking Claude to self-review its changes.

## How it works

The plugin uses a **Stop hook** — Claude Code's mechanism for intercepting agent exit. When Claude tries to stop:

1. The hook reads the state file (`.claude/review-loop.local.md`)
2. If in `task` phase: runs Codex, transitions to `addressing`, blocks exit
3. If in `addressing` phase: allows exit and cleans up

State is tracked in `.claude/review-loop.local.md` (add to `.gitignore`). Reviews are written to `reviews/review-<id>.md`.

## File structure

```
claude-review-loop/
├── .claude-plugin/
│   └── plugin.json           # Plugin manifest
├── commands/
│   ├── review-loop.md        # /review-loop slash command
│   └── cancel-review.md      # /cancel-review slash command
├── hooks/
│   ├── hooks.json            # Stop hook registration (900s timeout)
│   └── stop-hook.sh          # Core lifecycle engine
├── scripts/
│   └── setup-review-loop.sh  # Argument parsing, state file creation
├── AGENTS.md                  # Agent operating guidelines
├── CLAUDE.md                  # Symlink to AGENTS.md
└── README.md
```

## Configuration

The stop hook timeout is set to 900 seconds (15 minutes) in `hooks/hooks.json`. Adjust if your Codex reviews take longer.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_LOOP_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Flags passed to `codex`. Set to `--sandbox workspace-write` for safer sandboxed reviews. |

### Telemetry

Execution logs are written to `.claude/review-loop.log` with timestamps, codex exit codes, and elapsed times. This file is gitignored.

## Credits

Inspired by the [Ralph Wiggum plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) and [Ryan Carson's compound engineering loop](https://x.com/ryancarson/article/2016520542723924279).
