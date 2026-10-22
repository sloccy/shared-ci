# shared-ci

Reusable GitHub Actions workflow for the repos under `sloccy/`.

## `security.yml` — one nightly job per repo

Every night: **scan -> fix -> test -> push to the default branch.** Every week: dispatch a
rebuild. If anything fails: one issue. GitHub's Dependabot *alerts* are the safety net.

| Step | What it does |
|---|---|
| Go | `govulncheck` (called symbols only) -> bump each module to the minimum fixed version; stdlib findings raise the `go` directive |
| npm | `npm audit fix`, then bump exact-pinned direct deps to the fixed version when it is not a major |
| `extra_fix_script` | repo-specific bumps (e.g. a pinned Lambda layer) |
| Gate | `test_command` (default: Go build+test / `npm test`), optional `lint_command`, then govulncheck must be clean |
| Push | commit by `github-actions[bot]` listing modules + advisory IDs, pushed with the owner PAT so the repo's own publish/deploy workflow runs |
| `binaries` | `govulncheck -mode=binary` on shipped Go binaries (e.g. cloudflared); a finding turns the run red |
| Weekly rebuild | dispatches `rebuild_workflow` on `rebuild_weekday` (skipped when the nightly already pushed) |
| Failure | opens/comments on one `security-automation-failure` issue; closes it on the next green run |

If the gate fails, **nothing is pushed**; the run fails with the exact bump list in the issue.
Lint runs in the repo's normal CI on the pushed commit (a failure emails the PAT owner as the
pusher); set `lint_command` to make it part of the gate instead.

### Using it
Copy `templates/security.yml` to `.github/workflows/security.yml` and add the secret
`WORKFLOW_TOKEN`: a fine-grained PAT for that repo with *Contents* read/write and an expiry. (Issues and
workflow dispatch use the built-in `GITHUB_TOKEN`; the caller grants `issues: write` and `actions: write`.) The owner must be able to bypass branch protection on the default
branch. Call the workflow at `@v1` (never `@main`).

### Testing a change
Run the caller's workflow manually. `dry_run` (default on for manual runs) scans, fixes and
tests but does not push. `target_branch` runs the whole flow against a scratch branch.

### Policy
Dependencies move only for known vulnerabilities, to the minimum fixed version, never for
routine version bumps. Dependabot security *PRs* are off; its alerts stay on.

## Legacy workflows
`vuln-autofix.yml` and `dependabot-auto-merge.yml` are the previous PR-based flow and are
removed once every repo has moved to `security.yml`.
