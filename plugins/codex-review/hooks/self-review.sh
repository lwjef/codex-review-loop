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

# ── Check for file changes ───────────────────────────────────────────

SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
HAS_CHANGES=false

# Method 1: PostToolUse tracking file
if [ -n "$SESSION_ID" ]; then
  TRACK_FILE="${REPO_ROOT}/.claude/modified-files-${SESSION_ID}.txt"
  if [ -f "$TRACK_FILE" ] && [ -s "$TRACK_FILE" ]; then
    HAS_CHANGES=true
  fi
fi

# Method 2: Transcript parsing (fallback)
if [ "$HAS_CHANGES" = "false" ]; then
  TRANSCRIPT=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # Check if any Edit/Write tools were used
    if jq -e 'select(.tool_name == "Edit" or .tool_name == "Write")' "$TRANSCRIPT" >/dev/null 2>&1; then
      HAS_CHANGES=true
    fi
  fi
fi

# Method 3: Git uncommitted changes (ultimate fallback)
if [ "$HAS_CHANGES" = "false" ]; then
  DIFF_COUNT=$(git diff --name-only 2>/dev/null | grep -c . 2>/dev/null || echo 0)
  STAGED_COUNT=$(git diff --cached --name-only 2>/dev/null | grep -c . 2>/dev/null || echo 0)
  if [ "$DIFF_COUNT" -gt 0 ] || [ "$STAGED_COUNT" -gt 0 ]; then
    HAS_CHANGES=true
  fi
fi

# No changes → skip review
if [ "$HAS_CHANGES" = "false" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

# ── Marker-based dedup ───────────────────────────────────────────────
# Check if the last assistant message already contains our marker.
# If so, Claude already did a self-review this cycle — don't re-trigger.

# ── Cleanup helper ────────────────────────────────────────────────────
# Remove current session's tracking file on exit (prevents accumulation).
# The stop-hook cleanup only runs during review-loop; self-review handles all other sessions.
cleanup_tracking_file() {
  if [ -n "$SESSION_ID" ]; then
    rm -f "${REPO_ROOT}/.claude/modified-files-${SESSION_ID}.txt"
  fi
  # Also clean stale files from other sessions (>1 hour)
  find "${REPO_ROOT}/.claude" -name "modified-files-*.txt" -mmin +60 -delete 2>/dev/null || true
}

LAST_MSG=$(echo "$HOOK_INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null || echo "")
if echo "$LAST_MSG" | grep -qF "Self-Review Complete" 2>/dev/null; then
  cleanup_tracking_file
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
