---
name: resolve-github-issue
description: Select or accept a ready GitHub Issue in MeetingAudioCapture, claim it, implement and verify the scoped change, and create a pull request for developer validation. Use when asked to take the next Issue, resolve or implement an Issue, fix a queued bug, add a queued feature, or prepare a PR. Do not use to merge a PR.
---

# Resolve GitHub Issue

Deliver exactly one Issue from queue to a reviewable PR. Treat repository-root `AGENTS.md`, `CONTRIBUTING.md`, and the selected Issue as authoritative.

## Establish eligibility

1. Inspect `git status` and preserve unrelated work.
2. Confirm `gh auth status` and the repository default branch.
3. Count open PRs. Do not start another Issue when three agent-managed PRs are already open.
4. If the user supplied an Issue number, inspect that Issue. Otherwise select one open Issue labeled `agent:ready`, ordered by priority labels `priority:high`, `priority:medium`, then `priority:low`, and then oldest first.
5. Reject or pause work whose acceptance criteria are missing, whose dependencies are unresolved, or whose scope materially requires a product decision. Record the concrete blocker on the Issue and apply `agent:blocked`.
6. Check that no open PR, branch, assignee, or `agent:working` label indicates duplicate work.

If no eligible Issue exists, report that the queue is empty. Do not invent work.

## Claim the Issue

1. Apply `agent:working` and remove `agent:ready` and `agent:blocked`.
2. Assign the active GitHub user when repository permissions allow it.
3. Add a short Issue comment stating that work has started and naming the planned branch.
4. Synchronize `main` with `--ff-only` and create `codex/<issue-number>-<short-purpose>`.

If claiming or branch creation fails, undo only the claim metadata created in this run and report the failure. Never continue on `main`.

## Implement

1. Read the relevant implementation, tests, and durable documentation before editing.
2. Reproduce or characterize current behavior. For an incident, follow `docs/incident-response.md` and keep facts separate from hypotheses.
3. Make the smallest maintainable change satisfying the Issue. Add a regression test first when pure logic can reproduce a defect.
4. Follow all privacy, audio-data, permission, dependency, and architecture constraints in `AGENTS.md`.
5. Run the checks required by `CONTRIBUTING.md`. Never claim live recording verification from automated tests.
6. Review the diff and staged files for scope, credentials, recordings, personal data, build output, and temporary diagnostics.

## Create the PR

1. Commit only the scoped files with a concise imperative subject.
2. Push the branch and open a PR using `gh`. Include `Closes #<issue-number>`.
3. Complete the repository PR template truthfully. Mark manual checks as pending or not applicable; never pre-approve them.
4. Apply `agent:managed` and `verification:required` to the PR when the labels exist.
5. Follow required checks with `gh pr checks`. Fix failures in scope; do not weaken CI or branch protection.
6. Comment on the Issue with the PR URL and the exact developer verification requested.

Stop after handing off a green or clearly diagnosed PR. Do not merge, create a release, or start a second Issue in the same run.

## Handoff

Report:

- Issue and PR URLs
- branch name
- automated checks actually run and their results
- exact manual verification steps, or why they are not applicable
- remaining risks or blockers
