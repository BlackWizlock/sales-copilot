# План интерфейса встречи

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Полноценное прослушивание с синхронным текстом, локальные голоса и безопасная установка альфа-обновлений.

**Architecture:** MeetingModel координирует самостоятельные контроллеры воспроизведения, разделения голосов и обновления. CopilotCore хранит временные и голосовые контракты с совместимостью старых JSON. Компоненты интерфейса отделены от захвата.

**Tech Stack:** Swift 6 language mode 5, SwiftUI, AVFoundation, ScreenCaptureKit, локальная модель голосов, Security.framework.

**Spec:** docs/superpowers/specs/2026-11-02-meeting-experience-design.md

## Global Constraints

macOS 15+, Apple Silicon; аудио и обработка локальны; клиентские записи не используются во внешних сервисах. Подписи Axis закреплены, продукта «Модель» нет. Воспроизведение запрещено во время захвата. Существующие чужие изменения не отменять. Сохранение разрешений требует фактической проверки двух сборок.

## Review Focus

1. Смена встречи при проигрывании не оставляет старый звук и позицию.
2. Промежутки, пересечения, нулевая и нечисловая длительность не ломают подсветку и ползунок.
3. Отсутствие M4A не выдаёт один WAV за полный разговор.
4. Старые манифесты читаются, ручные имена не теряются при повторной обработке.
5. Поддельное обновление и сбой замены не повреждают текущую программу и архив.

### Task 1 Плеер и синхронизация

**Files:** Create Sources/AxisCopilot/PlaybackController.swift, Sources/AxisCopilot/PlaybackView.swift, Sources/CopilotCore/PlaybackTimeline.swift; modify MeetingModel.swift, MeetingView.swift, Sources/CoreChecks/main.swift.

**Interfaces:** PlaybackController exposes position/duration/isPlaying/rate/volume, load(url:), toggle(), seek(to:), stop(); PlaybackTimeline.activeLines(_:at:) returns [UUID]. MeetingModel owns playback, stops before capture/select; view observes playback directly.

- [ ] Write failing CoreChecks for interval starts/ends, overlap, gaps, clamp nonfinite positions, supported speeds 0.5...2 in steps 0.25.
- [ ] Run `swift run --build-system native CoreChecks`, observe missing-contract failure.
- [ ] Implement timeline and AVAudioPlayer with enableRate=true; preserve rate through pause/seeks, persist preference; prepare archive before playing, never fallback to partial WAV.
- [ ] Add fixed transport, seek slider, volume, speed, accessible shortcuts, text search and scroll-follow with manual disengagement; refresh 0.1 seconds only during playback.
- [ ] Run CoreChecks and synthetic playback check for rates, pause, end, source switch and archive errors. Verify UI through CUA.

### Task 2 Подпись и обновления

**Files:** Create scripts/sign-app.sh, scripts/setup-signing.sh, Sources/AxisCopilot/AppUpdater.swift, scripts/check-updates.sh; modify build-app.sh, package-employee.sh, docs/EMPLOYEE-INSTALL.md. Root integrates App.swift and MeetingView.swift.

**Interfaces:** AppUpdater @MainActor ObservableObject exposes error/status/isUpdating; chooseUpdate(currentlyBusy: Bool). Bundled updater helper uses pinned identifier/signer and fixed application destination. No signing private key in package.

- [ ] Write failing synthetic update validation/rollback checks; observe rejection/absent implementation.
- [ ] Implement permanent local signing identity bootstrap with explicit requirements and no silent ad-hoc fallback for distributions. Keep noninteractive CI option explicit.
- [ ] Implement native file selection, version/architecture/signature/signer validation, staged replacement after process exit, rollback and restart with NSWorkspace.
- [ ] Test malformed, wrong-signer, older-version, rollback and valid update on disposable synthetic applications. Verify signed DR equality across two differing builds. No permission or trust bypass.
- [ ] Update employee instructions, disclose one-time transition and no notarization. Run shell syntax and update checks.

### Task 3 Локальные голоса и имена

**Files:** Create Sources/AxisCopilot/LocalDiarizer.swift, Sources/CopilotCore/Speaker.swift, scripts/setup-speakers.sh; modify Package.swift only if needed, Session.swift, CoreChecks tests. Root integrates MeetingModel/View.

**Interfaces:** LocalDiarizer.process(session: MeetingSession, store: SessionStore) async throws, результат [SpeakerTurn]; SpeakerTurn has stable id/speakerID/source/start/end, SpeakerProfile id/name. Data backward-compatible via optional fields. Model download explicit, no cloud inference.

- [ ] Write failing old-manifest compatibility, overlap/unknown assignment, name persistence and manual override tests.
- [ ] Pin a compatible local engine/model and license; download only public models, verify local inference. Keep resources outside repository.
- [ ] Implement post-meeting grouping, minimum confidence/unknown state, progress/errors and manual names/per-phrase correction; repeat processing preserves manual override keyed to stable phrase ID.
- [ ] Test synthetic 3-speaker audio and overlap; report exact measured limitations, not automatic identity claims.

### Task 4 Интеграция и выпуск

**Files:** MeetingModel.swift, MeetingView.swift, App.swift, docs/TESTING.md, _standards/architecture.md, STATUS.md, Resources/Info.plist, scripts/ci-local.sh.

- [ ] Integrate controllers without changing capture start authorization; status of audio/text/voices independent.
- [ ] Run fresh checkout `bash scripts/ci-local.sh`, targeted synthetic checks, independent code review and Jev. Fix concrete important findings.
- [ ] Package employee Apple Silicon build, verify external dylibs absent and bundled inference; preserve installed app if user is recording.
- [ ] Install approved update when idle, verify launch/history/player through CUA; signature transition may require user system authentication. Do not claim permissions retained before actual test.
- [ ] Run hq_check staged; publish only if applicable gates permit, no merge without other lead cross-review. Record concrete remaining acceptance checks.

## Execution record

Owner/Agent: Codex. Handoff: owned. Existing direct instruction to implement without repetitive confirmations remains in force. Execute controller work in parallel where files do not overlap, integrate and review centrally. Previous icon/echo commit gate remains unresolved; do not silently treat it as cleared.
