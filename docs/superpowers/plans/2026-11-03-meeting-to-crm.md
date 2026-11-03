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

### Task1: Grounded summary
Files: Sources/CopilotCore/GroundedMeetingNotes.swift; Sources/AxisCopilot/LocalIntelligence.swift; Sources/AxisCopilot/GroundedSummaryGenerator.swift; Tests/Integration/LocalGenerationChecks.swift; scripts/check-local-intelligence.sh.
Interface: GroundedMeetingNotes validated against [TranscriptLine], locally audited facts; generator produces MeetingSummary.
- [x] Add and run regression showing fabricated decision with unrelated citation is accepted.
- [x] Implement per-fact exact citations, local entailment/speech-act audit, deterministic combination and bounded recovery.
- [x] Exercise source mismatch, omitted audit entries, invented owners/dates and proposal classification; run full CI.
- [ ] Run actual local model on synthetic meeting and PR; inspect output locally without publishing client text.

### Task2: Hints and Bitrix workflow
Files: LocalIntelligence.swift, CRMController.swift, BitrixClient.swift, CRMPanel.swift, Tests/BitrixIntegration and Tests/Integration.
Interfaces: existing suggest(), prepareExport, confirmExport and CRMExport journal.
- [x] Test automatic hint from synthetic objection and deal/material context using injected inference runtime.
- [x] Verify real audio and transcript payload, confirmed remote result and duplicate prevention; fix failures found.
- [ ] Install signed candidate, execute native synthetic workflow, send only to owner-selected test deal, read back activity and attachments.

### Task3: Remaining acceptance and release
Files: STATUS.md, docs/TESTING.md, existing release scripts and remaining PRD owners.
- [ ] Keep complete40-row registry; work through unverified cases without inventing live evidence.
- [ ] Independent whole-change review, clean-checkout CI, signed install/update, public alpha publication and HTTPS hash verification.
- [ ] Record external dependencies accurately (second Mac, actual meeting participants, Developer ID/portal app registration) and continue all independent implementation.

## Execution ledger
- Native execution authorized by owner; no repeat design approval for already approved requirements.
- Current branch b93342c, clean before test edit.
- Root cause: global citations unrelated to individual claims; recursive generative merging can amplify unsupported commitments.

- Task1: fabricated-decision regression RED→GREEN; exact-quote audit and two-fact incomplete audit RED→GREEN. Original summary is preserved on failed audit. Real local synthetic model passes proposal/negation test.
- Task2: attachment content replacement regression RED→GREEN. Preview audio assembly is automatic; export text uses assigned names and dedup. Full CI after reviewer fixes exit0; two-source actual ASR/M4A1.16s for19.04s synthetic archive.
- Final review: no Critical; P1 attachment identity and P2 audit source breadth fixed with failing regressions. Partial audit is treated as Important because silent coverage loss harms summary usefulness, and was fixed with a two-fact regression. Standards updated. No deferred findings.
- Real local ten-objection rerun passed: p50=1.461s, p95=5.189s from ready transcript, excluding live ASR.

- Completion gate Jev: safe_to_apply0.30/composite0.687, all3 claims verified but confidence0.66–0.74; escalated. Stronger lead adjudication: direct source review plus actual exit0 logs establish synthetic contracts, not real CRM/participant/second-Mac acceptance. No contradicted claim or concrete remaining blocker to reversible alpha install/working-branch commit. Native acceptance and clean checkout still required before public channel.
