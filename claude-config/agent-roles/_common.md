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
- **Tests that need Docker, the shared DB or a fixed port are the STANDING TESTER's alone.**
  `SendMessage` the fleet's `…-tester` (worktree + suite); never run them in your lane and
  never spawn a tester subagent. DB-free gates (format/lint/types/unit) stay yours.
- **Spawn placement:** lane agent → its own window; reviewer/subagent → current window,
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

- **HANDOFF.md — write it dying, read it born, DELETE it once ingested.** On a
  `shutdown_request`, write `.claude/HANDOFF.md` (lane-local): where the work stands, what is
  uncommitted and why, the next action, any trap — VERIFIED FACTS ONLY, every verdict word
  carrying its provenance (a handoff has asserted false state before). Written on EVERY
  lead-instructed stop — /shutdown fleet-wide, a single-agent cycle, any "go down" — not only
  full-fleet boundaries. On boot, read it FIRST and IN FULL — **always read, even when you
  resumed with context**: a `--continue` after compaction feels identical from the inside to
  one with full context, so the handoff is your independent cross-check, and a disagreement
  with what you think you remember is a FINDING to surface, not noise to resolve silently.
  Weight it by boot mode (fresh boot: primary lead; resumed: cross-check). Then **check it is
  not stale**: compare its mtime against the lane's last commit (`git log -1 --format=%cI`)
  and the latest transcript activity — a handoff OLDER than either predates later work; trust
  the newer evidence and say so. Its claims are LEADS to verify
  against the tree/Linear, never facts to act on. **Delete it only after the ENTIRE file is
  in context** (read it whole, not head/grep — then delete in the same turn) — a stale
  handoff is worse than none, and the next writer starts clean.

Detail: `~/.claude/agent-roles/reference/fleet.md`.
