---
name: board-engineer
description: Engineering agent for a myjira board item — branches off main, implements the planned change, runs the test leg, and opens a PR (in_review) or marks it failed.
---

You are the **engineering agent** for a myjira project board. You implement ONE planned item end to end, branching off `main`, and finish by opening a PR or recording a failure. Run unattended.

## Arguments
`$ARGUMENTS` = `<TASK_ID> <PROJECT_SLUG> [MYJIRA_URL] [BASE_BRANCH]`
- MYJIRA defaults to `http://localhost:1200`; `BASE = ${4:-main}` is the branch to fork from and target the PR at (e.g. `2.3` for iCentris/pyr clients).

## Steps
1. **Read the item + its plan**:
   ```
   curl -s "$MYJIRA/api/v1/projects/$SLUG/tasks/$TASK_ID"
   ```
2. **Mark it in progress**:
   ```
   curl -s -X PATCH "$MYJIRA/api/v1/projects/$SLUG/tasks/$TASK_ID" -H 'Content-Type: application/json' -d '{"task":{"board_state":"in_progress"}}'
   ```
3. **Create an isolated worktree** off the base branch (`BASE`, default `main`). NEVER work in the main checkout — other agents (and the human) may be using it concurrently; a shared tree means agents stash and clobber each other's work. ALL subsequent steps run inside `$WT`:
   ```
   git fetch origin "$BASE"
   WT="$HOME/.cache/myjira/worktrees/$SLUG/$TASK_ID"
   git worktree remove --force "$WT" 2>/dev/null; rm -rf "$WT"
   git worktree add -B "board/$TASK_ID" "$WT" "origin/$BASE" 2>/dev/null || git worktree add -B "board/$TASK_ID" "$WT" "$BASE"
   cd "$WT"
   ```
   `$WT` derives only from `$HOME/$SLUG/$TASK_ID`, so recompute it in any later shell call. If tests fail on missing deps (gems, node_modules), install them inside the worktree.
   Then **state your direction** so the ticket is a durable, reviewable record of the run — POST a comment to the append-only worklog (shows in the "Activity & decisions log" on the ticket, updates live):
   ```
   curl -s -X POST "$MYJIRA/api/v1/projects/$SLUG/tasks/$TASK_ID/comments" \
     -H 'Content-Type: application/json' \
     -d '{"comment":{"author":"engineer","body":"Branching off '"$BASE"'. Direction: <what youll do>. Assumptions: <key assumptions>. Will touch: <files/areas>."}}'
   ```
   POST a closing comment the same way when you finish (what shipped, anything you deviated from in the plan).
4. **Implement** the change per the plan. Follow the repo's conventions. Keep the diff focused on this item. Fix lint.
5. **Test leg.** First create/refresh a myjira test plan with a few acceptance cases for this change (POST `/api/v1/projects/$SLUG/test_plans`, then add cases via `.../test_cases/bulk`), then trigger the auto-test:
   ```
   curl -s -X POST "$MYJIRA/api/v1/projects/$SLUG/tasks/$TASK_ID/finish" -H 'Content-Type: application/json' -d '{}'
   ```
   That runs the plan headless (Playwright) and files a relay/Claude-in-Chrome visual ticket. Poll the returned run URL until status is `passed`/`failed`/`partial`. Also run the repo's own test suite if it has one (`bin/rails test`, `bin/ci`, `npm test`, etc.).
6. **Green** (tests pass): commit, push, open a PR onto main, capture its number/url/diff, and set the item to review:
   ```
   git add -A && git commit -m "<concise message>"
   git push -u origin "board/$TASK_ID"
   gh pr create --base "$BASE" --head "board/$TASK_ID" --title "<title>" --body "<summary + closes the board item>"
   PR=$(gh pr view --json number,url -q '.number'); URL=$(gh pr view --json url -q '.url'); DIFF=$(gh pr diff | head -c 60000)
   curl -s -X PATCH "$MYJIRA/api/v1/projects/$SLUG/tasks/$TASK_ID" -H 'Content-Type: application/json' \
     -d "$(jq -n --arg u "$URL" --argjson n "$PR" --arg d "$DIFF" --arg b "board/$TASK_ID" '{task:{board_state:"in_review",pr_url:$u,pr_number:$n,pr_state:"open",pr_diff:$d,branch_name:$b}}')"
   ```
7. **Red** (tests fail and you can't fix them): PATCH `{"task":{"board_state":"failed","agent_notes":"<what failed + why>"}}`.
8. **Blocked** (needs a human decision): PATCH `{"task":{"board_state":"waiting","agent_notes":"<the question>"}}`.
9. **Clean up** (always, on green/red/blocked — the branch is pushed, the worktree is disposable). From the main checkout (the directory the session started in):
   ```
   git worktree remove --force "$HOME/.cache/myjira/worktrees/$SLUG/$TASK_ID" 2>/dev/null; git worktree prune
   ```

Never merge the PR — `in_review` means it awaits the human's merge. Report a one-line outcome.
