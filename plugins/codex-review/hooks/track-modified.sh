#!/usr/bin/env bash
# Track Modified Files — PostToolUse Hook
#
# Appends file paths touched by Edit/Write tools to a session-scoped tracking file.
# Used by stop-hook.sh to scope Codex review to only files THIS agent changed.
#
# On first fire for a session, claims a pending review-loop state file by writing
# session_id into it. This links the session to the review for parallel agent safety.
#
# Receives JSON on stdin with tool_name and tool_input.file_path.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LOG_FILE="${REPO_ROOT}/.claude/review-loop.log"
log() { mkdir -p "$(dirname "$LOG_FILE")"; echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [track] $*" >> "$LOG_FILE"; }

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
TRACK_DIR="${REPO_ROOT}/.claude"
mkdir -p "$TRACK_DIR"
TRACK_FILE="${TRACK_DIR}/modified-files-${SESSION_ID}.txt"

# ── Claim pending state file on first fire ────────────────────────────
# State files without session_id are "pending" — created by /review-loop command.
# First PostToolUse hook for a session claims it by writing session_id into the file.
if [ -n "$SESSION_ID" ] && ! [ -f "$TRACK_FILE" ]; then
  CLAIMED=""
  for sf in "${REPO_ROOT}"/.claude/review-loop-*.local.md; do
    [ -f "$sf" ] || continue
    # Unclaimed = has no session_id line
    if ! grep -q "^session_id:" "$sf" 2>/dev/null; then
      if [ "$(uname)" = "Darwin" ]; then
        sed -i '' "/^started_at:/a\\
session_id: ${SESSION_ID}" "$sf"
      else
        sed -i "/^started_at:/a session_id: ${SESSION_ID}" "$sf"
      fi
      CLAIMED="$sf"
      log "Claimed state file $sf for session $SESSION_ID"
      break
    fi
  done
  [ -z "$CLAIMED" ] && log "WARN: no unclaimed state file found for session $SESSION_ID"
fi

# Append only if not already tracked (dedup)
if ! grep -qxF "$FILE_PATH" "$TRACK_FILE" 2>/dev/null; then
  echo "$FILE_PATH" >> "$TRACK_FILE"
fi
