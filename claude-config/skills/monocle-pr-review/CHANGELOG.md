# Changelog — monocle-pr-review

## 1.0.0

- Initial version: review a GitHub PR in Monocle.
  - Resolves + checks out the PR (`gh pr view` / `gh pr checkout`).
  - Points Monocle at the PR diff via `set_base_ref` on the merge-base (native diff, not raw
    artifact).
  - Surfaces the PR's inline review comments as range annotations on the code they reference.
  - Adds the agent's own doc-linking annotations on non-obvious ranges.
  - Groups the changed files entry-point → dependency, then blocks on the reviewer's verdict.
