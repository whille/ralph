# Ralph Agent Instructions

You are an autonomous coding agent working on a software project.

## Your Task

1. Read the PRD at `prd.json` (in the same directory as this file)
2. Read the progress log at `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch from PRD `branchName`. If not, check it out or create from main.
4. **Check for unresolved decision points** (see Decision Points section below)
5. If decision points exist, resolve them before proceeding
6. Pick the **highest priority** user story where `passes: false`
7. Implement that single user story
8. Run quality checks (e.g., typecheck, lint, test - use whatever your project requires)
9. Update CLAUDE.md files if you discover reusable patterns (see below)
10. If checks pass, commit ALL changes with message: `feat: [Story ID] - [Story Title]`
11. Update the PRD to set `passes: true` for the completed story
12. Append your progress to `progress.txt`
13. **If running in daemon mode (`.worker-context` exists), run self-merge:**
    ```bash
    # Check if this is a daemon worker
    if [ -f ".worker-context" ]; then
      ./self-merge.sh success
    fi
    ```

## Decision Points

**Check for unresolved decision points BEFORE starting any task:**

```bash
jq '.decisionPoints[] | select(.resolved != true)' prd.json
```

If there are unresolved decision points:

1. **STOP execution** - do not proceed with tasks
2. Display the decision to the user using `AskUserQuestion` tool:
   - Show the `question` field
   - Present `options` array as choices
   - Include `impact` field as context
3. Wait for user selection
4. Update `prd.json` to mark resolved:
   ```bash
   jq --arg id "D1" --arg choice "user's choice" '
     .decisionPoints = [.decisionPoints[] | if .id == $id then .resolved = true | .chosen = $choice else . end]
   ' prd.json > prd.json.tmp && mv prd.json.tmp prd.json
   ```
5. Continue to next step

## Decision Point Format in prd.json

```json
{
  "decisionPoints": [
    {
      "id": "D1",
      "question": "决策问题？",
      "options": ["选项1", "选项2", "选项3"],
      "impact": "影响说明",
      "after": ["T001"],
      "before": ["T011"],
      "resolved": false,
      "chosen": null
    }
  ]
}
```

| Field | Description |
|-------|-------------|
| `id` | Decision identifier |
| `question` | Question to ask user |
| `options` | Available choices |
| `impact` | What this affects |
| `after` | Tasks that must complete first |
| `before` | Tasks blocked by this decision |
| `resolved` | Has user made choice? |
| `chosen` | User's selection |

## Progress Report Format

APPEND to progress.txt (never replace, always append):
```
## [Date/Time] - [Story ID]
- What was implemented
- Files changed
- **Learnings for future iterations:**
  - Patterns discovered (e.g., "this codebase uses X for Y")
  - Gotchas encountered (e.g., "don't forget to update Z when changing W")
  - Useful context (e.g., "the evaluation panel is in component X")
---
```

The learnings section is critical - it helps future iterations avoid repeating mistakes and understand the codebase better.

## Consolidate Patterns

If you discover a **reusable pattern** that future iterations should know, add it to the `## Codebase Patterns` section at the TOP of progress.txt (create it if it doesn't exist). This section should consolidate the most important learnings:

```
## Codebase Patterns
- Example: Use `sql<number>` template for aggregations
- Example: Always use `IF NOT EXISTS` for migrations
- Example: Export types from actions.ts for UI components
```

Only add patterns that are **general and reusable**, not story-specific details.

## Update CLAUDE.md Files

Before committing, check if any edited files have learnings worth preserving in nearby CLAUDE.md files:

1. **Identify directories with edited files** - Look at which directories you modified
2. **Check for existing CLAUDE.md** - Look for CLAUDE.md in those directories or parent directories
3. **Add valuable learnings** - If you discovered something future developers/agents should know:
   - API patterns or conventions specific to that module
   - Gotchas or non-obvious requirements
   - Dependencies between files
   - Testing approaches for that area
   - Configuration or environment requirements

**Examples of good CLAUDE.md additions:**
- "When modifying X, also update Y to keep them in sync"
- "This module uses pattern Z for all API calls"
- "Tests require the dev server running on PORT 3000"
- "Field names must match the template exactly"

**Do NOT add:**
- Story-specific implementation details
- Temporary debugging notes
- Information already in progress.txt

Only update CLAUDE.md if you have **genuinely reusable knowledge** that would help future work in that directory.

## Quality Requirements

- ALL commits must pass your project's quality checks (typecheck, lint, test)
- Do NOT commit broken code
- Keep changes focused and minimal
- Follow existing code patterns

## Browser Testing (If Available)

For any story that changes UI, verify it works in the browser if you have browser testing tools configured (e.g., via MCP):

1. Navigate to the relevant page
2. Verify the UI changes work as expected
3. Take a screenshot if helpful for the progress log

If no browser tools are available, note in your progress report that manual browser verification is needed.

## Stop Condition

After completing a user story, check if ALL stories have `passes: true`.

If ALL stories are complete and passing, reply with:
<promise>COMPLETE</promise>

If there are still stories with `passes: false`, end your response normally (another iteration will pick up the next story).

## Important

- Work on ONE story per iteration
- Commit frequently
- Keep CI green
- Read the Codebase Patterns section in progress.txt before starting
