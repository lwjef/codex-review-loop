# compound-review-loop Plugin — Agent Guidelines

## What this is

A Claude Code plugin with a three-phase review + compound loop:
1. Claude implements a task
2. Codex independently reviews the changes
3. Claude addresses the review feedback
4. Claude extracts reusable knowledge → updates nearest AGENTS.md + progress log

Fork of [hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop) with:
- **File-scoped reviews** — PostToolUse hook tracks per-session modified files; Codex only reviews
  files THIS agent touched (safe for parallel agents on same branch)
- **Project convention injection** — reads AGENTS.md/CLAUDE.md and feeds conventions to Codex
- **AI anti-pattern checks** — detects mocks-to-pass-tests, code-replaced-with-comments,
  unused `_param` prefixes, hardcoded values, unnecessary type assertions
- **Knowledge compounding** — extracts reusable lore from review findings, routes to nearest
  AGENTS.md following Intent Layer architecture (Least Common Ancestor rule)
- **Dependency map** — auto-scoped codebase-map injection for impacted modules

## Three-phase lifecycle

```
Phase 1 (task):       Claude implements → Codex reviews (+ parallel lint/typecheck)
Phase 2 (addressing): Claude fixes findings from review
Phase 3 (compound):   Claude extracts lore → updates AGENTS.md + progress.txt
```

## Output dir resolution

Learnings and progress are stored in a configurable output dir:

1. `REVIEW_LOOP_OUTPUT_DIR` env var — explicit override
2. `compound.config.json` → `outputDir` — shared with compound loop
3. `.claude/learnings/` — default fallback (project-local)

This means if compound loop is configured, review-loop shares the same progress.txt automatically.

## How file scoping works

1. `PostToolUse` hook (`track-modified.sh`) fires on every Edit/Write
2. Appends `tool_input.file_path` to `.claude/modified-files-{session_id}.txt`
3. `Stop` hook reads that file → passes scoped file list to Codex
4. Codex runs `git diff -- <file>` per file instead of reviewing entire repo
5. Fallback chain: tracking file → transcript parsing → git diff (all changes)

## How compounding works

1. Review file is parsed for findings that were addressed (not skipped)
2. Each finding classified: reusable pattern vs task-specific detail
3. Reusable lore routed to nearest AGENTS.md (Least Common Ancestor)
4. Session entry appended to `{output_dir}/progress.txt`
5. General patterns added to `## Codebase Patterns` section at top of progress.txt

## Conventions

- Shell scripts must work on both macOS and Linux (handle `sed -i` differences)
- The stop hook MUST always produce valid JSON to stdout — never let non-JSON text leak
- Fail-open: on any error, approve exit rather than trapping the user
- State lives in `.claude/review-loop.local.md` — always clean up on exit
- Review ID format: `YYYYMMDD-HHMMSS-hexhex` — validate before using in paths
- Codex stdout/stderr is redirected away from hook stdout to prevent JSON corruption
- Telemetry goes to `.claude/review-loop.log` — structured, timestamped lines

## Security constraints

- Review IDs are validated against `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$` to prevent path traversal
- Codex flags are configurable via `REVIEW_LOOP_CODEX_FLAGS` env var
- No secrets or credentials are stored in state files

## Testing

- After modifying stop-hook.sh, test all four paths: no-state, task→addressing, addressing→compound, compound→approve
- Verify JSON output with `jq .` for each path
- Test with codex unavailable (should fall back to self-review prompt)
- Test with malformed state files (should fail-open)
- Test file scoping: modify 2 files, verify only those appear in review scope
- Test compound: verify AGENTS.md updates and progress.txt entries
- Test output dir resolution: env var > compound.config.json > default
