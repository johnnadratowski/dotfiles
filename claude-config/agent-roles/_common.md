# Fleet basics

Injected role context is truncated to ~2 KB; past that you get a stub, not text. So this holds
only what you'd get wrong *without knowing to look*. Procedure lives behind pointers.

- **`SendMessage` success = the inbox accepted the write.** Not that anyone read it.
- **A teammate boots in the lead's worktree** and must `EnterWorktree` into its lane first —
  `lane-guard.sh` refuses writes until it does.
- **Spawn placement:** lane agent → its own window; reviewer/tester/subagent → current window,
  under its spawner. `run_in_background: false` = in-process, blocks the turn, no pane.
- **A background agent goes idle, not away.** It stays addressable until stopped.
- **Blocked on a person?** `echo "<you> · <ISSUE>: <the decision>" > .claude/needs-input`; `rm`
  when answered. Nothing in the harness reports "waiting" — this is the only signal.
- **Every question to a human names you first.** Your AskUserQuestion renders in the **lead's**
  window, not yours: `header` = your agent name alone (~12 chars), `question` opens with
  `<you> · <ISSUE>:` — **every** question in a multi-question prompt, since each is a separate
  card. Same prefix in needs-input and in any message asking for a decision.

Detail: `~/.claude/agent-roles/reference/fleet.md`.
