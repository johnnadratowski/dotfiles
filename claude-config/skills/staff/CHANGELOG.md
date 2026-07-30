# staff — changelog

- **1.0.0** — Initial, as the up-counterpart to `/shutdown`.

  Deliberately **not** a wrapper around `team-boot.sh boot`. Booting the lead is shell and
  stays shell; what needed a skill is the half only an agent can do — **only the lead can
  create teammates**, since one launched any other way runs fine and is permanently
  unaddressable.

  The step that never existed anywhere is verification. `boot --with-team` types a request
  into the lead's pane and nothing confirms the outcome, so a teammate that skipped
  `EnterWorktree` was a silently-degraded fleet: alive, addressable, standing in lane 0, with
  every write bounced by `lane-guard` and no one watching. Staffing is now only claimed when
  `team-boot.sh status` — which resolves from process cwd — shows the pid in the lane.

  Placement closes with `fleet-layout reapply` rather than a fixed mode, so adding an agent
  restores the arrangement the user last chose instead of imposing one.
