# Recording and transcription implementation plan

> For agentic workers: use superpowers:executing-plans. Execute inline under the explicit user instruction of 2026-11-02.

**Goal:** Native Mac prototype captures meeting audio and microphone, preserves recordings and transcribes Russian locally.

**Architecture:** ScreenCaptureKit emits app audio and microphone separately; serialized capture sink resamples to 16 kHz mono and closes small WAV chunks. Main-actor session coordinator persists a manifest and processes disk-backed transcription jobs one at a time through whisper.cpp. SwiftUI exposes explicit start/stop, separate meters, transcript, playback and recording folder.

**Tech Stack:** Swift 6 compiler in Swift 5 language mode, SwiftUI, ScreenCaptureKit (macOS 15+), AVFoundation, whisper.cpp CLI. No remote inference or paid services.

**Spec:** ../specs/2026-11-02-sales-copilot-design.md, slice A only.

## Global constraints

1. Capture only after explicit start; no hidden recording.
2. Russian local transcription; preserve both sources and timestamps.
3. Source loss, recording failure and transcription failure must be visible.
4. Recordings and model weights outside git; no cloud calls at runtime.
5. All product code in the isolated codex/recording-prototype worktree.

## Review focus

1. Stop during startup or transcription must not create a second active recording.
2. Failure of one audio source must never display both sources as healthy.
3. Disk write failure must become a visible error, not silent data loss.
4. Silence must not create invented transcript text; preserve short final chunks.
5. Restart must expose interrupted recordings without automatically resuming capture.

## Task 1 Session persistence and audio chunks

Files: Package.swift; Sources/CopilotCore/Session.swift; Sources/CopilotCore/WaveFile.swift; Tests/CopilotCoreTests/SessionTests.swift.

Interfaces: AudioSource (microphone, meeting); AudioChunk (id, source, start, duration, filename, status); MeetingSession manifest; SessionStore create/load/save; WaveFile encode/decode PCM16.

- [x] Write tests for WAV clipping/header/data, manifest round trip, interrupted status and path isolation.
- [x] Run standalone CoreChecks after observing XCTest is absent from CLT; observe missing implementation failure.
- [x] Implement core value types and atomic persistence, owner-only storage.
- [x] Re-run targeted tests.

## Task 2 Capture and transcription

Files: Sources/AxisCopilot/AudioCapture.swift; Sources/CopilotCore/WhisperOutput.swift; Sources/AxisCopilot/LocalTranscriber.swift; Tests/CopilotCoreTests/WhisperTests.swift.

Interfaces: CaptureSink receives CMSampleBuffer, closes 8-second chunks and flushes partial chunk on stop; onChunk(AudioChunk), onLevel(AudioSource, Float), onError(String). LocalTranscriber.transcribe(chunkURL: URL, offset: Double, source: AudioSource) async throws returning TranscriptLine array.

- [x] Write JSON parser tests for offset translation, malformed output, blank/no-speech filtering.
- [x] Observe test failure; implement parser and run targeted tests.
- [x] Implement ScreenCaptureKit dual audio capture, shared monotonic origin, meters and serialized file writes.
- [x] Implement local Process invocation with fixed arguments, file logs and timeout; no shell interpolation.
- [x] Verify real whisper transcription of synthetic Russian WAV and both-source timing.

## Task 3 Native UI, packaging and end-to-end verification

Files: Sources/AxisCopilot/App.swift; Sources/AxisCopilot/MeetingModel.swift; Sources/AxisCopilot/MeetingView.swift; Resources/Info.plist; scripts/build-app.sh; scripts/ci-local.sh; docs/TESTING.md.

Interfaces: Main-actor model owns recording state, session manifest, pending disk jobs, source health and playback. Explicit actions: prepare, refresh apps, start, stop, replay, reveal recordings; interrupted-session selection is read-only until deliberate retry transcription.

- [x] Implement UI, startup validation, stop-and-drain and session browser.
- [x] Package .app with privacy strings, stable bundle ID and ad-hoc signing.
- [x] Run full tests and release build once; run offline synthetic transcription and recording playback test.
- [x] Inspect native app in UI; exercise start/stop and permissions if available, report any permission step requiring owner action.
- [x] Fresh branch reviewer, address important findings, update standards/STATUS, run Jev gate.
- [x] Add fixed brand header and product credits; package portable Apple Silicon app by owner request.
- [ ] Owner decision on Jev escalation, commit, committed clean-checkout verification and push feature branch.

## Rulings and ledger

- User explicitly approved full design and initial commit and instructed immediate implementation; do not ask for a further plan approval.
- Bootstrap executor fails on an unborn HEAD. Initial documentation commit performed with the equivalent explicit-path safety checks under the user permission; feature commits use normal executor.
- WhisperKit was a candidate, not a pinned requirement. Existing whisper.cpp CLI avoids full-Xcode dependency and permits an independently testable local pipeline. Model: multilingual small, downloaded once. No claim of latency until measured.
- HQ registration is separate metadata work; do not modify unrelated dirty HQ files.

- CoreChecks replaces XCTest because the installed CLT has no XCTest module. SDK27 @State macro plugin also requires Xcode; sheet state is in ObservableObject instead.
- Independent reviewer found 4 important failure-path defects; fixed writer error propagation, interrupted state, per-meeting recovery and startup-error cleanup, with targeted regression checks.
- Live ScreenCaptureKit verified after owner permission: selected QuickTime audio + microphone, in-recording transcript, 8 saved chunks including partial tails, M4A and restart history. Employee portable distribution added by user request.
