#!/usr/bin/env bash
# Review Loop — Stop Hook (customized fork)
#
# Three-phase lifecycle:
#   Phase 1 (task):       Claude finishes work → hook runs Codex multi-agent review → blocks exit
#   Phase 2 (addressing): Claude addresses review findings → blocks exit
#   Phase 3 (compound):   Claude extracts reusable lore → updates nearest AGENTS.md → allows exit
#
# On any error, default to allowing exit (never trap the user in a broken loop).
#
# Customizations over upstream (hamelsmu/claude-review-loop):
#   - File-scoped reviews: only reviews files THIS agent modified (parallel agent safe)
#   - Project conventions injected into diff review (anti-patterns from AGENTS.md)
#   - Knowledge compounding: extracts lore from review findings into AGENTS.md + progress log
#   - PostToolUse tracking file cleanup on completion
#
# Environment variables:
#   REVIEW_LOOP_CODEX_FLAGS       Override codex flags (default: --dangerously-bypass-approvals-and-sandbox)
#   REVIEW_LOOP_OUTPUT_DIR        Override output dir for learnings/progress
#   REVIEW_LOOP_SKIP_COMPOUND     Set to "true" to skip compound phase
#   REVIEW_LOOP_SKIP_QUALITY_CHECKS  Set to "true" to skip lint/typecheck
#   REVIEW_LOOP_SKIP_MAP          Set to "true" to skip codebase-map
#   REVIEW_LOOP_MAP_FORMAT        Override map format (default: graph)

# Resolve repo root — hooks may run from any CWD (e.g., apps/backend)
# All .claude/ paths must be absolute to work regardless of CWD.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

LOG_FILE="${REPO_ROOT}/.claude/review-loop.log"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

trap 'log "ERROR: hook exited via ERR trap (line $LINENO)"; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

# Consume stdin (hook input JSON) — must read to avoid broken pipe
HOOK_INPUT=$(cat)

# ── Find state file for THIS session ──────────────────────────────────
# State files are per-review: .claude/review-loop-{REVIEW_ID}.local.md
# Linked to sessions via `session_id:` field (written by track-modified.sh)
#
# Fallback chain (Stop event may not include session_id):
#   1. Match by session_id if available
#   2. If exactly one active state file exists, use it
#   3. If multiple, use most recently modified
# Debug: log what fields the Stop event provides
log "Stop hook fired. Input keys: $(echo "$HOOK_INPUT" | jq -r 'keys | join(",")' 2>/dev/null || echo 'parse-failed')"

SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")

STATE_FILE=""

# Try 1: find by session_id
if [ -n "$SESSION_ID" ]; then
  STATE_FILE=$(grep -l "session_id: ${SESSION_ID}" "${REPO_ROOT}"/.claude/review-loop-*.local.md 2>/dev/null | head -1)
fi

# Try 2: fallback — find active state files
if [ -z "$STATE_FILE" ] || [ ! -f "$STATE_FILE" ]; then
  ACTIVE_FILES=""
  for sf in "${REPO_ROOT}"/.claude/review-loop-*.local.md; do
    [ -f "$sf" ] || continue
    if grep -q "^active: true" "$sf" 2>/dev/null; then
      ACTIVE_FILES="${ACTIVE_FILES}${sf}\n"
    fi
  done
  ACTIVE_COUNT=$(printf '%b' "$ACTIVE_FILES" | grep -c . 2>/dev/null || echo 0)

  if [ "$ACTIVE_COUNT" -eq 1 ]; then
    STATE_FILE=$(printf '%b' "$ACTIVE_FILES" | head -1)
    log "State file: fallback to single active file $STATE_FILE"
  elif [ "$ACTIVE_COUNT" -gt 1 ]; then
    # Multiple active — use most recently modified (best guess for current session)
    STATE_FILE=$(printf '%b' "$ACTIVE_FILES" | grep . | xargs ls -t 2>/dev/null | head -1)
    log "State file: fallback to most recent of $ACTIVE_COUNT active files: $STATE_FILE"
  fi
fi

# No state file found → allow exit (no active review loop)
if [ -z "$STATE_FILE" ] || [ ! -f "$STATE_FILE" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Parse a field from the YAML frontmatter
parse_field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1
}

ACTIVE=$(parse_field "active")
PHASE=$(parse_field "phase")
REVIEW_ID=$(parse_field "review_id")

# Not active → clean up and exit
if [ "$ACTIVE" != "true" ]; then
  rm -f "$STATE_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Validate review_id format to prevent path traversal
if ! echo "$REVIEW_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
  log "ERROR: invalid review_id format: $REVIEW_ID"
  rm -f "$STATE_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Safety: if stop_hook_active is true and we're still in "task" phase,
# something went wrong with the phase transition. Allow exit to prevent loops.
STOP_HOOK_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
if [ "$STOP_HOOK_ACTIVE" = "true" ] && [ "$PHASE" = "task" ]; then
  log "WARN: stop_hook_active=true in task phase, aborting to prevent loop"
  rm -f "$STATE_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# ── File scoping: find files THIS agent modified ──────────────────────────
get_scoped_files() {
  local files=""

  # Method 1: PostToolUse tracking file (most accurate)
  if [ -n "$SESSION_ID" ]; then
    local track_file="${REPO_ROOT}/.claude/modified-files-${SESSION_ID}.txt"
    if [ -f "$track_file" ]; then
      files=$(cat "$track_file")
      log "File scoping: found $(wc -l < "$track_file" | tr -d ' ') files from tracking"
    fi
  fi

  # Method 2: Fallback to transcript parsing if no tracking file
  if [ -z "$files" ]; then
    local transcript
    transcript=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
    if [ -n "$transcript" ] && [ -f "$transcript" ]; then
      files=$(jq -r 'select(.tool_name == "Edit" or .tool_name == "Write") | .tool_input.file_path // empty' "$transcript" 2>/dev/null | sort -u)
      log "File scoping: found $(echo "$files" | grep -c . || echo 0) files from transcript"
    fi
  fi

  # Method 3: Ultimate fallback — all uncommitted changes
  if [ -z "$files" ]; then
    files=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)
    files=$(echo "$files" | sort -u)
    log "File scoping: fallback to git diff ($(echo "$files" | grep -c . || echo 0) files)"
  fi

  # Relativize absolute paths (Claude Code sends absolute paths in tool_input)
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  files=$(echo "$files" | sed "s|^${repo_root}/||" | grep -v '^$' | sort -u)

  echo "$files"
}

# ── Project type detection ────────────────────────────────────────────────
detect_nextjs() {
  # Check monorepo: any app with next.config or "next" in package.json
  find . -maxdepth 3 -name "next.config.*" -not -path "*/node_modules/*" 2>/dev/null | head -1 | grep -q . || \
    find . -maxdepth 3 -name "package.json" -not -path "*/node_modules/*" -exec grep -l '"next"' {} \; 2>/dev/null | head -1 | grep -q .
}

detect_browser_ui() {
  [ -d "app" ] || [ -d "pages" ] || [ -d "src/app" ] || [ -d "src/pages" ] || \
    [ -d "public" ] || [ -f "index.html" ] || \
    find . -maxdepth 3 -name "app" -type d -not -path "*/node_modules/*" 2>/dev/null | head -1 | grep -q .
}

# ── Codebase map: scoped dependency context ──────────────────────────────
# Derives module boundaries from changed files, generates focused map.
# Requires `codebase-map` CLI. Gracefully skips if unavailable.
#
# Environment variables:
#   REVIEW_LOOP_SKIP_MAP  Set to "true" to skip map generation
#   REVIEW_LOOP_MAP_FORMAT  Override format (default: graph)
generate_scoped_map() {
  local SCOPED_FILES="$1"

  if [ "${REVIEW_LOOP_SKIP_MAP:-false}" = "true" ]; then
    return
  fi

  if ! command -v codebase-map &>/dev/null; then
    log "Codebase map: skipped (codebase-map not installed)"
    return
  fi

  # Need an index file — scan if missing (only on first run)
  if [ ! -f ".codebasemap" ]; then
    log "Codebase map: generating index (first run)"
    codebase-map scan --quiet 2>/dev/null || {
      log "Codebase map: scan failed"
      return
    }
  fi

  [ -z "$SCOPED_FILES" ] && return

  # Derive unique top-level module dirs from changed files
  # e.g. apps/bff-worker/src/foo.ts → apps/bff-worker
  #      services/story-processor/src/bar.py → services/story-processor
  #      packages/database/src/core.ts → packages/database
  #      src/utils/helpers.ts → src (flat repo fallback)
  local MODULE_DIRS
  MODULE_DIRS=$(echo "$SCOPED_FILES" | sed 's|^\./||' | awk -F'/' '
    # Monorepo patterns: apps/X, services/X, packages/X, libs/X
    /^(apps|services|packages|libs|modules)\/[^/]+/ { print $1"/"$2; next }
    # Fallback: use first directory
    NF >= 2 { print $1; next }
  ' | sort -u)

  [ -z "$MODULE_DIRS" ] && return

  # Build include args as an array (no eval needed)
  local MAP_ARGS=()
  for dir in $MODULE_DIRS; do
    MAP_ARGS+=(--include "${dir}/**")
  done

  local MAP_FORMAT="${REVIEW_LOOP_MAP_FORMAT:-graph}"

  # Generate scoped map
  local MAP_OUTPUT
  MAP_OUTPUT=$(codebase-map format --format "$MAP_FORMAT" "${MAP_ARGS[@]}" 2>/dev/null) || true

  if [ -n "$MAP_OUTPUT" ]; then
    local MAP_BYTES
    MAP_BYTES=$(echo "$MAP_OUTPUT" | wc -c | tr -d ' ')
    log "Codebase map: generated ${MAP_BYTES} bytes for modules: $(echo "$MODULE_DIRS" | tr '\n' ', ')"

    # Cap at 40KB (~10K tokens) to avoid blowing up prompt
    if [ "$MAP_BYTES" -gt 40000 ]; then
      MAP_OUTPUT=$(echo "$MAP_OUTPUT" | head -500)
      MAP_OUTPUT="${MAP_OUTPUT}

[... truncated to 500 lines — full map was ${MAP_BYTES} bytes]"
      log "Codebase map: truncated from ${MAP_BYTES} bytes"
    fi

    echo "$MAP_OUTPUT"
  fi
}

# ── Load project conventions (AGENTS.md / CLAUDE.md) ─────────────────────
load_project_conventions() {
  local conventions=""

  # Check for AGENTS.md at repo root
  if [ -f "AGENTS.md" ]; then
    conventions=$(cat AGENTS.md 2>/dev/null || true)
  elif [ -f "CLAUDE.md" ]; then
    conventions=$(cat CLAUDE.md 2>/dev/null || true)
  fi

  echo "$conventions"
}

# ── Build the multi-agent review prompt ───────────────────────────────────
build_review_prompt() {
  local REVIEW_FILE="$1"
  local SCOPED_FILES="$2"

  local IS_NEXTJS=false
  local HAS_UI=false
  detect_nextjs && IS_NEXTJS=true
  detect_browser_ui && HAS_UI=true

  log "Project detection: nextjs=$IS_NEXTJS, browser_ui=$HAS_UI"

  # Build file scope instruction
  local FILE_SCOPE_INSTRUCTION=""
  if [ -n "$SCOPED_FILES" ]; then
    FILE_SCOPE_INSTRUCTION="IMPORTANT — FILE SCOPE: Only review changes in these specific files (this agent's modifications):
$(echo "$SCOPED_FILES" | sed 's/^/  - /')

Use \`git diff -- <file>\` for each file above. Do NOT review unrelated changes in the repository."
  fi

  # Load project conventions
  local CONVENTIONS
  CONVENTIONS=$(load_project_conventions)
  local CONVENTIONS_BLOCK=""
  if [ -n "$CONVENTIONS" ]; then
    CONVENTIONS_BLOCK="
PROJECT CONVENTIONS (from AGENTS.md — review against these standards):
---
${CONVENTIONS}
---"
  fi

  # Generate scoped dependency map
  local MAP_OUTPUT
  MAP_OUTPUT=$(generate_scoped_map "$SCOPED_FILES")
  local MAP_BLOCK=""
  if [ -n "$MAP_OUTPUT" ]; then
    MAP_BLOCK="
DEPENDENCY MAP (auto-generated for impacted modules — use for understanding relationships):
\`\`\`
${MAP_OUTPUT}
\`\`\`"
  fi

  # ── Preamble ──
  cat << PREAMBLE_EOF
You are orchestrating a thorough, independent code review of recent changes in this repository.

${FILE_SCOPE_INSTRUCTION}

${CONVENTIONS_BLOCK}

${MAP_BLOCK}

Use multi-agent to run the following review agents IN PARALLEL. Each agent should return its findings as structured text. After ALL agents complete, consolidate their findings into a single deduplicated review.

PREAMBLE_EOF

  # ── Agent 1: Diff Review (with project-specific anti-patterns) ──
  if [ -n "$SCOPED_FILES" ]; then
    local DIFF_CMD="For each scoped file listed above: run \`git diff -- <file>\` for tracked files. For NEW (untracked) files, run \`cat <file>\` to read the full content — \`git diff\` shows nothing for untracked files."
  else
    local DIFF_CMD="Run \`git diff\` and \`git diff --cached\` to see all uncommitted changes. Also run \`git log --oneline -5\` and \`git diff HEAD~5\` for recently committed work."
  fi

  cat << DIFF_EOF
---
AGENT 1: Diff Review (focus on changed code ONLY)

${DIFF_CMD}
Focus your review EXCLUSIVELY on this changed code.

Review criteria for changed code:

Code Quality:
- Is the changed code well-organized, modular, and readable?
- Does it follow DRY principles — no copy-pasted blocks that should be abstracted?
- Are names (variables, functions, files) clear and consistent with the codebase?
- Are abstractions at the right level — not over-engineered, not under-abstracted?
- Is there unnecessary complexity that could be simplified?

Test Coverage:
- Does every new function/endpoint/component have corresponding tests?
- Are edge cases covered: empty inputs, nulls, boundary values, error paths?
- Are tests isolated, deterministic, and fast?
- Do tests verify behavior (not implementation details)?
- For bug fixes: is there a regression test that would have caught the original bug?

Security:
- Input validation: are all user inputs validated and sanitized before use?
- Authentication/authorization: are auth checks present on all protected routes/actions?
- Injection: any risk of SQL injection, XSS, command injection, path traversal?
- Secrets: are any credentials, API keys, or tokens hardcoded or logged?
- OWASP Top 10: check for broken access control, cryptographic failures, insecure design, security misconfiguration, vulnerable dependencies, SSRF
- Are error messages safe (no stack traces or internal details leaked to users)?

AI Agent Anti-Patterns (CRITICAL — these are common AI coding mistakes):
- Did the agent create mocks/stubs just to pass tests instead of testing real behavior?
- Was real code replaced with comments like "// implementation here" or "// TODO"?
- Are there unused parameters prefixed with underscore (_param) to suppress lint warnings?
- Did the agent just add code on top without integrating into existing patterns?
- Are there hardcoded values that should use existing constants/enums?
- Was error handling added for impossible scenarios (over-engineering)?
- Are there new utility functions that duplicate existing ones in the codebase?
- Did the agent add unnecessary type assertions (as any, !) instead of fixing types?
- Were feature flags or backward-compat shims added when direct replacement was appropriate?

For each issue: return file path, line number, severity (critical/high/medium/low), category, description, and suggested fix.

DIFF_EOF

  # ── Agent 2: Holistic Review (scoped to changed modules) ──
  # Build module-scoped directory list for holistic review
  local HOLISTIC_SCOPE=""
  if [ -n "$SCOPED_FILES" ]; then
    local HOLISTIC_DIRS
    HOLISTIC_DIRS=$(echo "$SCOPED_FILES" | sed 's|^\./||' | awk -F'/' '
      /^(apps|services|packages|libs|modules)\/[^/]+/ { print $1"/"$2; next }
      NF >= 2 { print $1; next }
    ' | sort -u)
    if [ -n "$HOLISTIC_DIRS" ]; then
      HOLISTIC_SCOPE="SCOPE: Only review structure and conventions within these modules (where changes were made):
$(echo "$HOLISTIC_DIRS" | sed 's/^/  - /')

Read directory structure, config files, AGENTS.md / CLAUDE.md within these modules. Do NOT scan the entire repository."
    fi
  fi

  cat << HOLISTIC_EOF
---
AGENT 2: Holistic Review (evaluate structure and agent readiness of changed modules)

${HOLISTIC_SCOPE:-Read the project directory structure, key config files, README, and any AGENTS.md / CLAUDE.md files in modules where changes were made.}

This is NOT about individual line changes — it's about whether the changed modules are well-structured for maintainability and agent-driven development.

Review criteria (scoped to changed modules):

Code Organization & Modularity:
- Is module structure logical and navigable? Can a new developer (or agent) find things?
- Are concerns properly separated (data access, business logic, presentation, config)?
- Are there god files/functions that do too much and should be split?
- Is shared code properly extracted into reusable modules?
- Are import paths clean (absolute imports, no deep relative paths)?

Documentation & Agent Harness:
- Does the module have an AGENTS.md with operating guidelines for agents?
- Is there a CLAUDE.md symlinked to each AGENTS.md for Claude Code compatibility?
- Do AGENTS.md files document: conventions, file purposes, testing patterns, common pitfalls?
- Is there telemetry/observability instrumentation (logging, metrics, tracing)?
- Is there a type system in use (TypeScript, Python type hints, etc.) with proper coverage?
- Are there proper constraints and guardrails so agents working on the code are set up for success?
- Are environment variables documented and validated at startup?
- Are there clear boundaries between server-only and client-safe code?

Architecture (within module boundary):
- Is the dependency graph clean (no circular dependencies)?
- Are external integrations properly abstracted behind interfaces?
- Is configuration centralized rather than scattered?
- Is error handling consistent across the module?

For each issue: return file path (or directory), severity (critical/high/medium/low), category, description, and suggested fix.

HOLISTIC_EOF

  # ── Agent 3: Next.js Best Practices (conditional) ──
  if [ "$IS_NEXTJS" = "true" ]; then
    cat << 'NEXTJS_EOF'
---
AGENT 3: Next.js & React Best Practices Review

This is a Next.js project. Review the codebase against these specific patterns:

App Router & Server Components:
- Are Server Components used by default? Is 'use client' only added when interactivity is needed?
- Is data fetched in Server Components, not Client Components?
- Are Suspense boundaries used for streaming slow data sources?
- Are file conventions correct: layout.tsx, page.tsx, loading.tsx, error.tsx, not-found.tsx?
- Are searchParams and params handled as Promises (await searchParams / await params)?
- Is generateStaticParams() used to pre-render known dynamic routes?
- Is generateMetadata() used for SEO-critical pages?
- Is notFound() called for missing resources instead of returning null?

Data Fetching & Caching:
- Are parallel data fetches used (Promise.all) instead of sequential waterfalls?
- Is cache strategy appropriate: no-store for fresh data, force-cache for static, revalidate for ISR?
- Are cache tags used for fine-grained invalidation after mutations?
- Is React.cache() used to deduplicate queries within a single request?

Server Actions & Mutations:
- Are Server Actions validated and auth-checked as if they were public API endpoints?
- Is revalidateTag/revalidatePath called after mutations to invalidate cache?
- Is after() used for non-blocking post-response work (logging, analytics)?

Performance & Bundle Size:
- No barrel file imports — import directly from source paths?
- Is next/dynamic with { ssr: false } used for heavy client-only components?
- Are non-critical libraries (analytics, error tracking) deferred until after hydration?
- Are heavy bundles preloaded on user intent (hover/focus)?
- Is data minimized across the RSC boundary (only pass fields client needs)?

React Performance:
- Is derived state calculated during render, not in effects?
- Are expensive computations memoized appropriately?
- Is useTransition used for non-urgent updates?
- No unnecessary useEffect for things that belong in event handlers?
- Are stable callback references used (functional setState, refs) to avoid re-render churn?
- Is content-visibility: auto used for long lists?
- Are inline scripts used to set client data before hydration (prevent FOUC)?

For each issue: return file path, line number, severity (critical/high/medium/low), category, description, and suggested fix.

NEXTJS_EOF
  fi

  # ── Agent 4: UX & Browser Testing (conditional) ──
  if [ "$HAS_UI" = "true" ]; then
    cat << 'UX_EOF'
---
AGENT (UX): Browser-Based UX Review (SKIP if you cannot access a running dev server)

If the project has a running dev server, use agent-browser to test the UI.
Install agent-browser if needed: npm install -g agent-browser (or: brew install agent-browser)

Testing checklist:
- Navigate to all major routes/pages
- Test key user workflows end-to-end (signup, login, CRUD operations, etc.)
- Take screenshots at desktop (1280x720) and mobile (375x812) viewports
- Check for: broken layouts, missing error states, loading states, empty states
- Verify accessibility: keyboard navigation, focus indicators, color contrast
- Check responsive design at multiple breakpoints
- Verify forms have proper validation feedback
- Check that error messages are user-friendly

If the dev server is not running or you cannot access it, skip this agent and note that UX testing was not performed.

For each issue: return screenshot description, severity, category, description, and suggested fix.

UX_EOF
  fi

  # ── Consolidation instructions ──
  cat << CONSOLIDATION_EOF
---
CONSOLIDATION INSTRUCTIONS (after all agents complete):

1. Collect all findings from all agents
2. Deduplicate: if multiple agents flagged the same issue, keep the most detailed version
3. Organize all findings by severity (critical first, then high, medium, low)
4. For each finding, include:
   - File path and line number (or directory for structural issues)
   - Severity: critical / high / medium / low
   - Category: which review path found it (Diff, Holistic, Next.js, UX)
   - Description: clear explanation
   - Suggested fix: concrete, actionable recommendation
5. End with a summary: total issues, breakdown by severity, agents that ran, overall assessment
CONSOLIDATION_EOF
}

# ── Parallel quality checks (lint + typecheck) ───────────────────────────
# Runs alongside Codex review to avoid wasting time.
# Auto-detects project tooling. Results appended to review file.
#
# Environment variables:
#   REVIEW_LOOP_SKIP_QUALITY_CHECKS  Set to "true" to skip lint/typecheck
run_quality_checks() {
  local REVIEW_FILE="$1"
  local SCOPED_FILES="$2"
  local QUALITY_RESULTS=""
  local QUALITY_TMPDIR
  QUALITY_TMPDIR=$(mktemp -d)

  if [ "${REVIEW_LOOP_SKIP_QUALITY_CHECKS:-false}" = "true" ]; then
    log "Quality checks: skipped (REVIEW_LOOP_SKIP_QUALITY_CHECKS=true)"
    return
  fi

  # Derive app directories from scoped files for targeted checks
  local APP_DIRS
  APP_DIRS=$(echo "$SCOPED_FILES" | sed 's|^\./||' | cut -d'/' -f1-2 | sort -u | grep -v '^$' || true)

  log "Quality checks: starting (app dirs: $(echo "$APP_DIRS" | tr '\n' ', '))"

  # ── TypeScript typecheck ──
  (
    if [ -f "tsconfig.json" ]; then
      # Try project-level tsc first
      npx tsc --noEmit 2>&1 | tail -30 > "${QUALITY_TMPDIR}/typecheck.txt"
    elif [ -n "$APP_DIRS" ]; then
      # Try per-app tsconfig
      for dir in $APP_DIRS; do
        if [ -f "${dir}/tsconfig.json" ]; then
          echo "=== ${dir} ===" >> "${QUALITY_TMPDIR}/typecheck.txt"
          npx tsc --noEmit --project "${dir}/tsconfig.json" 2>&1 | tail -20 >> "${QUALITY_TMPDIR}/typecheck.txt"
        fi
      done
    fi
  ) &
  local TC_PID=$!

  # ── Lint ──
  (
    if [ -f "biome.json" ] || [ -f "biome.jsonc" ]; then
      # Biome — lint scoped files if available, otherwise full project
      if [ -n "$SCOPED_FILES" ]; then
        echo "$SCOPED_FILES" | xargs npx biome check --no-errors-on-unmatched 2>&1 | tail -30 > "${QUALITY_TMPDIR}/lint.txt"
      else
        npx biome check . --no-errors-on-unmatched 2>&1 | tail -30 > "${QUALITY_TMPDIR}/lint.txt"
      fi
    elif [ -f ".eslintrc.json" ] || [ -f ".eslintrc.js" ] || [ -f "eslint.config.js" ] || [ -f "eslint.config.mjs" ]; then
      # ESLint — lint scoped files
      if [ -n "$SCOPED_FILES" ]; then
        echo "$SCOPED_FILES" | grep -E '\.(ts|tsx|js|jsx)$' | xargs npx eslint --no-error-on-unmatched-pattern 2>&1 | tail -30 > "${QUALITY_TMPDIR}/lint.txt"
      else
        npx eslint . 2>&1 | tail -30 > "${QUALITY_TMPDIR}/lint.txt"
      fi
    fi
    # Python lint (ruff)
    if echo "$SCOPED_FILES" | grep -q '\.py$'; then
      local PY_FILES
      PY_FILES=$(echo "$SCOPED_FILES" | grep '\.py$')
      if command -v ruff &>/dev/null; then
        echo "$PY_FILES" | xargs ruff check 2>&1 | tail -20 >> "${QUALITY_TMPDIR}/lint.txt"
      fi
    fi
  ) &
  local LINT_PID=$!

  # Wait for both
  wait $TC_PID 2>/dev/null || true
  wait $LINT_PID 2>/dev/null || true

  # Collect results
  local TC_OUTPUT=""
  local LINT_OUTPUT=""
  [ -f "${QUALITY_TMPDIR}/typecheck.txt" ] && TC_OUTPUT=$(cat "${QUALITY_TMPDIR}/typecheck.txt")
  [ -f "${QUALITY_TMPDIR}/lint.txt" ] && LINT_OUTPUT=$(cat "${QUALITY_TMPDIR}/lint.txt")

  # Append to review file if there are findings
  if [ -n "$TC_OUTPUT" ] || [ -n "$LINT_OUTPUT" ]; then
    {
      echo ""
      echo "---"
      echo "## Automated Quality Checks (ran in parallel with Codex review)"
      echo ""
      if [ -n "$TC_OUTPUT" ]; then
        echo "### TypeScript Typecheck"
        echo '```'
        echo "$TC_OUTPUT"
        echo '```'
        echo ""
      fi
      if [ -n "$LINT_OUTPUT" ]; then
        echo "### Lint"
        echo '```'
        echo "$LINT_OUTPUT"
        echo '```'
        echo ""
      fi
    } >> "$REVIEW_FILE"
    log "Quality checks: appended results to $REVIEW_FILE"
  else
    log "Quality checks: no issues found"
  fi

  rm -rf "$QUALITY_TMPDIR"
}

# ── Output dir resolution ─────────────────────────────────────────────────
# Resolution chain (first match wins):
#   1. REVIEW_LOOP_OUTPUT_DIR env var
#   2. compound.config.json → outputDir (shared with compound loop)
#   3. .claude/learnings/ (default fallback)
resolve_output_dir() {
  # 1. Explicit env override
  if [ -n "${REVIEW_LOOP_OUTPUT_DIR:-}" ]; then
    echo "$REVIEW_LOOP_OUTPUT_DIR"
    return
  fi

  # 2. Compound config (shared dir)
  if [ -f "compound.config.json" ]; then
    local dir
    dir=$(jq -r '.outputDir // empty' compound.config.json 2>/dev/null) || true
    if [ -n "$dir" ]; then
      echo "$dir"
      return
    fi
  fi

  # 3. Default
  echo "${REPO_ROOT}/.claude/learnings"
}

# ── Knowledge compounding ─────────────────────────────────────────────────
# Builds the compound prompt that instructs Claude to:
#   1. Parse review findings → classify as reusable vs task-specific
#   2. Route reusable lore to nearest AGENTS.md (Least Common Ancestor)
#   3. Append session learnings to progress.txt
build_compound_prompt() {
  local REVIEW_FILE="$1"
  local SCOPED_FILES="$2"
  local OUTPUT_DIR="$3"

  # Derive directories with changed files for AGENTS.md routing
  local CHANGED_DIRS
  CHANGED_DIRS=$(echo "$SCOPED_FILES" | sed 's|^\./||' | xargs -I{} dirname {} 2>/dev/null | sort -u | grep -v '^\.$' || true)

  cat << COMPOUND_EOF
## Compound Phase: Extract Reusable Knowledge

You just completed a review loop. Before finishing, extract reusable learnings from this session.

### Review file to analyze
Read: ${REVIEW_FILE}

### Files you modified
$(echo "$SCOPED_FILES" | sed 's/^/- /')

### Instructions

**Step 1: Identify reusable patterns from the review**

Go through the review findings you addressed. For each one, classify:
- **Reusable** — general pattern, gotcha, or convention that helps future agents
- **Task-specific** — only relevant to this particular change (discard)

Examples of REUSABLE learnings:
- "When modifying X router, also update Y schema to keep them in sync"
- "This module uses pattern Z for all API calls — follow it"
- "Tests in this dir require mocking W service"
- "Don't use pattern X here because of Y constraint"
- "Always run Z after changing files in this directory"

Examples of TASK-SPECIFIC (do NOT save):
- "Fixed the bug in line 42 of foo.ts"
- "Added error handling for the new endpoint"

**Step 2: Update nearest AGENTS.md files**

For each reusable learning, find the closest AGENTS.md in the directory tree of the affected files. Follow the Least Common Ancestor rule — place knowledge at the shallowest node that covers all affected files.

Directories with changed files:
$(echo "$CHANGED_DIRS" | sed 's/^/- /')

Rules for updating AGENTS.md:
- Add learnings under a relevant existing section, or create "## Learned Patterns" if none fits
- Keep entries concise — one line per learning, fragment style
- Do NOT add task-specific details, temporary notes, or duplicate existing entries
- Check existing content first to avoid duplicates

**Step 3: Append to progress log**

Append a session entry to: ${OUTPUT_DIR}/progress.txt

Format:
\`\`\`
## $(date -u +"%Y-%m-%dT%H:%M:%SZ") - Review Loop [${REVIEW_ID}]
- Files changed: $(echo "$SCOPED_FILES" | wc -l | tr -d ' ') files
- Review findings addressed: [count from review]
- **Learnings for future iterations:**
  - [each reusable pattern you identified]
  - [gotchas encountered]
---
\`\`\`

Also update the \`## Codebase Patterns\` section at the TOP of progress.txt with any general patterns (create section if missing).

**Step 4: Done**

After updating AGENTS.md files and progress.txt, you may stop.
If no reusable learnings were found, just append a brief progress entry and stop.
COMPOUND_EOF
}

# ── Cleanup session tracking files ────────────────────────────────────────
cleanup_tracking() {
  if [ -n "$SESSION_ID" ]; then
    rm -f "${REPO_ROOT}/.claude/modified-files-${SESSION_ID}.txt"
  fi
  # Clean up stale tracking + state files older than 24h
  find "${REPO_ROOT}/.claude" -name "modified-files-*.txt" -mmin +1440 -delete 2>/dev/null || true
  find "${REPO_ROOT}/.claude" -name "review-loop-*.local.md" -mmin +1440 -delete 2>/dev/null || true
}

case "$PHASE" in
  task)
    # ── Phase 1 → 2: Run Codex multi-agent review ──────────────────────
    REVIEW_FILE="${REPO_ROOT}/reviews/review-${REVIEW_ID}.md"
    mkdir -p "${REPO_ROOT}/reviews"

    # Get scoped files for this agent
    SCOPED_FILES=$(get_scoped_files)
    log "Scoped files for review: $(echo "$SCOPED_FILES" | tr '\n' ', ')"

    CODEX_PROMPT=$(build_review_prompt "$REVIEW_FILE" "$SCOPED_FILES")

    # Run codex non-interactively with telemetry logging.
    CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
    CODEX_EXIT=0
    START_TIME=$(date +%s)

    if ! command -v codex &> /dev/null; then
      log "ERROR: codex not found on PATH"
      rm -f "$STATE_FILE"
      REASON="ERROR: Codex CLI is not installed. The review loop requires Codex for independent code review.

Install it: npm install -g @openai/codex

Then run /review-loop again. Multi-agent will be auto-configured."
      jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
      exit 0
    fi

    # Validate multi-agent is enabled (should have been set up by /review-loop command)
    CODEX_CONFIG="${HOME}/.codex/config.toml"
    if [ ! -f "$CODEX_CONFIG" ] || ! grep -qE '^\s*multi_agent\s*=\s*true' "$CODEX_CONFIG"; then
      log "ERROR: multi_agent not enabled in $CODEX_CONFIG"
      rm -f "$STATE_FILE"
      REASON="ERROR: Codex multi-agent is not enabled in ~/.codex/config.toml. This should have been configured by /review-loop but may have been changed.

Add to ~/.codex/config.toml:
  [features]
  multi_agent = true

Then run /review-loop again."
      jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
      exit 0
    fi

    log "Starting Codex multi-agent review (flags: $CODEX_FLAGS)"

    # Run quality checks in parallel with Codex review (zero wasted time)
    # Quality checks write to a SEPARATE temp file to avoid race condition
    # with codex's 2> redirect (which truncates on open).
    QUALITY_TMPFILE="${REVIEW_FILE}.quality"
    run_quality_checks "$QUALITY_TMPFILE" "$SCOPED_FILES" &
    QUALITY_PID=$!

    # Use `codex exec review [PROMPT]` with custom instructions.
    # Note: --uncommitted and [PROMPT] are mutually exclusive — we use [PROMPT] to
    # inject project conventions, file scope, and anti-pattern checklists.
    # The prompt tells Codex to `git diff` the specific files.
    # Review output goes to stderr; capture to review file.
    # shellcheck disable=SC2086
    codex exec review "$CODEX_PROMPT" $CODEX_FLAGS \
      >/dev/null 2>"$REVIEW_FILE" || CODEX_EXIT=$?
    ELAPSED=$(( $(date +%s) - START_TIME ))
    log "Codex finished (exit=$CODEX_EXIT, elapsed=${ELAPSED}s)"

    # Wait for quality checks to finish (usually done before Codex)
    wait $QUALITY_PID 2>/dev/null || true
    log "Quality checks finished"

    # Append quality check results AFTER codex is done (no race)
    if [ -f "$QUALITY_TMPFILE" ] && [ -s "$QUALITY_TMPFILE" ]; then
      cat "$QUALITY_TMPFILE" >> "$REVIEW_FILE"
      log "Quality checks: appended to review file"
    fi
    rm -f "$QUALITY_TMPFILE"

    # Strip noise from stderr capture (MCP startup, thinking lines, exec traces, session header)
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' '/^mcp:/d; /^Warning:/d; /^thinking$/d; /^exec$/d; /^user$/d; /^OpenAI Codex/d; /^--------$/d; /^workdir:/d; /^model:/d; /^provider:/d; /^approval:/d; /^sandbox:/d; /^reasoning/d; /^session id:/d' "$REVIEW_FILE"
    else
      sed -i '/^mcp:/d; /^Warning:/d; /^thinking$/d; /^exec$/d; /^user$/d; /^OpenAI Codex/d; /^--------$/d; /^workdir:/d; /^model:/d; /^provider:/d; /^approval:/d; /^sandbox:/d; /^reasoning/d; /^session id:/d' "$REVIEW_FILE"
    fi

    # Extract just the final review (after "codex" marker — the actual review output)
    # Codex stderr has: session header → thinking/exec traces → "codex\n<actual review>"
    if grep -q "^codex$" "$REVIEW_FILE" 2>/dev/null; then
      # Keep only content after the last "codex" line (the actual review)
      REVIEW_START=$(grep -n "^codex$" "$REVIEW_FILE" | tail -1 | cut -d: -f1)
      if [ -n "$REVIEW_START" ]; then
        tail -n +"$((REVIEW_START + 1))" "$REVIEW_FILE" > "${REVIEW_FILE}.tmp"
        mv "${REVIEW_FILE}.tmp" "$REVIEW_FILE"
      fi
    fi

    # Transition to addressing phase
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' 's/^phase: task$/phase: addressing/' "$STATE_FILE"
    else
      sed -i 's/^phase: task$/phase: addressing/' "$STATE_FILE"
    fi

    if [ ! -s "$REVIEW_FILE" ]; then
      log "WARN: Codex produced no review findings (exit=$CODEX_EXIT)"
      rm -f "$REVIEW_FILE" "$STATE_FILE"
      cleanup_tracking
      printf '{"decision":"approve"}\n'
      exit 0
    fi

    REASON="An independent multi-agent code review from Codex has been written to ${REVIEW_FILE}.

Please:
1. Read the review carefully
2. For each item, independently decide if you agree
3. For items you AGREE with: implement the fix
4. For items you DISAGREE with: briefly note why you are skipping them
5. Focus on critical and high severity items first
6. When done addressing all relevant items, you may stop

Use your own judgment. Do not blindly accept every suggestion."

    SYS_MSG="Review Loop [${REVIEW_ID}] — Phase 2/3: Address Codex feedback"

    jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
      '{decision:"block", reason:$r, systemMessage:$s}'
    ;;

  addressing)
    # ── Phase 2 → 3: Transition to compound phase ────────────────────────

    if [ "${REVIEW_LOOP_SKIP_COMPOUND:-false}" = "true" ]; then
      log "Compound phase: skipped (REVIEW_LOOP_SKIP_COMPOUND=true)"
      rm -f "$STATE_FILE"
      cleanup_tracking
      printf '{"decision":"approve"}\n'
      exit 0
    fi

    # Resolve output dir and ensure it exists
    OUTPUT_DIR=$(resolve_output_dir)
    mkdir -p "$OUTPUT_DIR"

    # Initialize progress file if needed
    if [ ! -f "$OUTPUT_DIR/progress.txt" ]; then
      {
        echo "# Review Loop — Progress & Learnings"
        echo "Started: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo ""
        echo "## Codebase Patterns"
        echo ""
        echo "---"
      } > "$OUTPUT_DIR/progress.txt"
      log "Compound: initialized $OUTPUT_DIR/progress.txt"
    fi

    # Re-read scoped files for compound prompt
    SCOPED_FILES=$(get_scoped_files)
    REVIEW_FILE="${REPO_ROOT}/reviews/review-${REVIEW_ID}.md"

    # Transition to compound phase
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' 's/^phase: addressing$/phase: compound/' "$STATE_FILE"
    else
      sed -i 's/^phase: addressing$/phase: compound/' "$STATE_FILE"
    fi

    REASON=$(build_compound_prompt "$REVIEW_FILE" "$SCOPED_FILES" "$OUTPUT_DIR")
    SYS_MSG="Review Loop [${REVIEW_ID}] — Phase 3/3: Extract reusable knowledge"

    log "Compound phase: starting (output_dir=$OUTPUT_DIR)"

    jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
      '{decision:"block", reason:$r, systemMessage:$s}'
    ;;

  compound)
    # ── Phase 3 complete: Knowledge extracted. Allow exit. ────────────────
    log "Review loop complete with compounding (review_id=$REVIEW_ID)"
    rm -f "$STATE_FILE"
    cleanup_tracking
    printf '{"decision":"approve"}\n'
    ;;

  *)
    # Unknown phase — clean up and allow exit
    log "WARN: unknown phase '$PHASE', cleaning up"
    rm -f "$STATE_FILE"
    cleanup_tracking
    printf '{"decision":"approve"}\n'
    ;;
esac
