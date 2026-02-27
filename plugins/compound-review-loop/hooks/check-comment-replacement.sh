#!/usr/bin/env bash
# Check Comment Replacement — PostToolUse Hook
#
# Detects when code is replaced with comments (lazy AI anti-pattern).
# Fires on Edit tool. Compares old_string vs new_string.
#
# Ported from ClaudeKit's check-comment-replacement.ts (shell, no deps).

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)

# Only check Edit (Write has no old_string to compare)
[ "$TOOL_NAME" != "Edit" ] && exit 0

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)

# Skip docs/markdown
case "$FILE_PATH" in
  *.md|*.mdx|*.txt|*.rst) exit 0 ;;
esac

OLD_STRING=$(echo "$INPUT" | jq -r '.tool_input.old_string // ""' 2>/dev/null)
NEW_STRING=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null)

[ -z "$OLD_STRING" ] || [ -z "$NEW_STRING" ] && exit 0

# Count non-empty, non-comment lines in old vs new
count_code_lines() {
  local n
  n=$(echo "$1" | grep -v '^\s*$' | grep -cvE '^\s*(//|/\*|\*|#[^!]|--|<!--)' 2>/dev/null) || true
  echo "${n:-0}"
}

count_comment_lines() {
  local n
  n=$(echo "$1" | grep -v '^\s*$' | grep -cE '^\s*(//|/\*|\*|#[^!]|--|<!--)' 2>/dev/null) || true
  echo "${n:-0}"
}

count_nonempty() {
  local n
  n=$(echo "$1" | grep -cv '^\s*$' 2>/dev/null) || true
  echo "${n:-0}"
}

OLD_CODE=$(count_code_lines "$OLD_STRING")
OLD_TOTAL=$(count_nonempty "$OLD_STRING")
NEW_CODE=$(count_code_lines "$NEW_STRING")
NEW_TOTAL=$(count_nonempty "$NEW_STRING")
NEW_COMMENTS=$(count_comment_lines "$NEW_STRING")

# Skip if old had no actual code (was already all comments)
[ "$OLD_CODE" -eq 0 ] && exit 0

# Skip if new has no content
[ "$NEW_TOTAL" -eq 0 ] && exit 0

# Violation: old had code, new is ALL comments, and similar size (replacement not deletion)
if [ "$NEW_CODE" -eq 0 ] && [ "$NEW_COMMENTS" -gt 0 ]; then
  SIZE_DIFF=$(( OLD_TOTAL - NEW_TOTAL ))
  [ "$SIZE_DIFF" -lt 0 ] && SIZE_DIFF=$(( -SIZE_DIFF ))
  THRESHOLD=$(( OLD_TOTAL / 2 ))
  [ "$THRESHOLD" -lt 2 ] && THRESHOLD=2

  if [ "$SIZE_DIFF" -le "$THRESHOLD" ]; then
    cat << 'EOF'
⚠️ Code replaced with comments detected.

If removing code, delete it cleanly — don't replace with explanatory comments.
Use git commit messages to document WHY code was removed.

Fix: either keep the original code or delete it entirely.
EOF
    exit 0
  fi
fi
