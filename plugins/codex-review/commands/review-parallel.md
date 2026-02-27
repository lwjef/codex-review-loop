---
description: "Run N parallel Codex reviews on uncommitted changes (diff, holistic, security, tests)"
allowed-tools:
  - Bash
  - Read
---

Run the following script to launch parallel Codex code reviews on current uncommitted changes. Each agent focuses on a
different review category for deeper, more thorough analysis.

```bash
set -e

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT"

echo "=== Parallel Codex Review: uncommitted changes ==="

# 1. Prerequisites
command -v codex >/dev/null 2>&1 || { echo "ERROR: codex not installed (npm install -g @openai/codex)"; exit 1; }

# 2. Collect changed files
FILES=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)
# Include untracked files
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)
FILES=$(printf '%s\n%s' "$FILES" "$UNTRACKED" | sort -u | grep -v '^$' || true)
FILE_COUNT=$(echo "$FILES" | grep -c . 2>/dev/null) || FILE_COUNT=0

if [ "$FILE_COUNT" -eq 0 ]; then
  echo "ERROR: No uncommitted changes found."
  exit 1
fi

echo "Files to review ($FILE_COUNT):"
echo "$FILES" | sed 's/^/  - /'

# 3. Load project conventions
CONVENTIONS=""
if [ -f "AGENTS.md" ]; then
  CONVENTIONS=$(cat AGENTS.md 2>/dev/null || true)
elif [ -f "CLAUDE.md" ]; then
  CONVENTIONS=$(cat CLAUDE.md 2>/dev/null || true)
fi

CONVENTIONS_BLOCK=""
if [ -n "$CONVENTIONS" ]; then
  CONVENTIONS_BLOCK="PROJECT CONVENTIONS (from AGENTS.md):
---
${CONVENTIONS}
---"
fi

# 4. Build file scope instruction
FILE_SCOPE="IMPORTANT — FILE SCOPE: Only review these files:
$(echo "$FILES" | sed 's/^/  - /')

For tracked files: \`git diff -- <file>\`. For NEW (untracked) files: \`cat <file>\` (git diff shows nothing for untracked).
Do NOT review unrelated changes."

# 5. Build per-agent prompts
DIFF_PROMPT="You are performing an independent code review focused on the DIFF of recent changes.

${FILE_SCOPE}

${CONVENTIONS_BLOCK}

For each scoped file: run \`git diff -- <file>\` for tracked, \`cat <file>\` for untracked.

Review criteria — focus EXCLUSIVELY on changed code:

Code Quality: Well-organized, modular, readable? DRY? Clear names? Right abstraction level?
Test Coverage: Every new function/endpoint has tests? Edge cases? Tests verify behavior?
AI Agent Anti-Patterns (CRITICAL): Mocks just to pass tests? Code replaced with TODO? Unused _params? Hardcoded values? Duplicate utility functions?

For each issue: [P0/P1/P2/P3] description — file:line
P0=blocks ship, P1=must fix, P2=should fix, P3=nice to have"

HOLISTIC_PROMPT="You are performing an independent code review focused on ARCHITECTURE and STRUCTURE.

${FILE_SCOPE}

Review changed modules for:
Code Organization: Logical structure? Proper separation of concerns? God files? Clean imports?
Documentation: AGENTS.md present? Conventions documented? Type coverage?
Architecture: Clean dependency graph? Abstractions for external integrations? Centralized config?

For each issue: [P0/P1/P2/P3] description — file:line (or directory)
P0=blocks ship, P1=must fix, P2=should fix, P3=nice to have"

SECURITY_PROMPT="You are performing an independent SECURITY-focused code review.

${FILE_SCOPE}

${CONVENTIONS_BLOCK}

For each scoped file: run \`git diff -- <file>\` for tracked, \`cat <file>\` for untracked.

Auth: Auth checks on ALL protected routes? Authorization (not just authentication)? Sessions secure?
Injection: SQL injection? XSS? Command injection? Path traversal? SSRF?
Data: Secrets hardcoded/logged? PII in logs/errors? Error messages leak internals?
Abuse: Rate limiting? Expensive ops protected? Upload limits?

For each issue: [P0/P1/P2/P3] description — file:line
P0=exploit possible, P1=must fix, P2=defense-in-depth, P3=hardening"

TESTS_PROMPT="You are performing an independent code review focused on TEST QUALITY and COVERAGE.

${FILE_SCOPE}

For each scoped file: run \`git diff -- <file>\` for tracked, \`cat <file>\` for untracked.
Also examine existing test files in the same directories.

Missing Coverage: Every public function/endpoint has tests? Error paths tested? Edge cases?
Test Quality: Tests verify behavior not implementation? Isolated? Deterministic? Specific assertions?
Anti-Patterns: Over-mocking? Testing privates? Tautological assertions?
Integration: DB writes tested with real DB? API routes full cycle? Multi-step workflows?

For each issue: [P0/P1/P2/P3] description — file:line
P0=untested critical path, P1=significant gap, P2=should add, P3=nice to have"

# 6. Launch parallel agents
OUTDIR="/tmp/codex-parallel-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR"
CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
START_TIME=$(date +%s)

echo ""
echo "Output → $OUTDIR/"
echo "Launching 4 parallel codex agents..."
echo "---"

# shellcheck disable=SC2086
codex exec review "$DIFF_PROMPT" $CODEX_FLAGS >/dev/null 2>"${OUTDIR}/1-diff.raw" &
PID1=$!
# shellcheck disable=SC2086
codex exec review "$HOLISTIC_PROMPT" $CODEX_FLAGS >/dev/null 2>"${OUTDIR}/2-holistic.raw" &
PID2=$!
# shellcheck disable=SC2086
codex exec review "$SECURITY_PROMPT" $CODEX_FLAGS >/dev/null 2>"${OUTDIR}/3-security.raw" &
PID3=$!
# shellcheck disable=SC2086
codex exec review "$TESTS_PROMPT" $CODEX_FLAGS >/dev/null 2>"${OUTDIR}/4-tests.raw" &
PID4=$!

FAILURES=0
wait $PID1 || FAILURES=$((FAILURES + 1))
wait $PID2 || FAILURES=$((FAILURES + 1))
wait $PID3 || FAILURES=$((FAILURES + 1))
wait $PID4 || FAILURES=$((FAILURES + 1))

ELAPSED=$(( $(date +%s) - START_TIME ))

# 7. Clean each agent's output and merge
REVIEW_FILE="${OUTDIR}/review-combined.md"
{
  echo "# Parallel Code Review — 4 Agents"
  echo ""
  echo "Files: ${FILE_COUNT} | Agents: 4 | Duration: ${ELAPSED}s"
  echo ""
} > "$REVIEW_FILE"

for f in "${OUTDIR}"/*.raw; do
  [ -f "$f" ] || continue
  AGENT_NAME=$(basename "$f" .raw | sed 's/^[0-9]-//')

  # Strip codex noise
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' '/^mcp:/d; /^Warning:/d; /^thinking$/d; /^exec$/d; /^user$/d; /^OpenAI Codex/d; /^--------$/d; /^workdir:/d; /^model:/d; /^provider:/d; /^approval:/d; /^sandbox:/d; /^reasoning/d; /^session id:/d' "$f" 2>/dev/null || true
  else
    sed -i '/^mcp:/d; /^Warning:/d; /^thinking$/d; /^exec$/d; /^user$/d; /^OpenAI Codex/d; /^--------$/d; /^workdir:/d; /^model:/d; /^provider:/d; /^approval:/d; /^sandbox:/d; /^reasoning/d; /^session id:/d' "$f" 2>/dev/null || true
  fi

  # Extract after last "codex" marker
  if grep -q "^codex$" "$f" 2>/dev/null; then
    LINE=$(grep -n "^codex$" "$f" | tail -1 | cut -d: -f1)
    if [ -n "$LINE" ]; then
      tail -n +"$((LINE + 1))" "$f" > "${f}.clean"
      mv "${f}.clean" "$f"
    fi
  fi

  {
    echo "---"
    echo "## ${AGENT_NAME^} Review"
    echo ""
    if [ -s "$f" ]; then
      cat "$f"
    else
      echo "_No findings._"
    fi
    echo ""
  } >> "$REVIEW_FILE"
done

echo "---"
echo "4 agents finished (elapsed=${ELAPSED}s, failures=${FAILURES})"
echo "Combined review: $REVIEW_FILE ($(wc -c < "$REVIEW_FILE" | tr -d ' ') bytes)"
echo "Individual: ${OUTDIR}/*.raw"
```

After the script completes, read the combined review file and present the findings to the user. Organize by severity (P0
first), deduplicate across agents, and include file paths.
