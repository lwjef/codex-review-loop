#!/usr/bin/env bash
# Check Unused Parameters — PostToolUse Hook
#
# Detects lazy refactoring where parameters are prefixed with _ instead of removed.
# Only flags when an Edit CHANGES a param to its underscore version (not pre-existing _params).
#
# Ported from ClaudeKit's check-unused-parameters.ts (shell, no deps).

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)

# Only check Edit
[ "$TOOL_NAME" != "Edit" ] && exit 0

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)

# Only check TS/JS files
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) ;;
  *) exit 0 ;;
esac

OLD_STRING=$(echo "$INPUT" | jq -r '.tool_input.old_string // ""' 2>/dev/null)
NEW_STRING=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null)

[ -z "$OLD_STRING" ] || [ -z "$NEW_STRING" ] && exit 0

# Extract parameter names from function signatures
# Looks for (param1, param2) patterns and extracts names before : or =
extract_params() {
  # Match content inside parentheses in function/arrow signatures
  echo "$1" | grep -oE '\([^)]+\)' | head -1 | \
    tr ',' '\n' | \
    sed 's/[[:space:]]//g' | \
    sed 's/:.*//' | \
    sed 's/=.*//' | \
    sed 's/^\.\.\.//' | \
    grep -v '^$'
}

OLD_PARAMS=$(extract_params "$OLD_STRING")
NEW_PARAMS=$(extract_params "$NEW_STRING")

# No params to compare
[ -z "$OLD_PARAMS" ] || [ -z "$NEW_PARAMS" ] && exit 0

# Compare: did any param get underscore-prefixed?
VIOLATIONS=""
while IFS= read -r old_param; do
  # Check if new params contain _oldparam
  if echo "$NEW_PARAMS" | grep -qx "_${old_param}"; then
    VIOLATIONS="${VIOLATIONS}  ${old_param} → _${old_param}\n"
  fi
done <<< "$OLD_PARAMS"

if [ -n "$VIOLATIONS" ]; then
  printf '⚠️ Lazy parameter refactoring detected.\n\n'
  printf 'Parameters renamed to underscore prefix instead of being removed:\n'
  printf '%b' "$VIOLATIONS"
  printf '\nFix: remove unused parameters entirely, or document why they must stay.\n'
  printf 'If required by interface/callback signature, add a comment explaining why.\n'
fi
