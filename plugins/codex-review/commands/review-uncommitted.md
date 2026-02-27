---
description: "Run Codex review on current uncommitted changes (standalone, no review-loop session needed)"
allowed-tools:
  - Bash
  - Read
---

Run the following script to get a Codex code review on current uncommitted changes. Uses custom prompt with project
conventions and file scope — same review quality as the full review loop.

```bash
set -e

echo "=== Codex Review: uncommitted changes ==="

# 1. Prerequisites
command -v codex >/dev/null 2>&1 || { echo "ERROR: codex not installed (npm install -g @openai/codex)"; exit 1; }

# 2. Collect changed files
FILES=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)
FILES=$(echo "$FILES" | sort -u | grep -v '^$' || true)
FILE_COUNT=$(echo "$FILES" | grep -c . 2>/dev/null) || FILE_COUNT=0

if [ "$FILE_COUNT" -eq 0 ]; then
  echo "ERROR: No uncommitted changes found."
  exit 1
fi

echo "Files to review ($FILE_COUNT):"
echo "$FILES" | sed 's/^/  - /'

# 3. Load project conventions (full AGENTS.md or CLAUDE.md — intent layer root node)
CONVENTIONS=""
if [ -f "AGENTS.md" ]; then
  CONVENTIONS=$(cat AGENTS.md 2>/dev/null || true)
elif [ -f "CLAUDE.md" ]; then
  CONVENTIONS=$(cat CLAUDE.md 2>/dev/null || true)
fi

CONVENTIONS_BLOCK=""
if [ -n "$CONVENTIONS" ]; then
  CONVENTIONS_BLOCK="
PROJECT CONVENTIONS (review against these standards):
---
${CONVENTIONS}
---"
fi

# 4. Build focused review prompt
FILE_SCOPE="IMPORTANT — FILE SCOPE: Only review changes in these specific files:
$(echo "$FILES" | sed 's/^/  - /')

For each file: run \`git diff -- <file>\` for tracked files. For NEW (untracked) files, run \`cat <file>\` — git diff shows nothing for untracked files. Do NOT review unrelated changes."

PROMPT="You are performing a thorough, independent code review of recent changes in this repository.

${FILE_SCOPE}

${CONVENTIONS_BLOCK}

Review criteria:

Code Quality:
- Well-organized, modular, readable? DRY? Clear names? Right abstraction level?

Test Coverage:
- Every new function/endpoint has tests? Edge cases covered? Tests verify behavior not implementation?

Security:
- Input validation? Auth checks? Injection risks (SQL, XSS, command, path traversal)?
- Secrets hardcoded or logged? OWASP Top 10?

AI Agent Anti-Patterns (CRITICAL):
- Mocks/stubs just to pass tests instead of testing real behavior?
- Code replaced with comments like '// implementation here' or '// TODO'?
- Unused parameters prefixed with underscore (_param) to suppress lint?
- Hardcoded values that should use existing constants/enums?
- New utility functions that duplicate existing ones?

For each issue: [P0-P3] Title — file:line, description, suggested fix.
End with summary."

# 5. Run codex exec review with custom prompt
# Note: [PROMPT] and --uncommitted are mutually exclusive — we use [PROMPT]
# to inject project conventions and file scope. The prompt tells Codex to git diff.
REVIEW_FILE="/tmp/codex-review-$(date +%Y%m%d-%H%M%S).md"
CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
START_TIME=$(date +%s)
CODEX_EXIT=0

echo ""
echo "Output → $REVIEW_FILE"
echo "---"

# shellcheck disable=SC2086
codex exec review "$PROMPT" $CODEX_FLAGS \
  >/dev/null 2>"$REVIEW_FILE" || CODEX_EXIT=$?

ELAPSED=$(( $(date +%s) - START_TIME ))

# 6. Extract clean review from stderr
# Codex stderr: session header → thinking/exec traces → "codex\n<actual review>"
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' '/^mcp:/d; /^Warning:/d; /^thinking$/d; /^exec$/d; /^user$/d; /^OpenAI Codex/d; /^--------$/d; /^workdir:/d; /^model:/d; /^provider:/d; /^approval:/d; /^sandbox:/d; /^reasoning/d; /^session id:/d' "$REVIEW_FILE" 2>/dev/null || true
else
  sed -i '/^mcp:/d; /^Warning:/d; /^thinking$/d; /^exec$/d; /^user$/d; /^OpenAI Codex/d; /^--------$/d; /^workdir:/d; /^model:/d; /^provider:/d; /^approval:/d; /^sandbox:/d; /^reasoning/d; /^session id:/d' "$REVIEW_FILE" 2>/dev/null || true
fi

if grep -q "^codex$" "$REVIEW_FILE" 2>/dev/null; then
  REVIEW_START=$(grep -n "^codex$" "$REVIEW_FILE" | tail -1 | cut -d: -f1)
  if [ -n "$REVIEW_START" ]; then
    tail -n +"$((REVIEW_START + 1))" "$REVIEW_FILE" > "${REVIEW_FILE}.clean"
    mv "${REVIEW_FILE}.clean" "$REVIEW_FILE"
  fi
fi

echo "---"
echo "Codex exit=$CODEX_EXIT, elapsed=${ELAPSED}s"
echo "Review: $REVIEW_FILE ($(wc -c < "$REVIEW_FILE" | tr -d ' ') bytes)"
```

After the script completes, read the review file and present the findings to the user. For each finding, include severity,
file path, and description.
