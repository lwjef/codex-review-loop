---
description: "Run Codex review on current uncommitted changes (standalone, no review-loop session needed)"
allowed-tools:
  - Bash
  - Read
---

Run the following test script to exercise the Codex review pipeline on the current repo's uncommitted changes. This is a dry-run — no state files, no phase transitions, no blocking.

```bash
set -e

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"

echo "=== Test Review: exercising Codex review pipeline ==="

# 1. Check prerequisites
command -v codex >/dev/null 2>&1 || { echo "ERROR: codex not installed (npm install -g @openai/codex)"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not installed"; exit 1; }

CODEX_CONFIG="${HOME}/.codex/config.toml"
if [ ! -f "$CODEX_CONFIG" ] || ! grep -qE '^\s*multi_agent\s*=\s*true' "$CODEX_CONFIG"; then
  echo "WARN: multi_agent not enabled in $CODEX_CONFIG"
fi

# 2. Collect changed files
FILES=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)
FILES=$(echo "$FILES" | sort -u | grep -v '^$' || true)
FILE_COUNT=$(echo "$FILES" | grep -c . 2>/dev/null || echo 0)

if [ "$FILE_COUNT" -eq 0 ]; then
  echo "ERROR: No uncommitted changes found. Make some changes first."
  exit 1
fi

echo "Changed files ($FILE_COUNT):"
echo "$FILES" | sed 's/^/  - /'

# 3. Build a minimal review prompt (same structure as stop-hook, but trimmed)
REVIEW_FILE="/tmp/test-review-$(date +%Y%m%d-%H%M%S).md"

FILE_SCOPE="IMPORTANT — FILE SCOPE: Only review changes in these specific files:
$(echo "$FILES" | sed 's/^/  - /')

Use \`git diff -- <file>\` for each file above."

PROMPT="You are performing an independent code review of uncommitted changes.

${FILE_SCOPE}

Review criteria:
- Code quality: readability, DRY, naming, complexity
- Security: input validation, injection risks, secrets, OWASP Top 10
- Test coverage: are changes tested? Edge cases?
- AI anti-patterns: mocks instead of real tests, unused _params, hardcoded values, duplicated utils

For each issue: file path, line, severity (critical/high/medium/low), description, suggested fix.
End with a summary."

# 4. Run codex exec review
echo ""
echo "Running: codex exec review --uncommitted (stderr → $REVIEW_FILE)"
echo "---"

CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
START_TIME=$(date +%s)
CODEX_EXIT=0

# shellcheck disable=SC2086
echo "$PROMPT" | codex exec review --uncommitted $CODEX_FLAGS - \
  >/dev/null 2>"$REVIEW_FILE" || CODEX_EXIT=$?

ELAPSED=$(( $(date +%s) - START_TIME ))

# Strip MCP noise
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' '/^mcp:/d; /^Warning:/d' "$REVIEW_FILE" 2>/dev/null || true
else
  sed -i '/^mcp:/d; /^Warning:/d' "$REVIEW_FILE" 2>/dev/null || true
fi

echo "---"
echo "Codex exit=$CODEX_EXIT, elapsed=${ELAPSED}s"
echo "Review file: $REVIEW_FILE"
echo "Review size: $(wc -c < "$REVIEW_FILE" | tr -d ' ') bytes"
echo ""

if [ -s "$REVIEW_FILE" ]; then
  echo "=== REVIEW OUTPUT ==="
  cat "$REVIEW_FILE"
  echo ""
  echo "=== END ==="
else
  echo "WARNING: Review file is empty — Codex produced no output."
  echo ""
  echo "Debug: try running manually:"
  echo "  echo 'Review this code for bugs' | codex exec review --uncommitted --dangerously-bypass-approvals-and-sandbox - 2>/tmp/review-test.md"
  echo "  cat /tmp/review-test.md"
fi
```

After the script runs, read the review file and present the results.
