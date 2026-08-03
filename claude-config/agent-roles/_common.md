# Fleet basics

Injected role context is truncated to ~2 KB; past that you get a stub, not text. So this holds
only what you'd get wrong *without knowing to look*. Procedure lives behind pointers.

- **`SendMessage` success = the inbox accepted the write.** Not that anyone read it.
- **A teammate boots in the lead's worktree** and must `EnterWorktree` into its lane first —
  `lane-guard.sh` refuses writes until it does.
- **Then `set_repo({path: <your lane>})`.** Monocle binds to the MCP client's roots, which are
  the LEAD's; entering your worktree does not rebind it. Unbound it answers about the lead's
  tree — a staged review is invisible and `get_feedback` says "No feedback pending" for a
  verdict that was submitted. Wrong answer, not an error. Verify from the echo; the fleet runs
  strict, so a refusal means you skipped it.
- **Spawn placement:** lane agent → its own window; reviewer/tester/subagent → current window,
  under its spawner. `run_in_background: false` = in-process, blocks the turn, no pane.
- **A background agent goes idle, not away.** It stays addressable until stopped.
- **Blocked on a person?** `echo "<you> · <ISSUE>: <the decision>" > .claude/needs-input`; `rm`
  when answered. Nothing in the harness reports "waiting" — this is the only signal.
- **Every question to a human names you first.** Your AskUserQuestion renders in the **lead's**
  window, not yours, so `question` opens with `<label> (<name>) · <ISSUE>:` — **every** question
  in a multi-question prompt, since each is a separate card. `header` stays **descriptive**
  (~12 chars: what the question is about); your name is already in the text. Same prefix in
  needs-input and in any message asking for a decision.

Detail: `~/.claude/agent-roles/reference/fleet.md`.
