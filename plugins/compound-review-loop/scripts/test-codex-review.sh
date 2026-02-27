#!/usr/bin/env bash
# Minimal Codex review test — run from any git repo with uncommitted changes.
# Usage: bash test-codex-review.sh
set -e

echo "1. Checking codex..."
command -v codex >/dev/null 2>&1 || { echo "FAIL: codex not installed"; exit 1; }
echo "   $(codex --version 2>&1 || echo 'version unknown')"

echo "2. Checking uncommitted changes..."
DIFF_STAT=$(git diff --stat 2>/dev/null || true)
CACHED_STAT=$(git diff --cached --stat 2>/dev/null || true)
if [ -z "$DIFF_STAT" ] && [ -z "$CACHED_STAT" ]; then
  echo "   FAIL: no uncommitted changes"
  exit 1
fi
echo "   $(git diff --name-only 2>/dev/null | wc -l | tr -d ' ') unstaged, $(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ') staged"

echo "3. Running codex exec review --uncommitted..."
OUTFILE="/tmp/codex-review-test-$(date +%s).md"
START=$(date +%s)

echo "Review the uncommitted changes for bugs and code quality issues." | \
  codex exec review --uncommitted --dangerously-bypass-approvals-and-sandbox - \
  >/dev/null 2>"$OUTFILE" || true

ELAPSED=$(( $(date +%s) - START ))
SIZE=$(wc -c < "$OUTFILE" | tr -d ' ')

echo "   Done in ${ELAPSED}s, output: ${SIZE} bytes → $OUTFILE"

# Strip noise
sed -i '' '/^mcp:/d; /^Warning:/d; /^$/d' "$OUTFILE" 2>/dev/null || true
SIZE_CLEAN=$(wc -c < "$OUTFILE" | tr -d ' ')

echo ""
if [ "$SIZE_CLEAN" -gt 10 ]; then
  echo "=== OUTPUT (first 50 lines) ==="
  head -50 "$OUTFILE"
  echo "=== END ==="
else
  echo "FAIL: empty or near-empty output ($SIZE_CLEAN bytes after cleaning)"
  echo ""
  echo "Try running directly:"
  echo '  echo "find bugs" | codex exec review --uncommitted --dangerously-bypass-approvals-and-sandbox - 2>&1 | head -30'
fi
