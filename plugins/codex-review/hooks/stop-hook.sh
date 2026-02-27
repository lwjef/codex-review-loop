#!/usr/bin/env bash
# Codex Review — Stop Hook
#
# Three-phase lifecycle:
#   Phase 1 (task):       Claude finishes work → hook runs N parallel Codex reviews → blocks exit
#   Phase 2 (addressing): Claude addresses review findings → blocks exit
#   Phase 3 (compound):   Claude extracts reusable lore → updates nearest AGENTS.md → allows exit
#
# On any error, default to allowing exit (never trap the user in a broken loop).
#
# Features:
#   - N parallel Codex processes (diff, holistic, security, tests, +conditional nextjs)
#   - File-scoped reviews: only reviews files THIS agent modified (parallel agent safe)
#   - Project conventions injected into review prompts (from AGENTS.md)
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
#   REVIEW_LOOP_SINGLE_AGENT      Set to "true" to use single codex process (default: parallel)

# Resolve repo root — hooks may run from any CWD (e.g., apps/backend)
# All .claude/ paths must be absolute to work regardless of CWD.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

LOG_FILE="${REPO_ROOT}/.claude/codex-review.log"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

trap 'log "ERROR: hook exited via ERR trap (line $LINENO)"; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

# Consume stdin (hook input JSON) — must read to avoid broken pipe
HOOK_INPUT=$(cat)

# ── Find state file for THIS session ──────────────────────────────────
# State files are per-review: .claude/codex-review-{REVIEW_ID}.local.md
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
  STATE_FILE=$(grep -l "session_id: ${SESSION_ID}" "${REPO_ROOT}"/.claude/codex-review-*.local.md 2>/dev/null | head -1)
fi

# Try 2: fallback — find active state files
if [ -z "$STATE_FILE" ] || [ ! -f "$STATE_FILE" ]; then
  ACTIVE_FILES=""
  for sf in "${REPO_ROOT}"/.claude/codex-review-*.local.md; do
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

# ── Build shared review context (sets _CTX_* globals) ──────────────────
# Must be called before any build_*_prompt function.
build_review_context() {
  local SCOPED_FILES="$1"

  _CTX_IS_NEXTJS=false
  detect_nextjs && _CTX_IS_NEXTJS=true
  log "Project detection: nextjs=$_CTX_IS_NEXTJS"

  # File scope instruction
  _CTX_FILE_SCOPE=""
  if [ -n "$SCOPED_FILES" ]; then
    _CTX_FILE_SCOPE="IMPORTANT — FILE SCOPE: Only review these files (this agent's modifications):
$(echo "$SCOPED_FILES" | sed 's/^/  - /')

For tracked files: \`git diff -- <file>\`. For NEW (untracked) files: \`cat <file>\` (git diff shows nothing for untracked).
Do NOT review unrelated changes."
  fi

  # Project conventions
  local CONVENTIONS
  CONVENTIONS=$(load_project_conventions)
  _CTX_CONVENTIONS=""
  if [ -n "$CONVENTIONS" ]; then
    _CTX_CONVENTIONS="PROJECT CONVENTIONS (from AGENTS.md):
---
${CONVENTIONS}
---"
  fi

  # Dependency map
  _CTX_MAP=""
  local MAP_OUTPUT
  MAP_OUTPUT=$(generate_scoped_map "$SCOPED_FILES")
  if [ -n "$MAP_OUTPUT" ]; then
    _CTX_MAP="DEPENDENCY MAP (impacted modules):
\`\`\`
${MAP_OUTPUT}
\`\`\`"
  fi

  # Module dirs for holistic scope
  _CTX_HOLISTIC_SCOPE=""
  if [ -n "$SCOPED_FILES" ]; then
    local HDIRS
    HDIRS=$(echo "$SCOPED_FILES" | sed 's|^\./||' | awk -F'/' '
      /^(apps|services|packages|libs|modules)\/[^/]+/ { print $1"/"$2; next }
      NF >= 2 { print $1; next }
    ' | sort -u)
    if [ -n "$HDIRS" ]; then
      _CTX_HOLISTIC_SCOPE="SCOPE: Only review structure within these modules:
$(echo "$HDIRS" | sed 's/^/  - /')
Do NOT scan the entire repository."
    fi
  fi
}

# ── Per-agent prompt builders (call build_review_context first) ────────

build_diff_prompt() {
  local SCOPED_FILES="$1"
  local DIFF_CMD
  if [ -n "$SCOPED_FILES" ]; then
    DIFF_CMD="For each scoped file listed above: run \`git diff -- <file>\` for tracked files. For NEW (untracked) files, run \`cat <file>\` to read the full content — \`git diff\` shows nothing for untracked files."
  else
    DIFF_CMD="Run \`git diff\` and \`git diff --cached\` to see all uncommitted changes. Also run \`git log --oneline -5\` and \`git diff HEAD~5\` for recently committed work."
  fi

  cat << DIFF_EOF
You are performing an independent code review focused on the DIFF of recent changes.

${_CTX_FILE_SCOPE}

${_CTX_CONVENTIONS}

${_CTX_MAP}

${DIFF_CMD}
Focus your review EXCLUSIVELY on changed code.

Review criteria:

Code Quality:
- Well-organized, modular, readable?
- DRY — no copy-pasted blocks that should be abstracted?
- Clear, consistent names?
- Right level of abstraction?
- Unnecessary complexity?

Test Coverage:
- Every new function/endpoint/component has tests?
- Edge cases: empty inputs, nulls, boundary values, error paths?
- Tests isolated, deterministic, fast?
- Tests verify behavior (not implementation)?
- Bug fixes have regression tests?

Security:
- Input validation on all user inputs?
- Auth checks on protected routes?
- Injection risks (SQL, XSS, command, path traversal)?
- No hardcoded secrets?
- OWASP Top 10 checks
- Error messages safe (no stack traces leaked)?

AI Agent Anti-Patterns (CRITICAL):
- Mocks/stubs just to pass tests instead of testing real behavior?
- Real code replaced with "// implementation here" or "// TODO"?
- Unused _param to suppress lint?
- Hardcoded values that should use existing constants?
- New utility functions duplicating existing ones?
- Unnecessary type assertions (as any, !)?

For each issue: [P0/P1/P2/P3] description — file:line
P0=blocks ship, P1=must fix before merge, P2=should fix, P3=nice to have
DIFF_EOF
}

build_holistic_prompt() {
  cat << HOLISTIC_EOF
You are performing an independent code review focused on ARCHITECTURE and STRUCTURE of changed modules.

${_CTX_FILE_SCOPE}

${_CTX_MAP}

${_CTX_HOLISTIC_SCOPE:-Read directory structure, config files, AGENTS.md / CLAUDE.md in modules where changes were made.}

This is NOT about individual line changes — it's about whether changed modules are well-structured.

Review criteria:

Code Organization:
- Module structure logical and navigable?
- Concerns properly separated (data access, business logic, presentation)?
- God files/functions that should be split?
- Shared code properly extracted?
- Clean import paths?

Documentation & Agent Readiness:
- Module has AGENTS.md with guidelines?
- AGENTS.md documents: conventions, file purposes, testing patterns, pitfalls?
- Proper type coverage?
- Environment variables documented and validated?

Architecture (within module boundary):
- Clean dependency graph (no circular deps)?
- External integrations abstracted behind interfaces?
- Configuration centralized?
- Error handling consistent?

For each issue: [P0/P1/P2/P3] description — file:line (or directory)
P0=blocks ship, P1=must fix before merge, P2=should fix, P3=nice to have
HOLISTIC_EOF
}

build_security_prompt() {
  cat << SECURITY_EOF
You are performing an independent SECURITY-focused code review of recent changes.

${_CTX_FILE_SCOPE}

${_CTX_CONVENTIONS}

For each scoped file: run \`git diff -- <file>\` for tracked files, \`cat <file>\` for untracked files.

Authentication & Authorization:
- Auth checks present on ALL protected routes/endpoints?
- Authorization checked (not just authentication) — correct role/permissions?
- Session management secure (expiry, rotation, invalidation)?
- API keys/tokens not exposed in client-side code?

Input Validation & Injection:
- ALL user inputs validated and sanitized?
- SQL injection risks (raw queries, string interpolation)?
- XSS risks (unescaped output, innerHTML, dangerouslySetInnerHTML)?
- Command injection (shell exec with user input)?
- Path traversal (user input in file paths)?
- SSRF (user-controlled URLs in server-side requests)?

Data Protection:
- Secrets/credentials hardcoded or logged?
- PII exposure in logs, errors, or API responses?
- Error messages leak internal details?
- Sensitive data in URL params?

Rate Limiting & Abuse:
- New endpoints have rate limiting?
- Expensive operations protected from abuse?
- File upload limits and type validation?

For each issue: [P0/P1/P2/P3] description — file:line
P0=blocks ship (exploit possible), P1=must fix, P2=defense-in-depth, P3=hardening
SECURITY_EOF
}

build_tests_prompt() {
  cat << TESTS_EOF
You are performing an independent code review focused on TEST QUALITY and COVERAGE.

${_CTX_FILE_SCOPE}

For each scoped file: run \`git diff -- <file>\` for tracked files, \`cat <file>\` for untracked files.
Also examine existing test files in the same directories to understand testing patterns.

Missing Coverage:
- Every new public function/method has tests?
- Every new API endpoint has request/response tests?
- Error paths and exception handling tested?
- Edge cases covered (empty, null, boundary, overflow)?

Test Quality:
- Tests verify BEHAVIOR, not implementation details?
- Tests isolated (no shared mutable state)?
- Tests deterministic (no flaky timing/order)?
- Assertions specific enough to catch regressions?

Anti-Patterns:
- Mocking too much (testing mocks not real behavior)?
- Testing private internals instead of public API?
- Tests that always pass (tautological assertions)?
- Overly broad error assertions?

Integration:
- DB-writing code tested with actual DB ops (not just mocks)?
- API routes tested with full request cycle?
- Multi-step workflows have integration tests?

For each issue: [P0/P1/P2/P3] description — file:line
P0=untested critical path, P1=significant gap, P2=should add, P3=nice to have
TESTS_EOF
}

build_nextjs_prompt() {
  cat << 'NEXTJS_EOF'
You are performing an independent code review focused on NEXT.JS and REACT best practices.

For each scoped file: run `git diff -- <file>` for tracked files, `cat <file>` for untracked files.

App Router & Server Components:
- Server Components by default? 'use client' only when needed?
- Data fetched in Server Components, not Client Components?
- Suspense boundaries for streaming?
- Correct file conventions: layout.tsx, page.tsx, loading.tsx, error.tsx?
- searchParams/params handled as Promises?
- generateStaticParams() for known dynamic routes?
- generateMetadata() for SEO-critical pages?

Data Fetching & Caching:
- Parallel data fetches (Promise.all) vs sequential waterfalls?
- Appropriate cache strategy (no-store/force-cache/revalidate)?
- Cache tags for fine-grained invalidation?

Performance & Bundle Size:
- No barrel file imports?
- next/dynamic for heavy client-only components?
- Non-critical libraries deferred until after hydration?
- Data minimized across RSC boundary?

React Performance:
- Derived state in render, not effects?
- Expensive computations memoized?
- useTransition for non-urgent updates?
- No unnecessary useEffect for event handler work?
- Stable callback references?

For each issue: [P0/P1/P2/P3] description — file:line
P0=blocks ship, P1=must fix before merge, P2=should fix, P3=nice to have
NEXTJS_EOF
}

# ── Build single-agent review prompt (fallback for REVIEW_LOOP_SINGLE_AGENT=true) ──
build_single_agent_prompt() {
  local SCOPED_FILES="$1"

  build_review_context "$SCOPED_FILES"

  cat << SINGLE_EOF
You are performing a thorough, independent code review of recent changes in this repository.

${_CTX_FILE_SCOPE}

${_CTX_CONVENTIONS}

${_CTX_MAP}

$(build_diff_prompt "$SCOPED_FILES")

For each issue: [P0/P1/P2/P3] description — file:line
P0=blocks ship, P1=must fix before merge, P2=should fix, P3=nice to have
SINGLE_EOF
}

# ── Clean codex stderr output ──────────────────────────────────────────
clean_codex_output() {
  local FILE="$1"
  [ -f "$FILE" ] || return

  # Remove codex noise lines (session header, thinking traces, MCP startup)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' '/^mcp:/d; /^Warning:/d; /^thinking$/d; /^exec$/d; /^user$/d; /^OpenAI Codex/d; /^--------$/d; /^workdir:/d; /^model:/d; /^provider:/d; /^approval:/d; /^sandbox:/d; /^reasoning/d; /^session id:/d' "$FILE"
  else
    sed -i '/^mcp:/d; /^Warning:/d; /^thinking$/d; /^exec$/d; /^user$/d; /^OpenAI Codex/d; /^--------$/d; /^workdir:/d; /^model:/d; /^provider:/d; /^approval:/d; /^sandbox:/d; /^reasoning/d; /^session id:/d' "$FILE"
  fi

  # Extract content after last "codex" marker (the actual review output)
  if grep -q "^codex$" "$FILE" 2>/dev/null; then
    local REVIEW_START
    REVIEW_START=$(grep -n "^codex$" "$FILE" | tail -1 | cut -d: -f1)
    if [ -n "$REVIEW_START" ]; then
      tail -n +"$((REVIEW_START + 1))" "$FILE" > "${FILE}.clean"
      mv "${FILE}.clean" "$FILE"
    fi
  fi
}

# ── Parallel codex review execution ───────────────────────────────────
run_parallel_codex_reviews() {
  local REVIEW_FILE="$1"
  local SCOPED_FILES="$2"
  local CODEX_FLAGS="$3"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  local PIDS=()
  local AGENT_NAMES=()
  local AGENT_LABELS=()
  local START_TIME
  START_TIME=$(date +%s)

  # Build shared context (sets _CTX_* globals)
  build_review_context "$SCOPED_FILES"

  # Agent 1: Diff Review (always)
  AGENT_NAMES+=("diff")
  AGENT_LABELS+=("Diff Review")
  local DIFF_PROMPT
  DIFF_PROMPT=$(build_diff_prompt "$SCOPED_FILES")
  # shellcheck disable=SC2086
  codex exec review "$DIFF_PROMPT" $CODEX_FLAGS >/dev/null 2>"${TMPDIR}/diff.raw" &
  PIDS+=($!)

  # Agent 2: Holistic Review (always)
  AGENT_NAMES+=("holistic")
  AGENT_LABELS+=("Holistic Review")
  local HOLISTIC_PROMPT
  HOLISTIC_PROMPT=$(build_holistic_prompt)
  # shellcheck disable=SC2086
  codex exec review "$HOLISTIC_PROMPT" $CODEX_FLAGS >/dev/null 2>"${TMPDIR}/holistic.raw" &
  PIDS+=($!)

  # Agent 3: Security Review (always)
  AGENT_NAMES+=("security")
  AGENT_LABELS+=("Security Review")
  local SECURITY_PROMPT
  SECURITY_PROMPT=$(build_security_prompt)
  # shellcheck disable=SC2086
  codex exec review "$SECURITY_PROMPT" $CODEX_FLAGS >/dev/null 2>"${TMPDIR}/security.raw" &
  PIDS+=($!)

  # Agent 4: Test Coverage Review (always)
  AGENT_NAMES+=("tests")
  AGENT_LABELS+=("Test Coverage Review")
  local TESTS_PROMPT
  TESTS_PROMPT=$(build_tests_prompt)
  # shellcheck disable=SC2086
  codex exec review "$TESTS_PROMPT" $CODEX_FLAGS >/dev/null 2>"${TMPDIR}/tests.raw" &
  PIDS+=($!)

  # Agent 5: Next.js (conditional)
  if [ "$_CTX_IS_NEXTJS" = "true" ]; then
    AGENT_NAMES+=("nextjs")
    AGENT_LABELS+=("Next.js Best Practices")
    local NEXTJS_PROMPT
    NEXTJS_PROMPT=$(build_nextjs_prompt)
    # shellcheck disable=SC2086
    codex exec review "$NEXTJS_PROMPT" $CODEX_FLAGS >/dev/null 2>"${TMPDIR}/nextjs.raw" &
    PIDS+=($!)
  fi

  local AGENT_COUNT=${#PIDS[@]}
  log "Launched $AGENT_COUNT parallel codex agents"

  # Wait for all agents
  local FAILURES=0
  for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}" || {
      log "WARN: agent ${AGENT_NAMES[$i]} exited non-zero"
      FAILURES=$((FAILURES + 1))
    }
  done

  local ELAPSED=$(( $(date +%s) - START_TIME ))
  log "All $AGENT_COUNT agents finished (elapsed=${ELAPSED}s, failures=$FAILURES)"

  # Write review header
  {
    echo "# Code Review — ${AGENT_COUNT} Parallel Agents"
    echo ""
    echo "Review ID: ${REVIEW_ID}"
    echo "Files reviewed: $(echo "$SCOPED_FILES" | grep -c . 2>/dev/null || echo 0)"
    echo "Agents: ${AGENT_COUNT} | Duration: ${ELAPSED}s"
    echo ""
  } > "$REVIEW_FILE"

  # Clean and merge each agent's output
  for i in "${!AGENT_NAMES[@]}"; do
    local name="${AGENT_NAMES[$i]}"
    local label="${AGENT_LABELS[$i]}"
    local raw="${TMPDIR}/${name}.raw"

    clean_codex_output "$raw"

    {
      echo "---"
      echo "## Agent $((i + 1)): ${label}"
      echo ""
    } >> "$REVIEW_FILE"

    if [ -f "$raw" ] && [ -s "$raw" ]; then
      cat "$raw" >> "$REVIEW_FILE"
    else
      echo "_No findings from this agent._" >> "$REVIEW_FILE"
    fi
    echo "" >> "$REVIEW_FILE"
  done

  rm -rf "$TMPDIR"
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
  find "${REPO_ROOT}/.claude" -name "codex-review-*.local.md" -mmin +1440 -delete 2>/dev/null || true
}

case "$PHASE" in
  task)
    # ── Phase 1 → 2: Run Codex multi-agent review ──────────────────────
    REVIEW_FILE="${REPO_ROOT}/reviews/review-${REVIEW_ID}.md"
    mkdir -p "${REPO_ROOT}/reviews"

    # Get scoped files for this agent
    SCOPED_FILES=$(get_scoped_files)
    log "Scoped files for review: $(echo "$SCOPED_FILES" | tr '\n' ', ')"

    # Run codex non-interactively with telemetry logging.
    CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
    CODEX_EXIT=0

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

    log "Starting Codex review (flags: $CODEX_FLAGS, parallel=$( [ "${REVIEW_LOOP_SINGLE_AGENT:-false}" = "true" ] && echo "false" || echo "true" ))"

    # Run quality checks in parallel with Codex review (zero wasted time)
    # Quality checks write to a SEPARATE temp file to avoid race condition.
    QUALITY_TMPFILE="${REVIEW_FILE}.quality"
    run_quality_checks "$QUALITY_TMPFILE" "$SCOPED_FILES" &
    QUALITY_PID=$!

    if [ "${REVIEW_LOOP_SINGLE_AGENT:-false}" = "true" ]; then
      # Single-agent mode: one codex process with combined prompt
      CODEX_PROMPT=$(build_single_agent_prompt "$SCOPED_FILES")
      START_TIME=$(date +%s)
      # shellcheck disable=SC2086
      codex exec review "$CODEX_PROMPT" $CODEX_FLAGS \
        >/dev/null 2>"$REVIEW_FILE" || CODEX_EXIT=$?
      ELAPSED=$(( $(date +%s) - START_TIME ))
      log "Codex single-agent finished (exit=$CODEX_EXIT, elapsed=${ELAPSED}s)"
      clean_codex_output "$REVIEW_FILE"
    else
      # Parallel mode: N separate codex processes, one per review category
      run_parallel_codex_reviews "$REVIEW_FILE" "$SCOPED_FILES" "$CODEX_FLAGS"
    fi

    # Wait for quality checks to finish
    wait $QUALITY_PID 2>/dev/null || true
    log "Quality checks finished"

    # Append quality check results AFTER codex is done (no race)
    if [ -f "$QUALITY_TMPFILE" ] && [ -s "$QUALITY_TMPFILE" ]; then
      cat "$QUALITY_TMPFILE" >> "$REVIEW_FILE"
      log "Quality checks: appended to review file"
    fi
    rm -f "$QUALITY_TMPFILE"

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
