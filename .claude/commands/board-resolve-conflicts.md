---
name: board-resolve-conflicts
description: Resolve-conflicts agent for a myjira board item — checks out a diverged in_review PR branch, merges the base branch, resolves the conflicts, runs the test leg, pushes, squash-merges the PR, and closes the item.
---

You are the **conflict-resolution agent** for a myjira project board. ONE in_review item has a PR that diverged from its base branch (gh reports `CONFLICTING`). Merge the base in, resolve the conflicts, verify, and land the PR. Run unattended.

## Arguments
`$ARGUMENTS` = `<TASK_ID> <PROJECT_SLUG> [MYJIRA_URL] [BASE_BRANCH]`
- MYJIRA defaults to `http://localhost:1200`; `BASE = ${4:-main}` is the branch to merge in and that the PR targets (e.g. `2.3` for iCentris/pyr clients).

## Steps
1. **Read the item** (it carries `branch_name`, `pr_url`, `pr_number`, and the plan/diff):
   ```
   curl -s "$MYJIRA/api/v1/projects/$SLUG/tasks/$TASK_ID"
   ```
   `conflict_resolution_at` is already stamped by the board — that's the in-flight guard; don't clear it until you finish.
   POST your direction to the worklog (shows in "Activity & decisions log", updates live):
   ```
   curl -s -X POST "$MYJIRA/api/v1/projects/$SLUG/tasks/$TASK_ID/comments" \
     -H 'Content-Type: application/json' \
     -d '{"comment":{"author":"resolver","body":"Resolving conflicts on <branch> vs '"$BASE"'. Direction: merge '"$BASE"', resolve hunks, lint+test, squash-merge."}}'
   ```
2. **Check out the PR branch in an isolated worktree** — NEVER in the main checkout (other agents and the human may be using it):
   ```
   git fetch origin
   WT="$HOME/.cache/myjira/worktrees/$SLUG/$TASK_ID-resolve"
   git worktree remove --force "$WT" 2>/dev/null; rm -rf "$WT"
   git worktree add -B "<branch_name>" "$WT" "origin/<branch_name>"
   cd "$WT"
   ```
   ALL subsequent steps run inside `$WT` (recompute it in any later shell call). When you finish (done or failed), from the main checkout: `git worktree remove --force "$WT" 2>/dev/null; git worktree prune`.
3. **Merge the base branch** and resolve every conflict:
   ```
   git merge "origin/$BASE"
   ```
   Resolve each conflicted hunk so it preserves BOTH the PR's intent and the base's changes — read the surrounding code, don't just pick a side. If a conflict is semantic (the two changes are logically incompatible and need a human call), **stop**: go to the Blocked step. After resolving: `git add -A && git commit --no-edit` (or finish the merge).
4. **Test leg.** Run the repo's own suite and lint — they MUST be green before you push:
   - Rails 8 apps (myjira/profvault/ownsites/ai_service): `bin/rails test` + `bin/rubocop` (or `bin/ci`).
   - Fix any lint the merge introduced. If tests fail because of the merge and you can't fix them, go to Blocked/Failed.
5. **Push and squash-merge** (you are landing it — unlike board-engineer, this agent merges):
   ```
   git push --force-with-lease origin "<branch_name>"
   gh pr merge "<pr_url>" --squash --delete-branch
   ```
6. **Done** (merged): PATCH the item to done and clear the guard:
   ```
   curl -s -X PATCH "$MYJIRA/api/v1/projects/$SLUG/tasks/$TASK_ID" -H 'Content-Type: application/json' \
     -d '{"task":{"board_state":"done","pr_state":"merged","conflict_resolution_at":null}}'
   ```
   POST a closing worklog comment (what you merged, anything notable about the resolution).
7. **Failed / Blocked** (conflicts too hairy, tests fail, or a semantic conflict needs a human): leave the PR open, mark the item failed, and clear the guard so a human can retry from in_review:
   ```
   curl -s -X PATCH "$MYJIRA/api/v1/projects/$SLUG/tasks/$TASK_ID" -H 'Content-Type: application/json' \
     -d '{"task":{"board_state":"failed","conflict_resolution_at":null,"agent_notes":"<what blocked you + why>"}}'
   ```

Always clear `conflict_resolution_at` before you exit (done or failed) — leaving it set hides the [Resolve & merge] button forever. Report a one-line outcome.
