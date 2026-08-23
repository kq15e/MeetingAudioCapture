# Repository Guidelines for Coding Agents

## Working Agreement

- Communicate with the user in Japanese.
- Before changing files, inspect `git status`, relevant implementation, tests, and documentation. Preserve user and other-agent changes, including untracked files.
- Keep changes limited to the active Issue. Do not mix incident investigation, feature work, and development-environment changes in one branch or Pull Request.
- GitHub operations must use `gh`. Use non-interactive `git` commands for local branch, commit, and push operations.
- Do not commit, push, merge, delete branches, install dependencies, change permissions, or perform destructive actions unless the user has authorized that scope.
- Prefer production-quality fixes over symptom suppression. Record unresolved assumptions and verification gaps.

The normal workflow and completion criteria live in `CONTRIBUTING.md`. Incident severity and response steps live in `docs/incident-response.md`. Treat those documents as authoritative and update them when the workflow itself changes.

## Product and Runtime Context

MeetingAudioCapture is a SwiftPM macOS menu-bar app for capturing meeting audio. It targets Apple Silicon and macOS 15 or later.

- Online meeting mode captures system audio and a selected microphone through ScreenCaptureKit.
- In-person mode captures a selected microphone through AVFoundation.
- Incoming audio is converted into timestamped chunks, resampled and mixed into stereo, then written as segmented M4A, WAV, or MP3 output.
- MP3 output depends on an external `ffmpeg`; M4A and WAV do not.
- Microphone and screen-recording behavior depends on macOS TCC permissions, installed audio devices, drivers, and real hardware. Pure unit tests cannot prove live capture works.
- Recordings can contain sensitive meeting content. Never inspect, copy, upload, log, or commit audio unless the user explicitly places a specific recording in scope.

## Architecture and Ownership

- `Package.swift`: package products, targets, framework links, and test settings.
- `Sources/MeetingAudioCaptureApp/`: AppKit status-bar UI, menus, alerts, and user interactions. Keep audio-domain logic out of this target.
- `Sources/MeetingAudioCaptureCore/`: recording engine, permissions, capture adapters, audio conversion, mixing, file writing, and settings stores.
- `Tests/MeetingAudioCaptureCoreTests/`: Swift Testing coverage for pure core logic.
- `Resources/Info.plist`: bundle metadata and permission usage descriptions.
- `Scripts/package-app.sh`: creates a release `.app` bundle.
- `Scripts/install-app.sh`: installs the current build into `/Applications` for permission and live-capture checks.
- `.github/`: CI, Issue forms, and Pull Request template.
- `docs/feature-notes.md`: shipped behavior and maintenance constraints.
- `docs/error-handling.md`: classified failures and expected recovery behavior.
- `docs/incident-response.md`: S1-S3 classification, investigation, repair, and closure rules.

The main audio path is:

```text
ScreenCaptureKit / AVCaptureSession
    -> CMSampleBuffer
    -> SampleBufferAudioConverter
    -> AudioChunk
    -> TimelineAudioMixer
    -> SegmentedAudioFileWriter
    -> M4A / WAV / MP3 segments
    -> optional AudioSegmentMerger
```

When diagnosing an audio failure, locate the failing stage before changing code. Do not assume an output-format problem when the failure occurs during input conversion.

## Expected Development Flow

For normal development and incident fixes:

1. Confirm `gh auth status` and create or identify a GitHub Issue.
2. Record the problem, scope, acceptance criteria, and relevant environment in the Issue.
3. Start from an up-to-date `main` and create `codex/<issue-number>-<short-purpose>`.
4. Reproduce or characterize the current behavior before implementation.
5. Add a failing regression test when the behavior can be isolated without live hardware.
6. Implement the smallest maintainable fix and update durable documentation where needed.
7. Run local build and tests, plus risk-based manual verification.
8. Commit only files in scope, push the branch, and create a PR with `gh pr create` containing `Closes #<issue-number>`.
9. Follow checks with `gh pr checks --watch`. Investigate failures rather than weakening CI.
10. Merge only after CI and required manual checks pass. Confirm the linked Issue closes and the local `main` is synchronized.

Direct commits and force pushes to `main` are exceptions and require explicit user authorization. When authorized, use `--force-with-lease`, verify the remote head immediately before pushing, and never include unrelated working-tree files.

## Incident Workflow

- Classify impact using `docs/incident-response.md`: S1 for broad recording failure/data loss, S2 for major failure in specific environments, and S3 for recoverable or minor defects.
- Keep facts, hypotheses, and unknowns separate. A screenshot may identify the throwing code path without identifying the source device or capture stream.
- Capture diagnostic metadata rather than audio: app/macOS version, recording mode, source kind, device identifier/name, sample rate, channels, bit depth, format flags, byte layout, and exact error.
- Put investigation chronology and temporary hypotheses in the Issue. Put the accepted fix and verification in the PR. Put only durable constraints and recovery guidance in `docs/`.
- Preserve partial recordings and user data during failure handling. Do not delete evidence or outputs while diagnosing unless the user explicitly requests it.
- A fix is not complete until the affected environment is verified or the remaining hardware-dependent verification is clearly handed off.

## Build, Test, and Manual Verification

Use a project-local Clang module cache in restricted environments:

```sh
CLANG_MODULE_CACHE_PATH=.build/ModuleCache swift build
CLANG_MODULE_CACHE_PATH=.build/ModuleCache swift test
Scripts/package-app.sh
```

- Tests use Swift Testing. Confirm the command runs test cases rather than only compiling the test bundle; CI on GitHub is the authoritative clean-environment run.
- Add tests for file naming, settings, conversion boundaries, resampling, mixing, output formats, segmentation, merging, and error classification whenever applicable.
- Avoid time-, ordering-, device-, permission-, and machine-dependent assumptions in unit tests.
- For audio capture, permission, device selection, or AppKit UI changes, also install with `Scripts/install-app.sh` and perform the relevant checks from `CONTRIBUTING.md`.
- Never claim live recording verification when only unit tests were run. State the exact mode, device, macOS version, and output playback result for manual checks.

## Coding Conventions

- Use Swift defaults, 4-space indentation, explicit domain names, and small focused types.
- Keep UI concerns in the app target and audio/recording behavior in the core target.
- Prefer early returns and explicit error propagation. Avoid silent fallback paths unless the product behavior requires them and tests document them.
- Add comments for non-obvious macOS API, PCM layout, timing, permission, compatibility, or data-safety constraints. Explain why, not line-by-line mechanics.
- Treat audio buffer byte layout, endianness, interleaving, alignment, sample format, channel count, timestamps, and sample rate as independent properties. Do not infer memory layout from bit depth alone.
- Do not add dependencies unless necessary and approved. Prefer AVFoundation, AudioToolbox, CoreMedia, and existing project facilities.

## Commits and Pull Requests

- Use concise imperative commit subjects, scoped to one feature or fix.
- PRs must explain the reason for the change, relevant Issue, tests run, manual checks, risks, and rollback approach.
- Include screenshots only for visible UI changes and redact private data.
- Do not mark checklist items complete unless that exact check was performed.
- Before committing, inspect the staged diff and ensure recordings, `.build/`, credentials, personal data, temporary diagnostics, and unrelated untracked files are excluded.

## Security and Privacy

- Never commit recordings, credentials, tokens, personal information, local build output, or TCC databases.
- Do not emit raw audio samples or meeting content into logs. Log only the minimum metadata required for diagnosis.
- Treat microphone and screen-recording permission changes as user-visible security changes; document prompts and restart requirements.
- Validate output paths and preserve existing recordings. Avoid cleanup that can remove partial or source segments after a failed write or merge.
