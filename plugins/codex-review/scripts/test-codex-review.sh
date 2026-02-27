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

codex exec review --uncommitted --dangerously-bypass-approvals-and-sandbox \
  >/dev/null 2>"$OUTFILE" || true

ELAPSED=$(( $(date +%s) - START ))
SIZE=$(wc -c < "$OUTFILE" | tr -d ' ')

echo "   Done in ${ELAPSED}s, raw output: ${SIZE} bytes → $OUTFILE"

# Extract final review (after last "codex" marker)
if grep -q "^codex$" "$OUTFILE" 2>/dev/null; then
  REVIEW_START=$(grep -n "^codex$" "$OUTFILE" | tail -1 | cut -d: -f1)
  tail -n +"$((REVIEW_START + 1))" "$OUTFILE" > "${OUTFILE}.clean"
  mv "${OUTFILE}.clean" "$OUTFILE"
fi

SIZE_CLEAN=$(wc -c < "$OUTFILE" | tr -d ' ')

echo ""
if [ "$SIZE_CLEAN" -gt 10 ]; then
  echo "=== REVIEW ($SIZE_CLEAN bytes) ==="
  cat "$OUTFILE"
  echo ""
  echo "=== END ==="
else
  echo "FAIL: empty or near-empty output ($SIZE_CLEAN bytes after cleaning)"
fi
