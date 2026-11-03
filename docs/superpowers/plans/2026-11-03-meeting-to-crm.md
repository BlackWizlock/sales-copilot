# Meeting to CRM Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Improve faithful meeting notes and complete the approved meeting, automatic hints and Bitrix export workflow.

**Architecture:** Keep SwiftUI, CopilotCore and fixed-loopback Ollama. Extract evidence-bound facts per transcript batch and audit each fact against its own exact source locally; combine validated facts deterministically, without another unconstrained summary. Preserve old archives. Export remains an explicit reviewed operation with a private reconciliation journal.

**Tech Stack:** Swift, SwiftUI, Ollama, Bitrix REST, existing ASR.

**Spec:** docs/superpowers/specs/2026-11-02-sales-copilot-design.md and owner instruction03.11.2026.

## Global Constraints
- No paid API or cloud transmission of client materials.
- No automatic CRM deal field or stage changes.
- Use a synthetic meeting and owner-selected test deal for live writes.
- Preserve original transcript and prior summary on failure.

## Review Focus
- Unrelated real citation must not license a fabricated decision.
- A suggestion, question or conditional offer must not become an agreement.
- Owner and deadline require explicit evidence; never infer speaker identity.
- Failed or partial model audit must not silently authorize claims.
- Audio, summary and transcript must reach the same selected deal, without duplicate retries.

### Task1 Grounded summary
Files: Sources/CopilotCore/GroundedMeetingNotes.swift; Sources/AxisCopilot/LocalIntelligence.swift; Sources/AxisCopilot/GroundedSummaryGenerator.swift; Tests/Integration/LocalGenerationChecks.swift; scripts/check-local-intelligence.sh.
Interface: GroundedMeetingNotes validated against [TranscriptLine], locally audited facts; generator produces MeetingSummary.
- [x] Add and run regression showing fabricated decision with unrelated citation is accepted.
- [x] Implement per-fact exact citations, local entailment/speech-act audit, deterministic combination and bounded recovery.
- [x] Exercise source mismatch, omitted audit entries, invented owners/dates and proposal classification; run full CI.
- [ ] Run actual local model on synthetic meeting and PR; inspect output locally without publishing client text.

### Task2 Hints and Bitrix workflow
Files: LocalIntelligence.swift, CRMController.swift, BitrixClient.swift, CRMPanel.swift, Tests/BitrixIntegration and Tests/Integration.
Interfaces: existing suggest(), prepareExport, confirmExport and CRMExport journal.
- [x] Test automatic hint from synthetic objection and deal/material context using injected inference runtime.
- [x] Verify real audio and transcript payload, confirmed remote result and duplicate prevention; fix failures found.
- [ ] Install signed candidate, execute native synthetic workflow, send only to owner-selected test deal, read back activity and attachments.

### Task3 Remaining acceptance and release
Files: STATUS.md, docs/TESTING.md, existing release scripts and remaining PRD owners.
- [ ] Keep complete43-row registry; work through unverified cases without inventing live evidence.
- [ ] Independent whole-change review, clean-checkout CI, signed install/update, public alpha publication and HTTPS hash verification.
- [ ] Record external dependencies accurately (second Mac, actual meeting participants, Developer ID/portal app registration) and continue all independent implementation.

## Execution ledger
- Native execution authorized by owner; no repeat design approval for already approved requirements.
- Current branch b93342c, clean before test edit.
- Root cause: global citations unrelated to individual claims; recursive generative merging can amplify unsupported commitments.

- Task1: fabricated-decision regression RED and GREEN; exact-quote audit and two-fact incomplete audit RED and GREEN. Original summary is preserved on failed audit. Real local synthetic model passes proposal/negation test.
- Task2: attachment content replacement regression RED and GREEN. Preview audio assembly is automatic; export text uses assigned names and dedup. Full CI after reviewer fixes exit0; two-source actual ASR/M4A1.16s for19.04s synthetic archive.
- Final review: no Critical; P1 attachment identity and P2 audit source breadth fixed with failing regressions. Partial audit is treated as Important because silent coverage loss harms summary usefulness, and was fixed with a two-fact regression. Standards updated. No deferred findings.
- Real local ten-objection rerun passed: p50=1.461s, p95=5.189s from ready transcript, excluding live ASR.

- Completion gate Jev: safe_to_apply0.30/composite0.687, all3 claims verified but confidence0.66–0.74; escalated. Stronger lead adjudication: direct source review plus actual exit0 logs establish synthetic contracts, not real CRM/participant/second-Mac acceptance. No contradicted claim or concrete remaining blocker to reversible alpha install/working-branch commit. Native acceptance and clean checkout still required before public channel.

## Summary quality continuation03.11

Owner requested completion without further planning questions. Continue within approved local summary scope.

Observed: Qwen2.5 7B, Qwen3.5 9B and Qwen3 14B all lose concrete commitments in PR; a single six-item list is crowded with near-identical topics. Qwen3 14B passes synthetic numerical/negation checks but gives18 topics and no actions in PR (281s); it is not promoted. Original PR remains unchanged locally.

Architecture adjustment: one structured extraction response has separate commitment and topic arrays. Commitments come first and contain actions, decisions and open questions; the other array contains topics. Each section is bounded to3 entries per batch. Both arrays are required even when empty. Existing independent per-fact audits and deterministic source/number/owner/deadline checks remain. No freeform final rewrite or cloud request. A failed response preserves the complete previous summary.

Files: GroundedSummaryGenerator.swift owns the split schema/prompt and validates category boundaries; GroundedMeetingNotes.swift exposes construction of the indexed draft and distinguishes current first-person promises from reported past; LocalGenerationChecks.swift verifies required sections, category mismatch, both facts and old-summary preservation. IntelligenceSettings.swift disables thinking while retaining structured format so compatible thinking models use the response budget for the actual result.

- [x] Reproduce current-promise rejection and reported-past false positive; fix with focused regressions.
- [x] Reproduce missing think=false; verify supported local models and preserve format.
- [x] RED split commitments/topics contract; implement bounded split extraction and preserve independent audit.
- [ ] Run actual synthetic workflow, inspect PR copy, then assess whether topic consolidation is still needed. No automatic promotion of a larger model.
- [ ] Review, full clean CI, signed candidate installation and native CRM acceptance.

### Audited commitment metadata20

Actual synthetic7B workflow retained a decision as an action and omitted the explicit deadline field, despite including Friday in the task text. Cause: audit could only downgrade to topic, and checked unsupported metadata without filling missing explicit metadata. Fix within the approved scope: audit each already proposed commitment against its own source, returning corrected category and literal owner/deadline; Core allows action/decision correction only within that family, forbids topic/question promotion, and requires explicit mutual agreement for a decision. Exact short acceptance with its proposal remains valid. Owner/deadline must occur literally in the same cited evidence. No source text or fact is invented.

- [x] RED action-to-decision correction and explicit owner/deadline recovery in CoreChecks.
- [x] GREEN CoreChecks with topic-promotion, invented metadata and personal-promise negative controls.
- [x] Preserve exact short acceptance and all injected runtime contracts.
- [x] Real local Qwen3:8b workflow with required structured metadata: all10 automatic hints, fragmented ASR price/duration, explicit decision, Anna action/Friday, negation, citations and reload passed (.build/workflow8-final20.log, exit0).
- [ ] Independent review, real PR-copy inspection and full clean CI before installation.

Exact-source coverage20: short literal agreement candidates are added to model facts and independently audited. No candidate is removed because another fact uses its source. RED/GREEN covers action loss from a shared quote, weekday grammar, unrelated-clause dates and prefix deduplication. Missing/nonliteral deadline recovery projects only a single weekday from already validated action text, with an exact source match. Core and injected runtime final checks pass; independent review found no Critical/Important. PR-copy quality and native candidate remain pending.

## Изменение маршрута генерации03.11.2026

Владелец запретил несанкционированный запуск тяжёлой локальной Qwen и потребовал OpenRouter для задач. Локальное ASR остаётся. Новая реализация убирает Ollama из runtime и комплекта, подключает общий маршрут резюме/чата/подсказок к пользовательским ключу, модели и дневному бюджету. Реальные клиентские материалы не используются в платных проверках. Предыдущие локальные замеры остаются историческими и не закрывают качество новой модели. Полный workflow24 остаётся открытым до фактической проверки выбранного пользователем backend.
