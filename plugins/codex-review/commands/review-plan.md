---
description: "Pre-implementation risk assessment: 4 parallel Codex agents analyze your plan against the codebase (read-only)"
argument-hint: "<path-to-plan.md>"
allowed-tools:
  - Bash
  - Read
---

Run the following script to launch parallel Codex risk assessment agents. Each agent reads the plan and analyzes the existing
codebase in read-only mode, focusing on a different risk category.

```bash
set -e

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT"

# ── Resolve plan file(s) ──────────────────────────────────────────────
# Accepts one or more file paths. Strips @ prefix (Claude Code file references).
# Multiple files are concatenated with separators.
PLAN_FILES=()
for arg in "$@"; do
  # Strip leading @ (Claude Code @file reference syntax)
  arg="${arg#@}"
  # Resolve relative to repo root
  if [ ! -f "$arg" ] && [ -f "${REPO_ROOT}/${arg}" ]; then
    arg="${REPO_ROOT}/${arg}"
  fi
  if [ -f "$arg" ]; then
    PLAN_FILES+=("$arg")
  else
    echo "WARNING: Plan file not found, skipping: $arg"
  fi
done

if [ ${#PLAN_FILES[@]} -eq 0 ]; then
  echo "ERROR: No plan files found."
  echo "Usage: /review-plan path/to/plan.md [path/to/plan2.md ...]"
  exit 1
fi

# Concatenate all plan files
PLAN_CONTENT=""
for pf in "${PLAN_FILES[@]}"; do
  if [ -n "$PLAN_CONTENT" ]; then
    PLAN_CONTENT="${PLAN_CONTENT}

---
"
  fi
  PLAN_CONTENT="${PLAN_CONTENT}$(cat "$pf")"
done

PLAN_LINES=$(echo "$PLAN_CONTENT" | wc -l | tr -d ' ')

if [ "$PLAN_LINES" -lt 3 ]; then
  echo "ERROR: Plan file(s) too short ($PLAN_LINES lines). Provide a real plan."
  exit 1
fi

PLAN_LABEL=$(printf '%s ' "${PLAN_FILES[@]}" | sed "s|${REPO_ROOT}/||g")
echo "=== Pre-Implementation Risk Assessment ==="
echo "Plan: ${PLAN_LABEL}(${#PLAN_FILES[@]} file(s), $PLAN_LINES lines)"

# ── Prerequisites ───────────────────────────────────────────────────
command -v codex >/dev/null 2>&1 || { echo "ERROR: codex not installed (npm install -g @openai/codex)"; exit 1; }

# ── Load project conventions ────────────────────────────────────────
CONVENTIONS=""
if [ -f "AGENTS.md" ]; then
  CONVENTIONS=$(cat AGENTS.md 2>/dev/null || true)
elif [ -f "CLAUDE.md" ]; then
  CONVENTIONS=$(cat CLAUDE.md 2>/dev/null || true)
fi

CONVENTIONS_BLOCK=""
if [ -n "$CONVENTIONS" ]; then
  CONVENTIONS_BLOCK="PROJECT CONVENTIONS (from AGENTS.md):
---
${CONVENTIONS}
---"
fi

# ── Optional: dependency map ────────────────────────────────────────
DEP_MAP=""
if [ "${REVIEW_LOOP_SKIP_MAP:-false}" != "true" ] && command -v codebase-map >/dev/null 2>&1; then
  MAP_FORMAT="${REVIEW_LOOP_MAP_FORMAT:-graph}"
  DEP_MAP=$(codebase-map --format "$MAP_FORMAT" 2>/dev/null || true)
  if [ -n "$DEP_MAP" ]; then
    DEP_MAP="CODEBASE DEPENDENCY MAP:
---
${DEP_MAP}
---"
  fi
fi

# ── Common preamble ─────────────────────────────────────────────────
PREAMBLE="You are performing a PRE-IMPLEMENTATION risk assessment. The team is about to implement the plan below.
Your job: analyze the EXISTING codebase to find risks, conflicts, and gaps BEFORE any code is written.

PLAN TO ASSESS:
---
${PLAN_CONTENT}
---

${CONVENTIONS_BLOCK}

${DEP_MAP}

IMPORTANT: This is read-only analysis. Do NOT modify any files. Use \`cat\`, \`find\`, \`grep\`, \`ls\` to explore the codebase.
Read relevant source files to understand current implementation before flagging risks."

# ── Per-agent prompts ───────────────────────────────────────────────

DEPS_PROMPT="${PREAMBLE}

FOCUS: DEPENDENCY & CONFLICT ANALYSIS

Analyze the existing codebase for conflicts with the proposed plan:

- API contracts: Will the plan break existing callers? Incompatible signature changes? Missing migrations?
- Data models: Schema conflicts? Backward-incompatible changes? Missing data backfills?
- Shared state: Race conditions with existing concurrent code? Shared resources (caches, queues, locks)?
- Import/dependency graph: Circular dependencies? Version conflicts? Missing packages?
- Configuration: Env vars, feature flags, config files that need updating?

For each risk: [HIGH/MED/LOW] description — file:line (existing code at risk)
HIGH=will break existing functionality, MED=likely issue, LOW=worth checking"

ARCH_PROMPT="${PREAMBLE}

FOCUS: ARCHITECTURE, SIMPLIFICATION & REUSE

Assess whether the plan fits the existing architecture — and challenge its complexity:

- Pattern consistency: Does the plan follow existing patterns (routing, state management, error handling, logging)?
- Module boundaries: Does the plan respect existing module/service boundaries? Cross-cutting concerns?
- Existing code reuse: Does the codebase already have utilities, helpers, services, or patterns that the plan reinvents? Point to exact files.
- Over-engineering: Which parts are more complex than needed? New abstractions where a simple function call works? Can you drop a dependency, skip a migration, use an existing queue/cache/table?
- Refactor-first: Would a small refactor of existing code make the planned feature trivial? Existing code that's 80% of what's needed?
- Simpler alternatives: Is there a fundamentally simpler way to achieve the same outcome? Different data model, different API shape, different flow?

For EACH simplification, be specific: point to the existing code (file:line), explain what it already does, and show how the plan could leverage it.

For each risk: [HIGH/MED/LOW] description — file:line (relevant existing code)
HIGH=plan reinvents existing code or architectural mismatch, MED=significant simplification possible, LOW=minor concern"

SECURITY_PROMPT="${PREAMBLE}

FOCUS: SECURITY IMPLICATIONS

Assess security risks of implementing this plan in the existing codebase:

- Auth & access: Does the plan introduce new endpoints/routes without auth? Privilege escalation paths?
- Input validation: New user inputs without sanitization? Injection vectors (SQL, XSS, command, path traversal)?
- Data exposure: Will the plan expose sensitive data? Logging PII? Error messages leaking internals?
- Secrets management: New API keys/tokens needed? Stored securely? Rotatable?
- Attack surface: New external integrations? Webhook receivers? File uploads? Rate limiting needed?
- Existing vulnerabilities: Does the plan build on code that already has security issues?

For each risk: [HIGH/MED/LOW] description — file:line (existing code or planned touchpoint)
HIGH=exploitable vulnerability, MED=defense-in-depth gap, LOW=hardening opportunity"

TESTING_PROMPT="${PREAMBLE}

FOCUS: TESTING, CORNER CASES & FAILURE MODES

Shift testing left. Challenge the plan — what will break, what's missing, what's untested:

Testing gaps:
- Existing test coverage: What tests exist for code the plan will modify? Are they adequate?
- Test infrastructure: Does the project have test setup for what the plan needs (DB fixtures, API mocks, E2E)?
- Regression risks: Which existing tests might break? What new tests are essential (not nice-to-have)?

Corner cases & failure modes:
- Edge cases: Empty inputs, zero items, null values, concurrent requests, unicode, timezone boundaries?
- Failure modes: What happens when external services are down? Database full? Network timeout? Partial writes?
- Race conditions: Multiple users hitting the same endpoint? Concurrent updates? Stale cache reads?
- Data integrity: Malformed, duplicated, or missing data? Orphaned records after partial failures?
- Rollback: If step 3 of 5 fails, what state is the system in? Can you recover?
- Scale surprises: Works for 10 users but breaks at 10K? O(n²) hidden in a loop? Unbounded queries?
- Migration risks: What happens to existing data/users during deployment? Backward compatibility?

For each finding: [HIGH/MED/LOW] description — file:line (existing code where the issue would manifest)
HIGH=will fail in production or critical untested path, MED=likely edge case, LOW=defensive consideration"

# ── Launch parallel agents ──────────────────────────────────────────
OUTDIR="/tmp/codex-plan-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR"
# --full-auto: sandboxed automatic execution (agents can read codebase freely)
CODEX_FLAGS="${REVIEW_LOOP_PLAN_FLAGS:---full-auto}"
START_TIME=$(date +%s)

echo ""
echo "Output → $OUTDIR/"
echo "Launching 4 parallel risk assessment agents (read-only)..."
echo "---"

# shellcheck disable=SC2086
codex exec review "$DEPS_PROMPT" $CODEX_FLAGS >/dev/null 2>"${OUTDIR}/1-dependencies.raw" &
PID1=$!
# shellcheck disable=SC2086
codex exec review "$ARCH_PROMPT" $CODEX_FLAGS >/dev/null 2>"${OUTDIR}/2-architecture.raw" &
PID2=$!
# shellcheck disable=SC2086
codex exec review "$SECURITY_PROMPT" $CODEX_FLAGS >/dev/null 2>"${OUTDIR}/3-security.raw" &
PID3=$!
# shellcheck disable=SC2086
codex exec review "$TESTING_PROMPT" $CODEX_FLAGS >/dev/null 2>"${OUTDIR}/4-testing.raw" &
PID4=$!

FAILURES=0
wait $PID1 || FAILURES=$((FAILURES + 1))
wait $PID2 || FAILURES=$((FAILURES + 1))
wait $PID3 || FAILURES=$((FAILURES + 1))
wait $PID4 || FAILURES=$((FAILURES + 1))

ELAPSED=$(( $(date +%s) - START_TIME ))

# ── Clean and merge output ──────────────────────────────────────────
REPORT_FILE="${OUTDIR}/risk-report.md"
{
  echo "# Pre-Implementation Risk Assessment — 4 Agents"
  echo ""
  echo "Plan: ${PLAN_LABEL}| Agents: 4 | Duration: ${ELAPSED}s"
  echo ""
} > "$REPORT_FILE"

for f in "${OUTDIR}"/*.raw; do
  [ -f "$f" ] || continue
  AGENT_NAME=$(basename "$f" .raw | sed 's/^[0-9]-//')

  # Strip codex noise
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' '/^mcp:/d; /^Warning:/d; /^thinking$/d; /^exec$/d; /^user$/d; /^OpenAI Codex/d; /^--------$/d; /^workdir:/d; /^model:/d; /^provider:/d; /^approval:/d; /^sandbox:/d; /^reasoning/d; /^session id:/d' "$f" 2>/dev/null || true
  else
    sed -i '/^mcp:/d; /^Warning:/d; /^thinking$/d; /^exec$/d; /^user$/d; /^OpenAI Codex/d; /^--------$/d; /^workdir:/d; /^model:/d; /^provider:/d; /^approval:/d; /^sandbox:/d; /^reasoning/d; /^session id:/d' "$f" 2>/dev/null || true
  fi

  # Extract after last "codex" marker
  if grep -q "^codex$" "$f" 2>/dev/null; then
    LINE=$(grep -n "^codex$" "$f" | tail -1 | cut -d: -f1)
    if [ -n "$LINE" ]; then
      tail -n +"$((LINE + 1))" "$f" > "${f}.clean"
      mv "${f}.clean" "$f"
    fi
  fi

  {
    echo "---"
    AGENT_TITLE="$(echo "$AGENT_NAME" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
    echo "## ${AGENT_TITLE} Assessment"
    echo ""
    if [ -s "$f" ]; then
      cat "$f"
    else
      echo "_No risks identified._"
    fi
    echo ""
  } >> "$REPORT_FILE"
done

echo "---"
echo "4 agents finished (elapsed=${ELAPSED}s, failures=${FAILURES})"
echo "Risk report: $REPORT_FILE ($(wc -c < "$REPORT_FILE" | tr -d ' ') bytes)"
echo "Individual: ${OUTDIR}/*.raw"
```

**Smart agent selection**: Before running the script, assess the plan and skip agents that clearly don't apply. For example:
- A docs-only plan doesn't need security or testing agents
- A UI sorting refactor doesn't need security analysis
- A pure config change doesn't need architecture review

To skip agents, comment out the corresponding `codex exec review` line and its `PID`/`wait` in the script before running.

After the script completes, read the risk report file and present findings to the user. Organize by severity (HIGH first),
deduplicate across agents, and group by theme. For each risk, explain:
1. What the risk is
2. Where in the existing codebase it applies (file:line)
3. How to mitigate it (adjust the plan, add a step, etc.)

End with a summary: total risks by severity, top 3 recommendations for plan improvements.

**IMPORTANT**: This is a PRE-IMPLEMENTATION analysis — purely informational. Present findings to the user and wait for their
decision on how to proceed. Do NOT:
- Start implementing fixes or code changes based on the risk report
- Treat findings as review-loop feedback to address
- Confuse this with a post-implementation code review

The user decides what to do with the risks: update the plan, proceed as-is, or adjust scope. This command produces a report,
not an action list.
