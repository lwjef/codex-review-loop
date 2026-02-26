# compound-review-loop (fork)

> Fork of [hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop) with
> file-scoped reviews, knowledge compounding, and AI anti-pattern detection.

A Claude Code plugin that adds an automated review + compound loop to your workflow. Every task
gets an independent review, and every review compounds knowledge back into the codebase.

## What it does

When you use `/review-loop`, the plugin creates a three-phase lifecycle:

1. **Task phase**: You describe a task, Claude implements it
2. **Review phase**: Stop hook runs [Codex](https://github.com/openai/codex) for independent review (+ parallel lint/typecheck), Claude addresses feedback
3. **Compound phase**: Claude extracts reusable knowledge from the review, updates nearest AGENTS.md, logs learnings to progress file

The result: every task gets a second opinion from a different model, and every gotcha discovered
becomes institutional knowledge that helps future agents.

## Fork additions

### File-scoped reviews (parallel agent safe)

A `PostToolUse` hook tracks every file modified by Edit/Write tools during the session. When the
Stop hook fires, Codex only reviews files THIS agent changed — not the entire repo.

Multiple agents can work in parallel on different modules of the same branch, each getting a review
scoped to its own changes.

**Fallback chain**: tracking file → transcript parsing → full git diff

### Project convention injection

Reads `AGENTS.md` or `CLAUDE.md` from repo root and injects project conventions into the Codex
review prompt. Codex reviews against YOUR standards, not generic ones.

### Auto-scoped dependency map

If [codebase-map](https://www.npmjs.com/package/codebase-map) is installed, auto-derives impacted
modules from changed files and injects a focused dependency graph into the review prompt. Monorepo-
agnostic — detects `apps/`, `services/`, `packages/` boundaries automatically.

### Real-time anti-pattern checks

PostToolUse hooks fire on every Edit, catching issues instantly:
- **Code→comment replacement** — blocks replacing code with `// removed` style comments
- **Unused parameter prefixing** — blocks `param` → `_param` lazy refactoring

### AI anti-pattern detection (in Codex review)

The diff review agent additionally checks for:
- Mocks/stubs created just to pass tests
- Hardcoded values that should use existing constants/enums
- Code added on top without integrating into existing patterns
- Over-engineered error handling for impossible scenarios
- New utility functions duplicating existing ones
- Unnecessary type assertions (`as any`, `!`) instead of fixing types
- Feature flags or backward-compat shims when direct replacement was appropriate

### Parallel quality checks

Lint and typecheck run **in parallel with Codex review** during the Stop hook — zero wasted time.
Auto-detects tooling: biome/eslint for JS/TS, ruff for Python, tsc for typechecking.

### Knowledge compounding

After addressing review findings, Claude enters a compound phase:
1. Parses review findings — classifies each as **reusable** vs **task-specific**
2. Routes reusable lore to nearest AGENTS.md (Least Common Ancestor rule)
3. Appends session entry to `progress.txt` with learnings
4. Updates `## Codebase Patterns` section at top of progress file

Patterns discovered on Monday inform Tuesday's work. Inspired by
[Every's compound engineering](https://every.to/guides/compound-engineering).

## Review coverage

The plugin spawns up to 4 parallel Codex sub-agents, depending on project type:

| Agent | Always runs? | Focus |
|-------|-------------|-------|
| **Diff Review** | Yes | `git diff` — code quality, test coverage, security (OWASP top 10), AI anti-patterns |
| **Holistic Review** | Yes | Project structure, documentation, AGENTS.md, agent harness, architecture |
| **Next.js Review** | If `next.config.*` or `"next"` in `package.json` | App Router, Server Components, caching, Server Actions, React performance |
| **UX Review** | If `app/`, `pages/`, `public/`, or `index.html` exists | Browser E2E via [agent-browser](https://agent-browser.dev/), accessibility, responsive design |

After all agents finish, Codex deduplicates findings and writes a single consolidated review to `reviews/review-<id>.md`.

## Requirements

- [Claude Code](https://claude.ai/code) (CLI)
- `jq` — `brew install jq` (macOS) / `apt install jq` (Linux)
- [Codex CLI](https://github.com/openai/codex) — `npm install -g @openai/codex`

### Optional

- [codebase-map](https://www.npmjs.com/package/codebase-map) — `npm install -g codebase-map` (auto-scoped dependency maps)

### Codex multi-agent

This plugin uses Codex [multi-agent](https://developers.openai.com/codex/multi-agent/) to run parallel review agents. The `/review-loop` command automatically enables it in `~/.codex/config.toml` on first use.

```toml
# ~/.codex/config.toml
[features]
multi_agent = true
```

## Installation

From the CLI:

```bash
claude plugin marketplace add dkorobtsov/claude-review-loop
claude plugin install compound-review-loop@dkorobtsov-review
```

Or from within a Claude Code session:

```
/plugin marketplace add dkorobtsov/claude-review-loop
/plugin install compound-review-loop@dkorobtsov-review
```

## Usage

### Start a review loop

```
/review-loop Add user authentication with JWT tokens and test coverage
```

Claude implements the task. When it finishes, the stop hook:
1. Collects files this agent modified (PostToolUse tracking)
2. Runs Codex review scoped to those files (+ parallel lint/typecheck)
3. Injects AGENTS.md conventions + dependency map into review prompt
4. Writes findings to `reviews/review-<id>.md`
5. Claude addresses findings
6. Claude extracts reusable knowledge → updates AGENTS.md + progress.txt

### Cancel a review loop

```
/cancel-review
```

## How it works

### Hooks

| Hook | Event | Purpose |
|------|-------|---------|
| `track-modified.sh` | PostToolUse (Edit/Write) | Accumulate changed files per session |
| `check-comment-replacement.sh` | PostToolUse (Edit) | Block code→comment replacement |
| `check-unused-parameters.sh` | PostToolUse (Edit) | Block `_param` lazy refactoring |
| `stop-hook.sh` | Stop | Three-phase lifecycle engine |

### Three-phase Stop hook

```
Phase 1 (task → addressing):
  ├─ Codex multi-agent review (scoped to agent's files)
  │   Context: AGENTS.md conventions + dependency map
  └─ Parallel: lint + typecheck

Phase 2 (addressing → compound):
  └─ Claude fixes review findings

Phase 3 (compound → done):
  ├─ Classify findings: reusable vs task-specific
  ├─ Update nearest AGENTS.md (Least Common Ancestor)
  └─ Append to progress.txt
```

## File structure

```
plugins/compound-review-loop/
├── .claude-plugin/
│   └── plugin.json                  # Plugin manifest
├── commands/
│   ├── review-loop.md               # /review-loop slash command
│   └── cancel-review.md             # /cancel-review slash command
├── hooks/
│   ├── hooks.json                   # Hook registration
│   ├── track-modified.sh            # PostToolUse: file tracking
│   ├── check-comment-replacement.sh # PostToolUse: code→comment check
│   ├── check-unused-parameters.sh   # PostToolUse: _param check
│   └── stop-hook.sh                 # Stop: review + compound lifecycle
├── scripts/
│   └── setup-review-loop.sh         # State file creation
└── AGENTS.md                        # Agent guidelines
```

## Configuration

### Output directory

Learnings and progress are stored in a configurable directory:

| Priority | Source | Example |
|----------|--------|---------|
| 1 | `REVIEW_LOOP_OUTPUT_DIR` env | `/path/to/learnings` |
| 2 | `compound.config.json` → `outputDir` | `./scripts/compound` |
| 3 | Default | `.claude/learnings/` |

If your project uses the [compound engineering plugin](https://github.com/EveryInc/compound-engineering-plugin),
the review loop automatically shares its output directory — same `progress.txt`, same patterns.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_LOOP_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Flags passed to `codex exec` |
| `REVIEW_LOOP_OUTPUT_DIR` | auto-resolved | Override output dir for learnings/progress |
| `REVIEW_LOOP_SKIP_COMPOUND` | `false` | Skip knowledge extraction phase |
| `REVIEW_LOOP_SKIP_QUALITY_CHECKS` | `false` | Skip parallel lint/typecheck |
| `REVIEW_LOOP_SKIP_MAP` | `false` | Skip codebase-map injection |
| `REVIEW_LOOP_MAP_FORMAT` | `graph` | codebase-map format (`graph`, `dsl`, `tree`) |

### Timeouts

The stop hook timeout is 900 seconds (15 minutes) in `hooks/hooks.json`. PostToolUse hooks timeout
at 5 seconds. Adjust in `hooks.json` if needed.

### Telemetry

Execution logs are written to `.claude/review-loop.log` with timestamps, codex exit codes, and
elapsed times. This file is gitignored.

## Credits

Original plugin by [Hamel Husain](https://github.com/hamelsmu). Compound engineering approach
inspired by [Ryan Carson / Every](https://every.to/guides/compound-engineering).
