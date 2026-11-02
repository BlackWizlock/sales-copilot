# STATUS

## Active

### SC-001 Создание проекта и описание прототипа

- Owner/Agent: Codex
- Source: user request 2026-11-02; confirmed project parameters
- Scope: project scaffold, repository, HQ registration, design document
- Handoff: ready_for_review
- Status: приватный репозиторий создан; локальный каркас и описание готовы к согласованию; первый коммит остановлен Jev
- Design: docs/superpowers/specs/2026-11-02-sales-copilot-design.md
- Review: independent builder check found nothing important left; first slice A clearly separated
- Validation: frontmatter_validate OK 74 projects; resolver identifies sales-copilot with 3 required standards; instruction_sync checked=1 conflicts=0; gitleaks staged found no leaks
- Pending: approve design; resolve Jev escalation before commit; publish initial structure; attach HQ submodule and complete registration in root CLAUDE.md

### SC-002 Локальная запись и транскрипция

- Owner/Agent: Codex
- Source: user request 2026-11-02
- Scope: macOS app, audio capture, recording, Russian transcription
- Handoff: owned
- Status: pending SC-001 and design approval; product code has not started

### SC-003 Автоматический суфлёр и интеграции

- Owner/Agent: Codex
- Source: user request 2026-11-02
- Scope: proposal grounding, live suggestions, Bitrix24 calendar/deal, MCP, optional OpenRouter, CRM recording export
- Handoff: owned
- Status: pending SC-002

## Review Gates

1. Initial staged documentation review via jev_review: safe_to_apply=0.38, correctness confidence=0.15, action=escalate. No commit or push performed. No specific defect was returned. User decision required by canonical Jev usage; do not retry the same patch to seek approval.
2. Full product design requires approval before implementation under brainstorming protocol. User confirmed project parameters, not this written design.

## Known Risks

1. Захват двух источников, разрешения macOS, работа с Granola и задержка моделей не проверены.
2. Доступ приложения и подписка REST/Маркетплейс на портале Битрикс24 не проверены; инструмент bitrix24-axis отсутствует в текущем каталоге сессии.
3. Нет подтверждения, что загруженная внешняя встреча автоматически запускает встроенный разбор Битрикс24.
4. Полного Xcode нет; Command Line Tools и SDK есть. Пригодность для сборки .app предстоит проверить.
5. Замена Granola возможна только после проверки основных сценариев; миграция старых встреч пока не включена.
6. Удалённый репозиторий пока пуст; локальный проект ещё не присоединён как подмодуль. Штабной реестр пересобран и видит проект; регистрация не считается завершённой.
7. Shell-алиасы не добавлены; создание окружения и зависимостей отложено до реализации.
