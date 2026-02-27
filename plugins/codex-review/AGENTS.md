# codex-review Plugin — Agent Guidelines

## Goal

Independent Codex code review of every Claude agent's changes, with project-specific context injection and knowledge
compounding. Each agent in a parallel swarm gets a focused review of only THEIR files — not the whole diff.

## Hook Inventory

| Hook | Event | Purpose | Always-on? |
|------|-------|---------|------------|
| `track-modified.sh` | PostToolUse (Edit/Write) | Track files this agent modified | Yes |
| `check-comment-replacement.sh` | PostToolUse (Edit) | Detect code→comment replacement | Yes |
| `check-unused-parameters.sh` | PostToolUse (Edit) | Detect `_param` lazy refactoring | Yes |
| `self-review.sh` | Stop | Randomized self-review questions (4 focus areas) | Yes |
| `stop-hook.sh` | Stop | N parallel Codex reviews + quality checks + compounding | Only with `/review-loop` |

## Commands

| Command | Description |
|---------|-------------|
| `/review-loop` | Activate 3-phase review loop for current session |
| `/review-parallel` | On-demand N parallel Codex reviews (standalone, no loop) |
| `/review-uncommitted` | On-demand single-agent Codex review (lightweight) |
| `/cancel-review` | Cancel active review loop |

## Hard Requirements (NEVER violate)

- **Parallel review**: N separate `codex exec review` processes, one per category (diff, holistic, security, tests,
  +conditional nextjs). NOT single-process multi-agent
- **Full AGENTS.md injection**: Load ENTIRE root AGENTS.md/CLAUDE.md into review prompt — not truncated
- **File-scoped reviews**: Each agent's review covers only files THAT agent modified
- **Codex CLI constraint**: `--uncommitted` and `[PROMPT]` are mutually exclusive. We use `[PROMPT]` mode
- **Codex output is on stderr**: Capture with `2>"$FILE"`. Extract after last `^codex$` marker
- **Stop hook JSON-only stdout**: All logging/codex output go to files/stderr — never stdout
- **Fail-open**: On any error, approve exit. Never trap user in broken loop
- **CWD-agnostic**: All paths resolved via `REPO_ROOT=$(git rev-parse --show-toplevel)`. Hooks may run from subdirectories

## Three-Phase Lifecycle (`/review-loop`)

```
Phase 1 (task):       Claude implements → stop hook runs N parallel Codex reviews (+ lint/typecheck)
Phase 2 (addressing): Claude addresses review findings
Phase 3 (compound):   Claude extracts reusable lore → updates AGENTS.md + progress.txt
```

## Parallel Codex Review (Phase 1)

Default: N parallel processes. Fallback: `REVIEW_LOOP_SINGLE_AGENT=true` for single process.

5 review categories (4 always + 1 conditional):
1. **Diff Review** — line-by-line code changes, AI anti-patterns, DRY, naming
2. **Holistic Review** — architecture, module structure, documentation, agent readiness
3. **Security Review** — auth, injection, data protection, rate limiting
4. **Test Coverage Review** — missing tests, test quality, anti-patterns, integration
5. **Next.js Review** (conditional) — App Router, RSC, caching, bundle size, React performance

Each agent gets: file scope instruction + project conventions + dependency map (where relevant) + category-specific
review criteria. Outputs merged into single `reviews/review-{ID}.md` with per-agent sections.

## Self-Review Hook (always-on)

Fires on EVERY session stop (no `/review-loop` needed). Skips when:
- `stop_hook_active=true` (review loop already handling)
- Active review-loop state file exists
- No file changes in session
- Already self-reviewed this cycle (marker: "Self-Review Complete")

4 focus areas with randomized questions:
1. Implementation Completeness — mocks, TODOs, hardcoded values
2. Code Quality — DRY, complexity, cleanup
3. Integration & Refactoring — bolt-on code, abstractions, hacks
4. Codebase Consistency — ripple effects, patterns, related files

## Codex Invocation

```bash
# CORRECT — N parallel processes
codex exec review "$DIFF_PROMPT" $FLAGS >/dev/null 2>"${TMPDIR}/diff.raw" &
codex exec review "$HOLISTIC_PROMPT" $FLAGS >/dev/null 2>"${TMPDIR}/holistic.raw" &
# ... wait for all, clean, merge

# WRONG — single process asking for "multi-agent" (codex exec review is single-agent)
codex exec review "$BIG_PROMPT_WITH_MULTI_AGENT_INSTRUCTIONS" $FLAGS >/dev/null 2>"$FILE"
```

Stderr contains: session header → MCP startup → thinking/exec traces → `codex\n<actual review>`. Use
`clean_codex_output()` to strip noise and extract after last `^codex$` marker.

## Gotchas

### CWD-relative paths (CRITICAL)

- Hooks run from whatever CWD the Claude Code session started in (e.g., `apps/backend/`)
- ALL `.claude/`, `reviews/` paths MUST use `${REPO_ROOT}/` prefix
- `REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)` at top of every hook

### Stop hook `session_id` not in Stop event

- `PostToolUse` events include `session_id` — `Stop` events may NOT
- Stop hook fallback chain: match by session_id → single active state file → most recent
- Without fallback, hook silently exits with approve

### ERR trap catches optional steps

- Global `trap ... ERR` catches ANY non-zero exit, including `codebase-map`, `jq` on missing files
- Guard all optional steps with `|| true`

### Parallel agent safety

- State files per session: `.claude/review-loop-{REVIEW_ID}.local.md`
- Tracking files per session: `.claude/modified-files-{SESSION_ID}.txt`
- Stale file cleanup: `find -mmin +60` (time-based, not blanket `rm -f`)

### grep -c double-zero

- `grep -c ... || echo 0` prints `0\n0` when grep exits 1 (0 matches + fallback echo)
- Fix: `n=$(...) || true; echo "${n:-0}"`

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `REVIEW_LOOP_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Codex CLI flags |
| `REVIEW_LOOP_OUTPUT_DIR` | `.claude/learnings/` | Knowledge compounding output |
| `REVIEW_LOOP_SINGLE_AGENT` | `false` | Use single codex process (disable parallel) |
| `REVIEW_LOOP_SKIP_COMPOUND` | `false` | Skip Phase 3 |
| `REVIEW_LOOP_SKIP_QUALITY_CHECKS` | `false` | Skip lint/typecheck |
| `REVIEW_LOOP_SKIP_MAP` | `false` | Skip codebase-map |
| `REVIEW_LOOP_SKIP_SELF_REVIEW` | `false` | Disable self-review hook |
| `REVIEW_LOOP_MAP_FORMAT` | `graph` | codebase-map output format |

## File Scoping

1. `track-modified.sh` fires on Edit/Write → appends to `.claude/modified-files-{session_id}.txt`
2. First fire claims unclaimed state file (writes `session_id:` into it)
3. Stop hook reads tracking file → scoped file list
4. Fallback chain: tracking file → transcript parsing → git diff (all changes)
5. Paths relativized via `git rev-parse --show-toplevel`

## Knowledge Compounding (Phase 3)

1. Review findings classified: reusable pattern vs task-specific
2. Reusable lore routed to nearest AGENTS.md (Least Common Ancestor)
3. Session entry → `{output_dir}/progress.txt`
4. Output dir: `REVIEW_LOOP_OUTPUT_DIR` env → `compound.config.json` → `.claude/learnings/`

## Conventions

- Shell: macOS + Linux compatible (`sed -i ''` vs `sed -i`)
- State: `.claude/review-loop-*.local.md` — always clean up on exit
- Review ID: `YYYYMMDD-HHMMSS-hexhex` — validate `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$`
- Log: `.claude/review-loop.log` — structured timestamped lines
- Security: validate review IDs, no eval, no secrets in state files

## Testing

- `/review-parallel`: on-demand parallel review (same quality as loop)
- `/review-uncommitted`: on-demand single-agent review (lightweight)
- `scripts/test-codex-review.sh`: minimal CLI test of codex exec review
- After modifying hooks: test all paths (no-state, task→addressing, addressing→compound, compound→approve)
- Verify JSON output with `jq .` for each path
- Test file scoping: modify 2 files, verify only those in review scope
- Test CWD: start session from subdirectory, verify hooks resolve REPO_ROOT correctly
