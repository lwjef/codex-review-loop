# compound-review-loop (fork)

> Fork of [hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop) with parallel Codex reviews,
> self-review, file-scoped reviews, knowledge compounding, and AI anti-pattern detection.

A Claude Code plugin that adds automated review loops to your workflow. Every task gets independent reviews from multiple
parallel Codex agents, and every review compounds knowledge back into the codebase.

## What it does

### Always-on (every session)

- **PostToolUse checks**: code→comment replacement detection, `_param` lazy refactoring detection
- **Self-review**: randomized questions from 4 focus areas on every stop (implementation completeness, code quality,
  integration, codebase consistency)

### On-demand (`/review-parallel`)

Run N parallel Codex reviews on uncommitted changes — no review loop needed. 4 specialized agents (diff, holistic,
security, tests) review independently and produce a combined report.

### Full loop (`/review-loop`)

Three-phase lifecycle:

1. **Task phase**: Claude implements your task
2. **Review phase**: Stop hook runs N parallel Codex reviews (+ lint/typecheck), Claude addresses feedback
3. **Compound phase**: Claude extracts reusable knowledge, updates nearest AGENTS.md, logs learnings

## Fork additions

### Parallel Codex reviews (N separate processes)

Each review category runs as an independent `codex exec review` process. Dramatically more thorough than single-agent
review — tested at 330KB/21 findings across 4 agents vs 2.2KB from single agent.

Fallback: `REVIEW_LOOP_SINGLE_AGENT=true` for single process.

### Self-review hook (from ClaudeKit)

Always-on Stop hook that forces Claude to self-review before stopping. Randomized questions from 4 focus areas avoid
pattern fatigue. Skips when review-loop is active (Codex handles it instead).

### File-scoped reviews (parallel agent safe)

A `PostToolUse` hook tracks every file modified by Edit/Write tools during the session. When the Stop hook fires, Codex
only reviews files THIS agent changed — not the entire repo.

Multiple agents can work in parallel on different modules, each getting a review scoped to its own changes.

### Project convention injection

Reads `AGENTS.md` or `CLAUDE.md` from repo root and injects project conventions into each Codex review prompt.

### Auto-scoped dependency map

If [codebase-map](https://www.npmjs.com/package/codebase-map) is installed, auto-derives impacted modules from changed
files and injects a focused dependency graph. Monorepo-agnostic — detects `apps/`, `services/`, `packages/` boundaries.

### Real-time anti-pattern checks

PostToolUse hooks fire on every Edit:

- **Code→comment replacement** — blocks replacing code with `// removed` comments
- **Unused parameter prefixing** — blocks `param` → `_param` lazy refactoring

### AI anti-pattern detection (in Codex review)

The diff review agent checks for: mocks/stubs to pass tests, hardcoded values that should use constants, code bolted on
without integrating, over-engineered error handling, duplicate utility functions, unnecessary type assertions, feature
flags where direct replacement fits.

### Parallel quality checks

Lint and typecheck run **in parallel with Codex review** — zero wasted time. Auto-detects: biome/eslint for JS/TS, ruff
for Python, tsc for typechecking.

### Knowledge compounding

After addressing findings, Claude extracts reusable knowledge: routes lore to nearest AGENTS.md (Least Common Ancestor),
logs session learnings to `progress.txt`.

## Review coverage

N parallel Codex processes, one per review category:

| Agent                  | Always runs?                                     | Focus                                                              |
| ---------------------- | ------------------------------------------------ | ------------------------------------------------------------------ |
| **Diff Review**        | Yes                                              | Line-by-line code quality, test coverage, security, AI anti-patterns |
| **Holistic Review**    | Yes                                              | Architecture, module structure, documentation, agent readiness     |
| **Security Review**    | Yes                                              | Auth, injection, data protection, rate limiting, OWASP             |
| **Test Coverage**      | Yes                                              | Missing tests, test quality, anti-patterns, integration gaps       |
| **Next.js Review**     | If `next.config.*` or `"next"` in `package.json` | App Router, RSC, caching, Server Actions, React performance       |

Each agent gets file scope + project conventions + category-specific criteria. Outputs merged into
`reviews/review-<id>.md`.

## Requirements

- [Claude Code](https://claude.ai/code) (CLI)
- `jq` — `brew install jq` (macOS) / `apt install jq` (Linux)
- [Codex CLI](https://github.com/openai/codex) — `npm install -g @openai/codex`

### Optional

- [codebase-map](https://www.npmjs.com/package/codebase-map) — `npm install -g codebase-map` (dependency maps)

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
2. Launches N parallel Codex reviews scoped to those files (+ lint/typecheck)
3. Injects AGENTS.md conventions + dependency map into each agent's prompt
4. Merges findings into `reviews/review-<id>.md`
5. Claude addresses findings
6. Claude extracts reusable knowledge → updates AGENTS.md + progress.txt

### On-demand parallel review

```
/review-parallel
```

Runs 4 parallel Codex reviews on uncommitted changes. No review loop session needed.

### On-demand single review

```
/review-uncommitted
```

Lightweight single-agent Codex review on uncommitted changes.

### Cancel a review loop

```
/cancel-review
```

## How it works

### Hooks

| Hook                           | Event                    | Always-on? | Purpose                                |
| ------------------------------ | ------------------------ | ---------- | -------------------------------------- |
| `track-modified.sh`            | PostToolUse (Edit/Write) | Yes        | Accumulate changed files per session   |
| `check-comment-replacement.sh` | PostToolUse (Edit)       | Yes        | Block code→comment replacement         |
| `check-unused-parameters.sh`   | PostToolUse (Edit)       | Yes        | Block `_param` lazy refactoring        |
| `self-review.sh`               | Stop                     | Yes        | Randomized self-review (4 focus areas) |
| `stop-hook.sh`                 | Stop                     | Loop only  | N parallel Codex reviews + compounding |

### Three-phase Stop hook

```
Phase 1 (task → addressing):
  ├─ N parallel Codex reviews (scoped to agent's files)
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
│   ├── review-parallel.md           # /review-parallel (on-demand, N agents)
│   ├── review-uncommitted.md        # /review-uncommitted (on-demand, 1 agent)
│   └── cancel-review.md             # /cancel-review
├── hooks/
│   ├── hooks.json                   # Hook registration
│   ├── track-modified.sh            # PostToolUse: file tracking
│   ├── check-comment-replacement.sh # PostToolUse: code→comment check
│   ├── check-unused-parameters.sh   # PostToolUse: _param check
│   ├── self-review.sh               # Stop: always-on self-review
│   └── stop-hook.sh                 # Stop: review + compound lifecycle
├── scripts/
│   └── setup-review-loop.sh         # State file creation
└── AGENTS.md                        # Agent guidelines
```

## Configuration

### Environment variables

| Variable                          | Default                                      | Description                            |
| --------------------------------- | -------------------------------------------- | -------------------------------------- |
| `REVIEW_LOOP_CODEX_FLAGS`         | `--dangerously-bypass-approvals-and-sandbox` | Flags passed to `codex exec`           |
| `REVIEW_LOOP_OUTPUT_DIR`          | auto-resolved                                | Override output dir for learnings      |
| `REVIEW_LOOP_SINGLE_AGENT`        | `false`                                      | Disable parallel (single codex process)|
| `REVIEW_LOOP_SKIP_COMPOUND`       | `false`                                      | Skip knowledge extraction phase        |
| `REVIEW_LOOP_SKIP_QUALITY_CHECKS` | `false`                                      | Skip parallel lint/typecheck           |
| `REVIEW_LOOP_SKIP_MAP`            | `false`                                      | Skip codebase-map injection            |
| `REVIEW_LOOP_SKIP_SELF_REVIEW`    | `false`                                      | Disable self-review hook               |
| `REVIEW_LOOP_MAP_FORMAT`          | `graph`                                      | codebase-map format                    |

### Output directory

Learnings and progress stored in configurable directory:

| Priority | Source                               | Example              |
| -------- | ------------------------------------ | -------------------- |
| 1        | `REVIEW_LOOP_OUTPUT_DIR` env         | `/path/to/learnings` |
| 2        | `compound.config.json` → `outputDir` | `./scripts/compound` |
| 3        | Default                              | `.claude/learnings/` |

### Timeouts

Stop hook: 1800s (30 min) for parallel Codex reviews. Self-review: 30s. PostToolUse hooks: 5s. Adjust in `hooks.json`.

### Telemetry

Execution logs: `.claude/review-loop.log` (timestamps, codex exit codes, elapsed times). Gitignored.

## Credits

Original plugin by [Hamel Husain](https://github.com/hamelsmu). Compound engineering approach inspired by
[Ryan Carson / Every](https://every.to/guides/compound-engineering). Self-review ported from
[ClaudeKit](https://github.com/carlrannaberg/claudekit) by Carl Rannaberg.
