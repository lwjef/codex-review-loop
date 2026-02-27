---
description: "Run Codex review on current uncommitted changes (standalone, no review-loop session needed)"
allowed-tools:
  - Bash
  - Read
---

Run the following script to get a Codex code review on current uncommitted changes. No state files, no phase transitions — just the review.

```bash
set -e

echo "=== Codex Review: uncommitted changes ==="

# 1. Prerequisites
command -v codex >/dev/null 2>&1 || { echo "ERROR: codex not installed (npm install -g @openai/codex)"; exit 1; }

# 2. Verify there are changes to review
FILE_COUNT=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
STAGED_COUNT=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$((FILE_COUNT + STAGED_COUNT))

if [ "$TOTAL" -eq 0 ]; then
  echo "ERROR: No uncommitted changes found."
  exit 1
fi

echo "Files to review: $FILE_COUNT unstaged, $STAGED_COUNT staged"
git diff --name-only 2>/dev/null | sed 's/^/  - /'
git diff --cached --name-only 2>/dev/null | sed 's/^/  - (staged) /'

# 3. Run codex exec review --uncommitted
# Note: --uncommitted and [PROMPT] are mutually exclusive in Codex CLI.
# Codex applies its own review criteria. Output goes to stderr.
REVIEW_FILE="/tmp/codex-review-$(date +%Y%m%d-%H%M%S).md"
CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
START_TIME=$(date +%s)
CODEX_EXIT=0

echo ""
echo "Output → $REVIEW_FILE"
echo "---"

# shellcheck disable=SC2086
codex exec review --uncommitted $CODEX_FLAGS \
  >/dev/null 2>"$REVIEW_FILE" || CODEX_EXIT=$?

ELAPSED=$(( $(date +%s) - START_TIME ))

# 4. Clean up stderr noise — extract just the review
# Codex stderr format: session header → thinking/exec traces → "codex\n<actual review>"
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' '/^mcp:/d; /^Warning:/d; /^thinking$/d; /^exec$/d; /^user$/d; /^OpenAI Codex/d; /^--------$/d; /^workdir:/d; /^model:/d; /^provider:/d; /^approval:/d; /^sandbox:/d; /^reasoning/d; /^session id:/d' "$REVIEW_FILE" 2>/dev/null || true
else
  sed -i '/^mcp:/d; /^Warning:/d; /^thinking$/d; /^exec$/d; /^user$/d; /^OpenAI Codex/d; /^--------$/d; /^workdir:/d; /^model:/d; /^provider:/d; /^approval:/d; /^sandbox:/d; /^reasoning/d; /^session id:/d' "$REVIEW_FILE" 2>/dev/null || true
fi

# Extract final review (content after last "codex" marker)
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

After the script completes, read the review file and present the findings to the user. For each finding, include severity, file path, and description.
