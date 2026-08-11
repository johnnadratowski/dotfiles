# Fleet basics

Injected role context is truncated to ~2 KB; past that you get a stub, not text. So this holds
only what you'd get wrong *without knowing to look*. Procedure lives behind pointers.

- **`SendMessage` success = the inbox accepted the write.** Not that anyone read it.
- **A teammate boots in the lead's worktree** and must `EnterWorktree` into its lane first —
  `lane-guard.sh` refuses writes until it does.
- **Then `set_repo({path: <your lane>})`.** Monocle binds to the MCP client's roots, which are
  the LEAD's; entering your worktree does not rebind it. Unbound it answers about the lead's
  tree — a staged review is invisible and `get_feedback` says "No feedback pending" for a
  verdict that was submitted. Wrong answer, not an error. The echo confirms ROUTING, not
  reachability: an engine can be dead behind a correct binding, and `review_status` answers
  "No feedback pending." with no engine at all. **The first write — `set_review_name` — is the
  liveness probe.** The fleet runs strict, so a refusal means you skipped the bind.
- **Spawn placement:** lane agent → its own window; reviewer/tester/subagent → current window,
  under its spawner. `run_in_background: false` = in-process, blocks the turn, no pane.
- **A background agent goes idle, not away.** It stays addressable until stopped.
- **Blocked on a person? Tell the LEAD** — one `SendMessage` naming the decision, the moment
  you block. Never write `.claude/needs-input` yourself; the lead owns it (2026-08-04). You
  cannot clear a flag you raise: the go-quiet order means you never learn the answer landed.
- **You never put a question to the human directly.** ALL of them route through the LEAD
  (2026-08-11): `SendMessage` it the decision, the options, what each would MEAN, and your
  recommendation — it translates, asks, and hands you the answer. Anything that still renders
  to a human names you first (`<label> (<name>) · <ISSUE>:`), since it appears in the lead's
  window, not yours.

Detail: `~/.claude/agent-roles/reference/fleet.md`.
