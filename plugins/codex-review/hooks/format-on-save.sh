#!/usr/bin/env bash
# Format on Save — PostToolUse Hook
#
# Auto-formats files after Edit/Write using project's configured formatter.
# Detects: prettier, biome, eslint --fix, ruff format, gofmt, rustfmt.
# Runs silently — only outputs on error.
#
# Environment variables:
#   REVIEW_LOOP_SKIP_FORMAT  Set to "true" to disable auto-formatting

[ "${REVIEW_LOOP_SKIP_FORMAT:-false}" = "true" ] && exit 0

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0
[ -f "$FILE_PATH" ] || exit 0

# Skip non-formattable files
case "$FILE_PATH" in
  *.txt|*.log|*.csv|*.lock|*.snap) exit 0 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# ── Detect and run formatter ─────────────────────────────────────────

format_js_ts() {
  # Prettier > Biome > ESLint (check project config, not global installs)
  if [ -f "${REPO_ROOT}/node_modules/.bin/prettier" ]; then
    "${REPO_ROOT}/node_modules/.bin/prettier" --write "$FILE_PATH" 2>/dev/null
    return $?
  elif [ -f "${REPO_ROOT}/node_modules/.bin/biome" ]; then
    "${REPO_ROOT}/node_modules/.bin/biome" format --write "$FILE_PATH" 2>/dev/null
    return $?
  elif [ -f "${REPO_ROOT}/node_modules/.bin/eslint" ]; then
    "${REPO_ROOT}/node_modules/.bin/eslint" --fix "$FILE_PATH" 2>/dev/null
    return $?
  fi
  return 1
}

format_python() {
  if command -v ruff &>/dev/null; then
    ruff format "$FILE_PATH" 2>/dev/null
    return $?
  elif command -v black &>/dev/null; then
    black --quiet "$FILE_PATH" 2>/dev/null
    return $?
  fi
  return 1
}

case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs)
    format_js_ts || true
    ;;
  *.json)
    # Only format JSON if prettier is available (biome/eslint don't handle JSON well)
    if [ -f "${REPO_ROOT}/node_modules/.bin/prettier" ]; then
      "${REPO_ROOT}/node_modules/.bin/prettier" --write "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
  *.css|*.scss|*.less)
    format_js_ts || true
    ;;
  *.html|*.vue|*.svelte)
    format_js_ts || true
    ;;
  *.py)
    format_python || true
    ;;
  *.go)
    command -v gofmt &>/dev/null && gofmt -w "$FILE_PATH" 2>/dev/null || true
    ;;
  *.rs)
    command -v rustfmt &>/dev/null && rustfmt "$FILE_PATH" 2>/dev/null || true
    ;;
  *.yaml|*.yml|*.md|*.mdx)
    if [ -f "${REPO_ROOT}/node_modules/.bin/prettier" ]; then
      "${REPO_ROOT}/node_modules/.bin/prettier" --write "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
esac

exit 0
