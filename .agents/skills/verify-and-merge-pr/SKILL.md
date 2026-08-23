---
name: verify-and-merge-pr
description: Record a developer's manual validation result for a MeetingAudioCapture pull request and, when explicitly approved and all protections pass, squash-merge it and confirm Issue closure. Use after the developer reports testing a branch build, approves a PR, or asks to merge a verified PR. Do not use to implement changes or infer approval.
---

# Verify and Merge PR

Complete one PR only after the developer supplies an explicit validation result. Treat repository-root `AGENTS.md`, `CONTRIBUTING.md`, the PR, and its linked Issue as authoritative.

## Confirm authority and scope

1. Identify the exact PR. Do not guess when multiple PRs could match.
2. Inspect the PR diff, linked Issue, review state, labels, and required checks with `gh`.
3. Require an explicit developer result for each manual check requested by the PR. A general merge request counts as merge approval, but never as evidence that unreported hardware checks passed.
4. Ensure the result identifies the tested branch or build and, for recording changes, the relevant mode, device, macOS version, and playback result.

If verification failed, do not merge. Record the failure on the PR, keep or restore `verification:required`, remove `verification:passed`, and hand the PR back for repair.

## Record successful verification

1. Add a concise PR comment containing the developer-reported result without embellishment.
2. Replace `verification:required` with `verification:passed` when those labels exist.
3. Confirm the PR still targets `main`, is not a draft, has no unresolved requested changes, and is mergeable.
4. Confirm all required status checks pass for the current head commit and the branch is up to date when protection requires it.

Do not bypass protections, dismiss reviews, force-push, or use administrator override.

## Merge and reconcile

1. Squash-merge using `gh pr merge --squash --delete-branch` only when approval and every required condition are present.
2. Confirm the PR is merged and the linked Issue is closed. If automatic closure did not occur, investigate the link before closing anything manually.
3. Synchronize local `main` with `--ff-only` when the current worktree is clean. Do not discard unrelated local changes.
4. Recount open PRs and report whether capacity is available for another Issue. Do not automatically start the next Issue in this run unless the user separately asks.

## Handoff

Report:

- merged PR and closed Issue URLs
- recorded verification summary
- final required-check status
- squash commit
- whether the open-PR count is below three

If any condition blocks merging, report the exact unmet condition and the safe next action.
