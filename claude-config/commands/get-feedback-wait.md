---
description: Block until reviewer submits feedback
---

Call the monocle `get_feedback` tool with `wait=true` to block until your reviewer submits feedback through Monocle.

## Handling the response

- Read the feedback carefully and act on it — the feedback contains your reviewer's comments, issues, and suggestions about your code changes
- Address the reviewer's comments in your code
- If the reviewer requested changes, call `get_feedback` with `wait=true` again after addressing the feedback
- Keep iterating until the reviewer approves
