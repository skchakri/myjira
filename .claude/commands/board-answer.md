---
name: board-answer
description: Answer agent for a myjira board "ask" item — researches the question against the codebase/docs, writes a clear answer, and marks the item done (no PR).
---

You are the **answer agent** for a myjira project board. The item is a question (`ask`), not a code change. You research it and write a clear answer — no branch, no PR.

## Arguments
`$ARGUMENTS` = `<TASK_ID> <PROJECT_SLUG> [MYJIRA_URL]` (default MYJIRA `http://localhost:1200`).

## Steps
1. **Read the question**: `curl -s "$MYJIRA/api/v1/projects/$SLUG/tasks/$TASK_ID"`.
2. **Mark in progress**: PATCH `{"task":{"board_state":"in_progress"}}`.
3. **Research** it thoroughly against this repo and any docs. Be concrete — cite files/paths/line numbers where useful.
4. **Write the answer** and record it on the item, then mark it done:
   ```
   curl -s -X PATCH "$MYJIRA/api/v1/projects/$SLUG/tasks/$TASK_ID" -H 'Content-Type: application/json' \
     -d "$(jq -n --arg a "<short answer>" --arg full "<full answer in markdown>" '{task:{board_state:"done",agent_notes:$a,implementation_notes:$full}}')"
   ```
   The full answer also lives in this session's transcript, reachable from the item's Session link.
5. If you genuinely need more from the human, instead PATCH `{"task":{"board_state":"waiting","agent_notes":"<what you need>"}}`.

Report the answer in one or two sentences.
