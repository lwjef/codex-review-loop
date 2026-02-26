#!/usr/bin/env bash
# Track Modified Files — PostToolUse Hook
#
# Appends file paths touched by Edit/Write tools to a session-scoped tracking file.
# Used by stop-hook.sh to scope Codex review to only files THIS agent changed.
#
# Receives JSON on stdin with tool_name and tool_input.file_path.

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)

# Only track Edit and Write tools
case "$TOOL_NAME" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

# Skip if no file path
[ -z "$FILE_PATH" ] && exit 0

# Append to session-scoped tracking file
TRACK_DIR=".claude"
mkdir -p "$TRACK_DIR"
TRACK_FILE="${TRACK_DIR}/modified-files-${SESSION_ID}.txt"

# Append only if not already tracked (dedup)
if ! grep -qxF "$FILE_PATH" "$TRACK_FILE" 2>/dev/null; then
  echo "$FILE_PATH" >> "$TRACK_FILE"
fi
