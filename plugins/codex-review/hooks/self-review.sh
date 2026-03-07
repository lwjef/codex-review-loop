#!/usr/bin/env bash
# Self-Review — Stop Hook
#
# Lightweight, always-on quality gate. Forces Claude to self-review changes
# before stopping. Fires on EVERY session stop, independent of /review-loop
#
# Ported from ClaudeKit's self-review.ts (shell, no deps).
#
# Features:
#   - Only triggers if file changes occurred (via tracking file or transcript)
#   - Marker-based dedup: won't re-review already-reviewed changes
#   - Randomized questions from 4 focus areas to avoid pattern fatigue
#   - Skips if stop_hook_active=true (review loop already handles review)
#
# Environment variables:
#   REVIEW_LOOP_SKIP_SELF_REVIEW  Set to "true" to disable self-review

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

HOOK_INPUT=$(cat)

# ── Skip conditions ──────────────────────────────────────────────────

# Disabled by env
if [ "${REVIEW_LOOP_SKIP_SELF_REVIEW:-false}" = "true" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Already inside a stop hook loop (codex review is handling it)
STOP_HOOK_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Active codex-review session exists → let stop-hook.sh handle it
for sf in "${REPO_ROOT}"/.claude/codex-review-*.local.md; do
  [ -f "$sf" ] || continue
  if grep -q "^active: true" "$sf" 2>/dev/null; then
    printf '{"decision":"approve"}\n'
    exit 0
  fi
done

# ── Cleanup helper ────────────────────────────────────────────────────
# Remove current session's tracking file on exit (prevents accumulation).
# The stop-hook cleanup only runs during review-loop; self-review handles all other sessions.
cleanup_tracking_file() {
  local sid="$1"
  if [ -n "$sid" ]; then
    rm -f "${REPO_ROOT}/.claude/modified-files-${sid}.txt"
  fi
  # Also clean stale files from other sessions (>1 hour)
  find "${REPO_ROOT}/.claude" -name "modified-files-*.txt" -mmin +60 -delete 2>/dev/null || true
}

# ── Check for file changes SINCE last self-review ────────────────────
# Key insight: we only care about edits that happened AFTER the last
# "Self-Review Complete" marker. Without this, the hook re-fires on
# every stop even after the review is done (old edits still in transcript).

SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
TRANSCRIPT=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
HAS_CHANGES=false

# Find the line number of the last "Self-Review Complete" marker in the transcript.
# Everything before this line was already reviewed — only edits after it matter.
MARKER_LINE=0
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  # The marker appears in assistant messages as part of the tool_use_result reason field
  # or in the assistant's own text output. Search for it in the raw JSONL.
  MARKER_LINE=$(grep -nF "Self-Review Complete" "$TRANSCRIPT" 2>/dev/null | tail -1 | cut -d: -f1)
  MARKER_LINE="${MARKER_LINE:-0}"
fi

if [ "$MARKER_LINE" -gt 0 ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  # Scan only lines AFTER the marker for editing tool uses
  if tail -n +"$((MARKER_LINE + 1))" "$TRANSCRIPT" | \
     jq -e 'select(.tool_name == "Edit" or .tool_name == "Write" or .tool_name == "MultiEdit" or .tool_name == "NotebookEdit")' >/dev/null 2>&1; then
    HAS_CHANGES=true
  fi
else
  # No marker found — first review this session. Check full transcript.

  # Method 1: PostToolUse tracking file
  if [ -n "$SESSION_ID" ]; then
    TRACK_FILE="${REPO_ROOT}/.claude/modified-files-${SESSION_ID}.txt"
    if [ -f "$TRACK_FILE" ] && [ -s "$TRACK_FILE" ]; then
      HAS_CHANGES=true
    fi
  fi

  # Method 2: Full transcript scan (fallback)
  if [ "$HAS_CHANGES" = "false" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    if jq -e 'select(.tool_name == "Edit" or .tool_name == "Write" or .tool_name == "MultiEdit" or .tool_name == "NotebookEdit")' "$TRANSCRIPT" >/dev/null 2>&1; then
      HAS_CHANGES=true
    fi
  fi
fi

# No changes since last review → skip
if [ "$HAS_CHANGES" = "false" ]; then
  cleanup_tracking_file "$SESSION_ID"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# ── Skip non-code changes ────────────────────────────────────────────
# Don't ask about mocks/tests/refactoring when only docs/config were edited.
# Extract file paths from Edit/Write tool uses and check extensions.
HAS_CODE_CHANGES=false
NON_CODE_PATTERN='\.(md|txt|log)$'

# Check tracking file first (fast path)
if [ -n "$SESSION_ID" ]; then
  TRACK_FILE="${REPO_ROOT}/.claude/modified-files-${SESSION_ID}.txt"
  if [ -f "$TRACK_FILE" ] && [ -s "$TRACK_FILE" ]; then
    if grep -qvE "$NON_CODE_PATTERN" "$TRACK_FILE" 2>/dev/null; then
      HAS_CODE_CHANGES=true
    fi
  fi
fi

# Fallback: extract file_path from transcript tool uses
if [ "$HAS_CODE_CHANGES" = "false" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  EDITED_FILES=""
  if [ "$MARKER_LINE" -gt 0 ]; then
    EDITED_FILES=$(tail -n +"$((MARKER_LINE + 1))" "$TRANSCRIPT" | \
      jq -r 'select(.tool_name == "Edit" or .tool_name == "Write" or .tool_name == "MultiEdit" or .tool_name == "NotebookEdit") | .input.file_path // .input.path // empty' 2>/dev/null || true)
  else
    EDITED_FILES=$(jq -r 'select(.tool_name == "Edit" or .tool_name == "Write" or .tool_name == "MultiEdit" or .tool_name == "NotebookEdit") | .input.file_path // .input.path // empty' "$TRANSCRIPT" 2>/dev/null || true)
  fi
  if [ -n "$EDITED_FILES" ] && echo "$EDITED_FILES" | grep -qvE "$NON_CODE_PATTERN"; then
    HAS_CODE_CHANGES=true
  fi
fi

# Only docs/config changed → skip self-review
if [ "$HAS_CODE_CHANGES" = "false" ]; then
  cleanup_tracking_file "$SESSION_ID"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# ── Build self-review prompt with randomized questions ───────────────

# 4 focus areas, 6 questions each. Pick one random question per area.
# Randomization prevents pattern fatigue — agents stop reading repeated prompts.
pick_random() {
  local arr=("$@")
  local count=${#arr[@]}
  # Use $RANDOM (bash built-in) for lightweight randomization
  local idx=$(( RANDOM % count ))
  echo "${arr[$idx]}"
}

Q1_POOL=(
  "Did you create a mock implementation just to pass tests instead of real functionality?"
  "Are there any 'Not implemented yet' placeholders or TODO comments in production code?"
  "Does the implementation actually do what it claims, or just return hardcoded values?"
  "Did you stub out functionality with placeholder messages instead of real logic?"
  "Did you implement the full solution or just the minimum to make tests green?"
  "Did you finish what you started or leave work half-done?"
)

Q2_POOL=(
  "Did you leave the code better than you found it?"
  "Is there duplicated logic that should be extracted?"
  "Are you using different patterns than the existing code uses?"
  "Did you clean up after making your changes work?"
  "Can anything be simplified — fewer lines, fewer abstractions, fewer branches?"
  "Did you add defensive code, error handling, or abstractions that aren't actually needed?"
)

Q3_POOL=(
  "Did you just add code on top without integrating it properly?"
  "Should you extract the new functionality into cleaner abstractions?"
  "Would refactoring the surrounding code make everything simpler?"
  "Does the code structure still make sense after your additions?"
  "Should you consolidate similar functions that now exist?"
  "Did you leave any temporary workarounds or hacks?"
)

Q4_POOL=(
  "Should other parts of the codebase be updated to match your improvements?"
  "Did you update all the places that depend on what you changed?"
  "Are there related files that need the same changes?"
  "Did you create a utility that existing code could benefit from?"
  "Should your solution be applied elsewhere for consistency?"
  "Are you following the same patterns used elsewhere in the codebase?"
)

Q1=$(pick_random "${Q1_POOL[@]}")
Q2=$(pick_random "${Q2_POOL[@]}")
Q3=$(pick_random "${Q3_POOL[@]}")
Q4=$(pick_random "${Q4_POOL[@]}")

REASON="## Self-Review

You made code changes in this session. Before stopping, check:
- ${Q1}
- ${Q2}
- ${Q3}
- ${Q4}

Address any concerns, then end with **Self-Review Complete**."

jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
