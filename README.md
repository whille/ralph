# Ralph

Autonomous AI agent loop for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Each iteration is a fresh instance. Memory persists via git history, `progress.txt`, and `prd.json`.

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- `jq` installed (`brew install jq` on macOS)
- A git repository for your project

## Testing

Run the test suite to verify scripts work correctly:

```bash
./tests/run_tests.sh
```

Tests cover:
- Symlink resolution
- Configuration management
- PRD status parsing
- Worktree management
- Daemon script functionality
- Edge cases and error handling
- Git integration

All 28 tests should pass.

## Setup

### Copy to your project

```bash
mkdir -p scripts/ralph
cp ralph.sh scripts/ralph/
cp CLAUDE.md scripts/ralph/
chmod +x scripts/ralph/ralph.sh
```

### Install skills globally

```bash
cp -r skills/* ~/.claude/skills/
```

## Workflow

### 1. Create a PRD

Use the PRD skill to generate a detailed requirements document:

```
Load the prd skill and create a PRD for [your feature description]
```

Answer the clarifying questions. The skill saves output to `tasks/prd-[feature-name].md`.

### 2. Convert PRD to Ralph format

Use the Ralph skill to convert the markdown PRD to JSON:

```
Load the ralph skill and convert tasks/prd-[feature-name].md to prd.json
```

This creates `prd.json` with user stories structured for autonomous execution.

### 3. Run Ralph

```bash
# Single project loop
./scripts/ralph/ralph.sh [max_iterations]
```

Default is 10 iterations. Ralph will:
1. Create a feature branch (from PRD `branchName`)
2. Pick the highest priority story where `passes: false`
3. Implement that single story
4. Run quality checks (typecheck, tests)
5. Commit if checks pass
6. Update `prd.json` to mark story as `passes: true`
7. Append learnings to `progress.txt`
8. Repeat until all stories pass or max iterations reached

### Daemon Mode (Multi-Project + Parallel)

Run Ralph as a background daemon monitoring multiple projects:

```bash
# Start daemon
ralph-daemon.sh start

# Add project to watch
ralph-daemon.sh add ~/projects/myproject

# Check status
ralph-daemon.sh status

# View logs
ralph-daemon.sh logs              # All projects
ralph-daemon.sh logs ~/projects/myproject  # Filter by project

# Graceful stop (waits for workers)
ralph-daemon.sh stop

# Force stop (kills all workers)
ralph-daemon.sh stop --force
```

**Logs:**
- Main: `~/.ralph-daemon/daemon.log` (with `[project]` prefix)
- Worker: `<project>/.claude/worktrees/<task>/worker.log`

**Features:**
- Monitors multiple `prd.json` across projects
- Parallel execution using git worktrees (no lock conflicts)
- Respects task dependencies (`depends` field)
- Auto-merge on completion
- Graceful shutdown (waits for workers to complete)

**Config:** `~/.ralph-daemon/config.json`

```json
{
  "watchDirs": ["~/projects/myproject"],
  "workerCount": 3,
  "pollInterval": 30,
  "workerTimeout": 3600
}
```

**Task dependencies in prd.json:**

```json
{
  "userStories": [
    { "id": "US-001", "depends": [], "passes": false },
    { "id": "US-002", "depends": ["US-001"], "passes": false }
  ]
}
```

## Key Files

| File | Purpose |
|------|---------|
| `ralph.sh` | Single-project loop |
| `ralph-daemon.sh` | Multi-project daemon with parallel execution |
| `CLAUDE.md` | Agent instructions |
| `prd.json` | User stories with `passes` status |
| `prd.json.example` | Example PRD format |
| `progress.txt` | Append-only learnings |
| `skills/` | PRD generation and conversion skills |

## Critical Concepts

### Each Iteration = Fresh Context

Each iteration spawns a **new Claude instance** with clean context. Memory persists via:
- Git history (commits from previous iterations)
- `progress.txt` (learnings)
- `prd.json` (task status)

### Small Tasks

Each PRD item should be small enough to complete in one context window.

Right-sized: add a column, add a component, update an action
Too big: "build dashboard", "add auth", "refactor API"

### Feedback Loops

Ralph needs feedback loops: typecheck, tests, CI. Broken code compounds across iterations.

## Debugging

```bash
# Task status
jq '.userStories[] | {id, title, passes}' prd.json

# Learnings
cat progress.txt

# Git history
git log --oneline -10
```

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
