---
description: Send a plan and wait for review feedback
---

Submit a plan file to Monocle and block until the reviewer responds with feedback.

**Important:** This is for content that isn't already a tracked file change — plans, architecture docs, summaries, etc. You do NOT need to send regular code files; Monocle automatically picks up file changes.

## Steps

1. **Find the plan file** — if the user provided a path as an argument, use that. Otherwise, find the most recently modified plan file in the project.

2. **Read the plan file** to confirm it exists and get its filename.

3. **Call the monocle `send_artifact` tool** with:
   - `title`: The first markdown heading from the plan, or the filename if no heading found
   - `file_path`: Absolute path to the plan file
   - `id`: The plan filename (e.g. `my-plan.md`) — ensures updates replace the previous version
   - `content_type`: `md`

4. **Call the monocle `get_feedback` tool** with `wait=true` to block until the reviewer responds.

5. **Handle the response:**
   - If the reviewer approved with no comments, inform the user and continue
   - If the reviewer provided feedback requesting changes, share the feedback with the user and act on it — update the plan, then repeat from step 3
   - Keep iterating until the reviewer approves
