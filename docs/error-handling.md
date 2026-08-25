# Error Handling Assumptions

This document lists the error cases that MeetingAudioCapture intentionally classifies and recovers from. Use it as the baseline when adding exception handling, debugging failure reports, or writing manual test cases.

## Recovery Model

- Runtime errors move the app into `RecorderState.failed` and show `ERR` in the menu bar.
- The menu shows `再試行` when failed. Selecting it clears the failed state and starts a new recording attempt.
- The menu also shows `エラーをクリア`, which returns the recorder to idle without starting a new recording.
- When a recording fails after files were already opened, the app closes the writer and keeps any completed segment files. It does not delete partial outputs.
- User-facing alerts should include: what failed, the diagnostic detail, and the next action.

## Covered Error Cases

| Case | Internal error | Typical trigger | Expected behavior | Suggested manual test |
| --- | --- | --- | --- | --- |
| Microphone permission denied | `permissionDenied` | macOS microphone permission is off | Show a permission message and allow retry after permission is fixed | Turn off microphone permission, start in `対面` mode |
| Screen recording permission denied | `permissionDenied` | macOS screen recording permission is off | Show a permission/restart message and allow retry | Turn off screen recording permission, start in `オンライン会議` mode |
| No display available | `noDisplayAvailable` | ScreenCaptureKit cannot find a display | Fail before recording starts and remain recoverable | Hard to reproduce; inspect logs if display enumeration fails |
| Screen capture start failure | `screenCaptureFailed` | `SCShareableContent`, `SCStream.addStreamOutput`, or `startCapture` fails | Cleanup startup resources, enter failed state, allow retry | Remove/re-add screen permission, change display setup, then retry |
| No microphone available | `noMicrophoneAvailable` | No usable input device or selected device is gone | Fail before recording starts and allow selecting another mic | Select an external mic, unplug it, then start |
| Microphone capture start failure | `microphoneCaptureFailed` | `AVCaptureDeviceInput` or capture session setup fails | Cleanup startup resources, enter failed state, allow retry | Change macOS input device while testing, or unplug selected device |
| Runtime capture interruption | `captureInterrupted` | `SCStream` stops with an error during recording | Stop capture, close current writer, keep completed files, show `ERR` | Change screen recording permission/display setup during recording |
| File write failure | `fileWriteFailed` | Output directory becomes unavailable, disk full, or file write throws | Stop recording, keep files already closed, recommend checking save location | Record to a temp folder, remove/move it during recording |
| Audio conversion failure | `audioConversionFailed` | Incoming sample buffer cannot be converted | Stop recording, close writer, show audio processing guidance | Hard to force manually; covered by converter error paths |
| Missing or near-silent input during startup | Input diagnostic warning | No buffers arrive, or the first 7 seconds remain below -60 dBFS | Identify the affected input once and continue recording | Mute the microphone, start recording, wait at least 7 seconds, then confirm the saved file remains playable |
| Unsupported audio format | `unsupportedAudioFormat` | Input PCM format is unsupported | Stop/fail with audio format guidance | Hard to force manually; usually device/OS dependent |
| Invalid audio buffer | `invalidBuffer` | Malformed or inconsistent audio buffer | Stop/fail with audio processing guidance | Covered by unit tests around buffer validation |
| Writer not started | `writerNotStarted` | Audio is ready but the writer is unexpectedly missing | Fail and suggest changing save location/retrying | Mostly defensive; should not occur in normal UI flow |
| MP3 encoder unavailable | `mp3EncoderUnavailable` | MP3 is selected but `ffmpeg` is not installed in a known Homebrew/system path | Stop/fail at segment close, keep recoverable temporary M4A if conversion had started, suggest installing ffmpeg or choosing M4A/WAV | Select MP3 on a Mac without `ffmpeg`, record a short clip, then stop |
| MP3 encoding failure | `mp3EncodingFailed` | External encoder exits non-zero or cannot launch | Stop/fail, keep completed files, preserve temporary M4A in the session `parts/` directory where possible, show encoder diagnostic | Temporarily replace encoder with a failing test binary or inspect real encoder failure logs |
| Segment merge failure | `segmentMergeFailed` | Post-recording merge fails after segments were saved | Keep original segment files, show a merge error, and leave the recorder usable | Enable merge, then make the merge path fail and confirm `partNNN` files remain |
| Stop failure | `stopFailed` | `SCStream.stopCapture` returns an error | Enter failed state, keep any completed files, allow clear/retry | Hard to force manually; inspect if stop shows an error |

## Related Operational Cases

These are not all `RecorderError` cases, but they are part of the expected debugging surface.

| Case | Expected behavior | Suggested manual test |
| --- | --- | --- |
| Saved output directory no longer exists | Fall back to Downloads, clear saved setting, show a fallback alert | Select a temp folder, delete it, then start recording |
| Saved output directory is not writable | Fall back or reject selection, depending on when detected | Try selecting a read-only or restricted folder |
| TCC permission loop after rebuild | Use `/Applications/MeetingAudioCapture.app`, reset TCC if needed, then re-grant permissions | Run `Scripts/install-app.sh`, then reset `Microphone` / `ScreenCapture` for the bundle ID |
| Old app bundle still running | Latest code may not be active; install script attempts to quit old/new app before copying | Check that only `MeetingAudioCapture.app` is running |
| MP3 conversion is slower than direct formats | MP3 uses a temporary M4A plus ffmpeg conversion; M4A/WAV remain the safest formats for long recordings | Record a short MP3 clip first, then confirm longer recordings in the target environment |
| Segment merge retention | The merged file is written at the session root. Source `partNNN` files remain in `parts/` on both success and failure | Enable merge with short segments and confirm the merged file and all original parts remain; inject failure and confirm originals remain |

## Out Of Scope For Current Handling

- Repairing corrupted M4A files after force quit or power loss.
- Retrying a failed recording automatically without user action.
- Guaranteeing the final in-progress segment is playable after every write failure.
- Recovering from macOS TCC database corruption beyond documenting reset steps.
- Detailed OS-level diagnostics for third-party audio drivers or virtual devices.
