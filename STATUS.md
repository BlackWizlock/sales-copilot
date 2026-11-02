# STATUS

updated: 2026-11-02

## Сейчас в работе

### SC-002 Локальная запись и транскрипция

- Owner/Agent: Codex
- Source: user approval 2026-11-02, written design and initial commit approved, implementation requested
- Scope: native macOS app, microphone/app audio capture, WAV and M4A, local Russian transcription
- Handoff: ready_for_review
- Branch: codex/recording-prototype
- Publication: implementation 83ba8f8 and verification 4dcf546 pushed; PR https://github.com/BlackWizlock/sales-copilot/pull/1 open for review
- Status: implementation commit 83ba8f8 passed ci-local.sh in a fresh clean clone: 10 core checks, release build, diagnostics, Russian two-source transcription and M4A export; live QuickTime + microphone capture and restart history verified earlier; portable Apple Silicon bundle and fixed Axis branding verified
- Review: independent reviewer confirmed 4 Important failure-path findings fixed; no new Critical/Important findings. Successful chunks now synchronously drained before export on stop error.
- Design: docs/superpowers/specs/2026-11-02-sales-copilot-design.md
- Plan: docs/superpowers/plans/2026-11-02-recording-transcription.md
- Validation: docs/TESTING.md
- Update 0.1.1: native macOS icon added; inactive Model product link removed by owner correction; Apple Silicon package v2 built and bundled inference passed
- Next: cross-review by other lead and live Zoom/Telemost acceptance; owner explicitly approved proceeding despite feature Jev escalation on 2026-11-02; no merge without other lead review

## Сделано за неделю

### SC-001 Создание проекта и описание прототипа

- Owner/Agent: Codex
- Source: user request and explicit approval 2026-11-02
- Scope: approved project scaffold, private repository, design
- Handoff: ready_for_review
- Status: initial documentation approved by user and published as main commit 171b734
- Validation: initial gitleaks clear; instruction_sync checked=1 conflicts=0; frontmatter resolver sees sales-copilot
- Pending: HQ gitlink/submodule registration remains separate metadata tail; generated HQ registry already identifies project

## Очередь

### SC-003 Автоматический суфлёр и интеграции

- Owner/Agent: Codex
- Source: user request 2026-11-02
- Scope: proposal grounding, automatic suggestions, Bitrix24 calendar/deal, MCP, optional OpenRouter, CRM recording export
- Handoff: owned
- Status: pending SC-002 live acceptance; not implemented

## Review Gates

1. Initial documentation Jev escalation safe_to_apply=0.38, correctness confidence=0.15 was explicitly overridden by user approval of description and initial commit. Initial commit 171b734 pushed.
2. Product feature Jev gate escalated: safe_to_apply=0.23, composite=0.6628, low confidence on test_gap, no concrete defect specified. Both verification claims (10 core checks and bundled synthetic inference) confirmed with confidence=1.0. Owner explicitly approved commit and push despite this escalation on 2026-11-02 (reply to the specific exception request: «да, поехали»). This is separate from the initial documentation exception. Implementation commit 83ba8f8 passed ci-local.sh in a fresh clean clone.
3. Cross-review from other lead required before merge.

## Known Risks

1. Zoom, Telemost, Granola coexistence, headphones and long meeting still require live acceptance.
2. Bitrix24 REST availability, CRM attachment and native analysis not verified; no Bitrix integration in this slice.
3. Permanent local signing and manual signed updates implemented in 0.2.0; permission retention between installed builds still requires live acceptance. No notarization or automatic network delivery.
4. Small local model can misrecognize names/numbers; 8-second chunks can split phrases. No measured live p95.
5. Audio not yet flushed from RAM can be lost in a crash. Persisted WAVs remain even if transcription/export fails.
6. MCP and OpenRouter are absent; confidential materials must not be sent to cloud providers.

### SC-002a Echo hotfix 0.1.2

- Owner/Agent: Codex
- Source: owner reports duplicate mic/application speech, asks immediate correction
- Scope: native microphone voice processing, playback feedback protection, honest source labels, device-change interruption
- Handoff: owned
- Validation: local release + core + native processing configuration + synthetic ASR/M4A passed; independent lifecycle review; physical echo/double-talk acceptance outstanding
- Gate: Jev safe_to_apply 0.20 escalated; test evidence verified; candidate installed locally after explicit immediate-fix instruction and independent re-review; existing session saved; permission refreshed after owner Touch ID; app moved to /Applications/AxisCopilot.app at owner request, launch and system-audio discovery pass; incorporated into owner-approved 0.2.0 private-branch publication

### SC-004 Meeting playback, speakers and local updates 0.2.0

- Owner/Agent: Codex
- Source: owner approved meeting mockup and design with «да ок», 2026-11-02
- Scope: player controls, seven playback rates, phrase following/search, local postmeeting voice groups and manual names, persistent signing, signed local alpha updates, Apple Silicon bundle
- Handoff: ready_for_review
- Publication: reviewed candidate 5a3e7e1 pushed to private codex/recording-prototype; PR https://github.com/BlackWizlock/sales-copilot/pull/1 remains open, not merged
- Validation: full ci-local passed in isolated candidate checkout; real native muted playback passed all seven rates; bundled three-voice 60.86-second fixture produced three recurring groups; updater rejection and rollback fixtures passed
- Native acceptance: build 5 installed through signed updater from build 4; final layout, phrase seek/highlight, search, speaker rename and manual phrase assignment verified on synthetic history; final isolated ci-local and employee bundle PASS
- Permissions: owner refreshed bootstrap permission for build 4; after updater installed build 5, fresh system-audio discovery populated application picker without another permission change. This proves that transition for system-audio discovery, not microphone capture retention or all future macOS releases
- Update race: CUA automatically reopened app during helper replacement, briefly leaving old/new idle processes; old instance quit through UI. Single-instance protection remains a hardening item; no capture or client meeting edited
- Gate: player/speaker Jev safe_to_apply 0.28 and updater 0.23 escalated, no contradicted claims; stronger independent reasoner reviewed final source/logs and supports private-branch publication and owner-review alpha, no blocking defect. Owner explicitly authorized commit and push despite these scores on 2026-11-02. Exception applies to the reviewed candidate and private working branch; no merge or employee distribution clearance
- Limits: synthetic voices do not establish meeting accuracy or reliable overlap detection; same signing requirement does not establish retained TCC permission; physical echo/double-talk, real-meeting speakers and installation on a second Mac still require acceptance
