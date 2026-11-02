# STATUS

updated: 2026-11-02

## Сейчас в работе

### SC-002 Локальная запись и транскрипция

- Owner/Agent: Codex
- Source: user approval 2026-11-02, written design and initial commit approved, implementation requested
- Scope: native macOS app, microphone/app audio capture, WAV and M4A, local Russian transcription
- Handoff: owned
- Branch: codex/recording-prototype
- Status: implementation built, 10 core checks and synthetic real-whisper pipeline passed; live QuickTime + microphone capture, in-recording transcription, M4A and restart history verified; portable Apple Silicon bundle with embedded model/backend passed synthetic inference; brand header and product credits added
- Review: independent reviewer confirmed 4 Important failure-path findings fixed; no new Critical/Important findings. Successful chunks now synchronously drained before export on stop error.
- Design: docs/superpowers/specs/2026-11-02-sales-copilot-design.md
- Plan: docs/superpowers/plans/2026-11-02-recording-transcription.md
- Validation: docs/TESTING.md
- Next: commit, clean-checkout validation and publish for cross-review; owner explicitly approved proceeding despite feature Jev escalation on 2026-11-02; no merge without other lead review

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
2. Product feature Jev gate escalated: safe_to_apply=0.23, composite=0.6628, low confidence on test_gap, no concrete defect specified. Both verification claims (10 core checks and bundled synthetic inference) confirmed with confidence=1.0. Owner explicitly approved commit and push despite this escalation on 2026-11-02 (reply to the specific exception request: «да, поехали»). This is separate from the initial documentation exception. A fresh export of staged source passed ci-local.sh; committed clean-checkout validation follows the implementation commit.
3. Cross-review from other lead required before merge.

## Known Risks

1. Zoom, Telemost, Granola coexistence, headphones and long meeting still require live acceptance.
2. Bitrix24 REST availability, CRM attachment and native analysis not verified; no Bitrix integration in this slice.
3. Local ad-hoc signing may require permission renewal after rebuild. No notarization or automatic updates.
4. Small local model can misrecognize names/numbers; 8-second chunks can split phrases. No measured live p95.
5. Audio not yet flushed from RAM can be lost in a crash. Persisted WAVs remain even if transcription/export fails.
6. MCP and OpenRouter are absent; confidential materials must not be sent to cloud providers.
