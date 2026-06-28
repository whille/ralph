#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--tool amp|claude] [max_iterations]

set -e

# Parse arguments
TOOL="claude"  # Default to Claude
MAX_ITERATIONS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    *)
      # Assume it's max_iterations if it's a number
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

# Validate tool choice
if [[ "$TOOL" != "amp" && "$TOOL" != "claude" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'amp' or 'claude'."
  exit 1
fi

# Resolve symlink to get actual script directory
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_SOURCE" ]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  case "$SCRIPT_SOURCE" in
    /*) ;;  # Absolute path
    *) SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE" ;;  # Relative path
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"

PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    # Archive the previous run
    DATE=$(date +%Y-%m-%d)
    # Strip "ralph/" prefix from branch name for folder
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"

    # Reset progress file for new run
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"

# Auto-export the current ccc.json provider env so ANTHROPIC_AUTH_TOKEN /
# BASE_URL / MODEL are set. Lets `ralph.sh` and `ccc` share provider config
# without manual export. Skipped if ccc.json or jq is unavailable.
if [[ "$TOOL" == "claude" ]] && [[ -f "$HOME/.claude/ccc.json" ]] && command -v jq >/dev/null 2>&1; then
  CCC_CURRENT=$(jq -r '.current_provider // empty' "$HOME/.claude/ccc.json" 2>/dev/null)
  if [[ -n "$CCC_CURRENT" ]]; then
    while IFS=$'\t' read -r key value; do
      export "$key=$value"
    done < <(jq -r ".providers[\"$CCC_CURRENT\"].env // {} | to_entries | .[] | \"\(.key)\t\(.value)\"" "$HOME/.claude/ccc.json" 2>/dev/null)
    echo "Injected ccc provider env: $CCC_CURRENT ($ANTHROPIC_BASE_URL)"
  fi
fi

for i in $(seq 1 $MAX_ITERATIONS); do
  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
  echo "==============================================================="

  # Run the selected tool with the ralph prompt.
  # Stream stdout/stderr live to terminal via `tail -f` (line-buffered on tty),
  # then read full output from log file for <promise>COMPLETE</promise> detection.
  # `tee /dev/stderr` was block-buffered and hid progress for the full run.
  ITER_LOG="$SCRIPT_DIR/.ralph_iter_${i}.log"
  if [[ "$TOOL" == "amp" ]]; then
    ( cat "$SCRIPT_DIR/prompt.md" | amp --dangerously-allow-all ) > "$ITER_LOG" 2>&1 &
    TOOL_PID=$!
  else
    # Direct claude CLI (provider env injected above from ccc.json)
    claude --dangerously-skip-permissions --print < "$SCRIPT_DIR/claude.md" > "$ITER_LOG" 2>&1 &
    TOOL_PID=$!
  fi

  # Live-stream the log to terminal so user sees progress; kill tail when tool exits
  tail -n +1 -f "$ITER_LOG" >/dev/stderr &
  TAIL_PID=$!
  wait "$TOOL_PID"
  TOOL_EXIT=$?
  kill "$TAIL_PID" 2>/dev/null
  wait "$TAIL_PID" 2>/dev/null

  OUTPUT=$(cat "$ITER_LOG")

  # Check for completion signal
  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi

  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
