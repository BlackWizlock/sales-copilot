# STATUS

updated: 2026-11-03

## Полный перечень PRD и запросов сессии

- Owner/Agent: Codex
- Source: [продуктовое описание](docs/superpowers/specs/2026-11-02-sales-copilot-design.md), [интерфейсный PRD](docs/superpowers/specs/2026-11-02-interface-prd.md), запросы владельца в текущей переписке 02.11.2026
- Scope: весь согласованный прототип, исправления и выпуск альфа-версии; без слияния PR
- Handoff: owned
- Branch: codex/recording-prototype

«Проверено» означает указанный вид проверки. Наличие кода не означает приёмку на живой встрече. Ни один открытый пункт не считается выполненным из-за выпуска новой сборки.

| ID | Требование | Фактическое состояние | Следующее доказательство или действие |
| --- | --- | --- | --- |
| 01 | Запись микрофона и звука приложения, M4A | Реализовано; установленная сборка9 записала оба потока, issues=[] | Живой Zoom и Телемост |
| 02 | Устранение ошибки старта -10875 | Исправлено; клиентские частоты совпадают; реальный старт9 прошёл | Регрессия при смене устройства |
| 03 | Эхоподавление новой записи | VoiceProcessingIO, защита от воспроизведения, раздельные источники | Живой разговор через динамики и одновременная речь |
| 04 | Усиленная очистка старой записи PR | Создана отдельная meeting.echo-reduced.m4a, оригинал сохранён;10 синтетических проверок | Прослушивание и сравнение; выбор версии добавлен в плеер11 |
| 05 | Локальная русская транскрипция и восстановление | Реализовано; CoreChecks и синтетическое реальное ASR/M4A проходили | Чистый checkout8788d97 прошёл полный CI11 с локальным SwiftPM mirror FluidAudio |
| 06 | Удаление дублей слов и фраз | Обратимое представление без удаления исходников, проверки ядра | Оценка на реальном разговоре |
| 07 | Голоса, ручные имена, привязка фраз | Локальная итоговая группировка и ручные поправки; синтетические3 голоса | Точность трёх участников реальной встречи |
| 08 | Плеер и скорость0,5–2×, поиск, фразы | Реализовано; нативно проверены семь скоростей и переходы | Регрессия финальной сборки |
| 09 | Плавающий значок, уровни, управление | Реализовано; синтетические проверки жизненного цикла | Полноэкранный созвон и два языка |
| 10 | Поддержка любых документов как материалов | Текст/PDF/Office/изображения/OCR; несколько файлов;14 проверок | Финальный CI; схемы и формулы не интерпретируются |
| 11 | Видимая зона перетаскивания и удаление файлов | Реализовано; нативно проверены два документа и независимое удаление | Регрессия финальной сборки |
| 12 | Автоматические подсказки по репликам клиента |10 синтетических возражений настоящей локальной модели прошли; p50=1,461с/p95=5,189с от готового текста | Задержка с живым ASR и оценка полезности на созвоне |
| 13 | Структурированное резюме с цитатами и правками |16 сохраняет цену и срок в разорванном ASR; нативно обнаружена бессвязная тема. Кандидат17 добавляет meaningful и сохраняет цитаты повторов/разные поручения; RED и GREEN контрактов прошли | Реальная PR с Qwen2.5 всё ещё искажает смысл; проверяется более сильная локальная модель без облака |
| 14 | Отдельный чат по встрече |16 нативно ответил про100тыс. и4недели с точными ссылками на две реплики; история восстановилась после переключения встреч | Повторный запуск и регрессия финальной сборки |
| 15 | Удобные настройки, отмена, закрытие, навигация | Отдельное окно с категориями и явным сохранением секретов/путей | Малая ширина, клавиатура, оба языка |
| 16 | Личный Битрикс24, очистка поля, права, удаление ключа | Реализовано; Keychain CRUD и подключение владельца проверены | Отсутствие автоматических запросов после обновления |
| 17 | Поиск сделки по названию и сохранение привязки | Реализовано; синтетические интеграции и изоляция порталов | Нативная регрессия |
| 18 | Месячная сетка и свойства дня | Реализовано; реальные39 событий, ноябрь2=2 и ноябрь5=1; sheet9 проверен | Форматирование и редактор10 |
| 19 | Читаемое описание, списки, активные ссылки | Установлено11; нативная синтетическая проверка абзацев, списков, ссылок прошла | Реальные описания сложной структуры |
| 20 | Карточка названия сделки и клиента вместо номера | Установлено11; нативно видны название сделки, клиент и пояснение подготовки | Живая CRM-регрессия после явной разблокировки |
| 21 | Редактор описания с сохранением в Битрикс24 | Реализован10; синтетически проверены конфликт, точный состав полей, одна дата серии, read-back, отсутствие повторной записи | Нативно проверены выделение/предпросмотр/отмена; реальная запись по выбранной владельцем правке |
| 22 | Открытие Zoom/Телемоста из события | Проверенные HTTPS-ссылки реализованы; открытие не начинает запись | Живое открытие в установленном клиенте; бот-участник вне первого прототипа |
| 23 | Запуск подготовки непосредственно из карточки сделки | Безопасный axis-copilot://deal реализован, проверены отмена/портал/занятость; виджет не зарегистрирован | Нативная доставка ссылки; регистрация CRM-вкладки отдельным приложением |
| 24 | Экспорт встречи с аудио, текстом, итогами в сделку |17: production controller/client сверили реальное тестовое дело2472 в сделке504, два файла по SHA-256, journal completed, повтор creates0. Исправлен browser HTML вместо аудио через disk.file.get; нужны crm+disk | Нативная отправка новой синтетической встречи после установки17; запись/подсказки с живым ASR отдельно |
| 25 | Штатный разбор записи в Битрикс24 | Не реализован путь внешнего звонка; обычное дело не запускает CoPilot | Проверить OAuth/тариф/методы и безопасный полный цикл |
| 26 | MCP шесть инструментов и доступ по встречам | Установленный11: initialize, шесть инструментов, ping, EOF; UI подключения проверен | Разрешение встреч остаётся явным; фильтры/аудит проверены синтетически |
| 27 | Каталог ASR как в VoiceInk | Whisper small/medium/turbo, Parakeet; явная загрузка/выбор/проверка | Регрессия загрузки/отмены в финальной сборке |
| 28 | OpenRouter как опция и ключ в настройках | Изолированная песочница, каталог/бюджет/Keychain; клиентские данные не передаются | Платный тест не выполняется без отдельного разрешения |
| 29 | Русские и английские локали | 553 ключа RU/EN,46 шаблонов; runtime и нативное English/system прошли | Системные ошибки и updater сохраняют исходный язык |
| 30 | English name, иконка, фирменные полосы | Axis Copilot; ICNS; ссылки активных продуктов без Model | Нативная регрессия |
| 31 | Обновления без фоновых запросов пароля | Сборка10 открывала диалог;11 запрещает взаимодействие синхронно, тест чужого ACL прошёл | Нативный запуск11 и настройки без диалога прошли; ключ закрыт до явной разблокировки; Team ID требует Developer ID |
| 32 | Единый сервер обновлений для всех установок | HTTPS latest.json опубликован:0.3.1(11), arm64,563856154 байта и SHA256; установленная11 сообщает актуальную совместимую версию | Полный HTTPS GET завершён, размер/SHA256 совпали; второй Mac и обновление с предыдущей версии открыты |
| 33 | Комплект сотрудника Apple Silicon | Переносимая сборка9 есть, без личных ключей | Комплект11 собран и реальное bundled ASR/M4A прошло; второй Mac не проверен |
| 34 | Понятный pipeline major/minor/patch, VPS, стек | docs/DEVELOPMENT.md и docs/UPDATES.md реализованы | Проверить инструкцию чистой сборкой и публикацией |
| 35 | Публичный GitHub, описание, лицензия, сохранность переменных | Репозиторий PUBLIC; MIT/README/SECURITY в опубликованной ветке8788d97; gitleaks7 коммитов без утечек | PR1 открыт, main не обновлён; независимая проверка перед слиянием |
| 36 | Полный чистый CI и независимое ревью | Полный CI11 прошёл в чистом checkout8788d97; FluidAudio через нативный SwiftPM mirror на закреплённой ревизии, исходники/lock без изменений;3 P2 исправлены | Jev0,21 исключение владельца выполнено; перекрёстное ревью требуется перед merge |
| 37 | Удаление встречи и всех локальных производных | Реализованы подтверждение, удаление локальных производных и отзыв MCP; CoreChecks прошёл | Нативная регрессия; удалённая CRM сохраняется |
| 38 | MCP фильтры по периоду/сделке и журнал выдачи без текста | Фильтры дат/сделки и ограниченный журнал без текста реализованы; stdio/CoreChecks прошли | Полный CI11; отказ выдачи при недоступном журнале |
| 39 | Совместная работа с Granola | Не подтверждена | Живой сравнительный запуск и замер нагрузки |
| 40 | Перекрёстная проверка и слияние | PR1 открыт; слияние не выполнялось | Другой ведущий агент перед merge; текущий scope без merge |
| 41 | Компактная панель, видимая сделка, сортировка, даты и папки |16 нативно показала название сделки и выбранную строку; фильтр по названию сохраняет привязку. Папки/перенос/сортировка проверены ранее и сохранены после обновления | Принято на этом Mac; второй Mac отдельный пункт33 |
| 42 | Использование конспекта Телемоста | Официальные источники изучены: полная расшифровка приходит вложением на почту до24ч; публичный GET транскрипции не найден; API и справка противоречат по автостарту | Тариф/домен аккаунта и реальный формат вложения пока не проверены; импорт не реализован |

Текущая работа: установлена0.3.6(16), кандидат0.3.7(17) прошёл полный CI и дополнительные CRM-регрессии. Нативный16 подключён к Битрикс24 и привязал свежую синтетическую встречу к504. Кандидат17 успешно сверил реальное тестовое дело2472: транскрипция и аудио совпали по SHA-256, journal completed, повтор creates0. Исправлены машинное скачивание через Диск и возможный crash при неполном FILES. Jev17 safe_to_apply0.33, test_gapconfidence0.07, один claim exit-code unsupported по текстовым логам; выполнен запрос усиленного ревью фактических логов/кодов возврата. Подготовка обратимой установки17 и нативного экспорта продолжается. Реальная PR не принята по качеству, модель по умолчанию не менялась. Публичный канал11; системные права не сбрасывались.

## Очередь текущей сессии

Полная очередь в нативном плане Codex содержит все42 ID из таблицы выше. Открытые проверки сохраняются отдельными задачами; наличие реализации не закрывает их автоматически.

1. **24, в работе:** полный экспорт синтетической встречи в сделку504 с аудио, текстом и резюме; сверка серверного дела, вложений и отсутствия дубля.
2. **13:** качество и полнота резюме. Независимый аудит каждого факта сохраняет цену и срок в синтетическом ASR, meaningful отсекает бессвязные фразы; обязательность verdict и частичное принятие проверены. Реальная PR остаётся недостаточной по смыслу/полноте; Qwen3.5:9b не прошла проверку суммы и structured output. Продолжить улучшение локальной обработки без облака.
3. **41, принято на этом Mac:** видимое название сделки, выбранная строка, папки и сортировка проверены нативно после16. Второй Mac отдельный пункт33.
4. **12:** связать автоматические подсказки с живым ASR и измерить задержку от речи.
5. **01–11,14–23,25–40,42:** оставшиеся проверки и реализация строго по каждому отдельному ID таблицы и нативного плана. Ни один пункт не снимается выпуском сборки.

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

### SC-011a Чистая сборка11, публичная ветка и канал обновлений

- Owner/Agent: Codex
- Source: исключение владельца для Jev0,21; commit8788d97, codex/recording-prototype, PR1
- Scope: чистая сборка, проверка истории, push, публичность исходников и публикация канала11
- Handoff: closed
- Status: полный ci-local прошёл в чистом checkout8788d97; gitleaks7 коммитов без утечек; origin совпадает с HEAD, репозиторий PUBLIC, PR1 OPEN без слияния. HTTPS latest.json и полный ZIP прочитаны, размер563856154 и SHA256 совпали; установленная11 показала последнюю совместимую версию.
- Verification: live gh и git, .build/ci-clean11-mirror.log, .build/gitleaks-public11.log; Jev verify3/3 verified. Живое резюме, качество встречи, CRM-запись и второй Mac этим не приняты.


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
- Status: implementation in progress, candidate 0.3.1(11); local inference/summary, proposal/deal retrieval, CRM/calendar, stdio MCP, optional isolated OpenRouter sandbox and ASR catalog implemented; full worktree CI and portable build passed; clean-checkout CI8788d97 passed; public branch pushed; native summary format error and live acceptance remain open
- UI correction: build7 installed through signed updater with restored history and Bitrix connection. Build8 adds a visible multi-document drop zone above tabs, per-file removal, client-audio automatic hints in main view and floating HUD, and correct recurring calendar dates. Build8 installed by signed helper. Native sheet import of two synthetic documents, independent removal, and updater sheet open/cancel verified through CUA.
- CRM: synthetic full deal selection and binding, restoration/new-record inheritance, historical isolation, timeout/reconciliation/no duplicate creation verified; delayed A export/reconcile cannot replace B result. Owner personal connection restored in installed build7; live read-only calendar returned 39 events. Native CUA observation on build8: November2=2 events, November5=1 event; these are manual live observations, not CI assertions. Fixed recurring occurrence dates and stable UI identities; real write has not been tested.
- Local AI: production-controller synthetic Qwen checks produced structured summary in 4.60 s and cited meeting answer in 1.77 s; switch/fingerprint cancellation and private chat reload verified. Timings exclude ASR and do not establish live meeting latency.
- Source review: independent source reviews found no confirmed P1/P2; final other-lead review supports owner alpha/private branch, not merge or employee acceptance. Jev safe_to_apply=0.20/composite=0.574 escalated for low confidence and two unsupported claims (zero contradicted); stronger reasoner inspected source/tests/logs and supports private candidate with explicit manual UI evidence.
- Release: central HTTPS latest.json publishes0.3.1(11); complete HTTPS archive download and SHA256 verified. Public visibility confirmed after seven-commit gitleaks scan; branch8788d97 pushed, PR1 open and unmerged. Latest publication evidence is in SC-011 below.

## Review Gates

1. Initial documentation Jev escalation safe_to_apply=0.38, correctness confidence=0.15 was explicitly overridden by user approval of description and initial commit. Initial commit 171b734 pushed.
2. Product feature Jev gate escalated: safe_to_apply=0.23, composite=0.6628, low confidence on test_gap, no concrete defect specified. Both verification claims (10 core checks and bundled synthetic inference) confirmed with confidence=1.0. Owner explicitly approved commit and push despite this escalation on 2026-11-02 (reply to the specific exception request: «да, поехали»). This is separate from the initial documentation exception. Implementation commit 83ba8f8 passed ci-local.sh in a fresh clean clone.
3. Cross-review from other lead required before merge.

## Known Risks

1. Zoom, Telemost, Granola coexistence, headphones and long meeting still require live acceptance.
2. Bitrix24 personal connection and calendar reading verified; real CRM attachment/write not accepted; native Bitrix meeting analysis remains unconfirmed. Synthetic integration checks are available.
3. Permanent signing and central update client implemented. Installed build 5→6 retained system-audio discovery without renewed access; actual capture/all future releases not proven. Central host configured; current publication evidence is in SC-011 below; no Apple notarization.
4. Small local model can misrecognize names/numbers; 8-second chunks can split phrases. No measured live p95.
5. Audio not yet flushed from RAM can be lost in a crash. Persisted WAVs remain even if transcription/export fails.
6. MCP is opt-in per meeting and read-only. OpenRouter is a separate synthetic/public sandbox; confidential materials must not be sent there. Full dynamic UI/error translation remains incomplete.

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

### Build8 native capture acceptance

- Owner/Agent: Codex
- Source: post-update native smoke check
- Scope: microphone permission and recording startup
- Handoff: owned
- Status: owner granted microphone access. Build8 start failed twice with -10875. CoreAudio explicitly reported mismatched input/output client formats; physical microphone48kHz/output44.1kHz. Standalone regression failed 48000/44100, then passed 48000/48000 after explicit mixer/output rate alignment. Build9 native acceptance passed: completed FF4A37EE-D07A-483D-BAA4-E7C86954FB62, three microphone and three meeting chunks, issues=[], M4A saved; no TCC reset or system device change. Central release remains unpublished.

### Calendar day properties

- Owner/Agent: Codex
- Source: owner asks for properties window when selecting a day
- Scope: day sheet containing event title, dates, location, description, verified meeting link and linked-deal action; Close/Escape; no calendar writes
- Handoff: owned
- Status: implemented in installed9, native day sheet acceptance passed; formatting and explicit description editor candidate10 pending


### SC-011 Проверенный кандидат и публикация ветки11

- Owner/Agent: Codex
- Source: полная матрица40 требований выше и поручение завершить функции
- Scope: кандидат0.3.1(11), MCP, редактор календаря, локали, тихий Keychain, удаление, отдельная аудиокопия PR, обновления
- Handoff: ready_for_review
- Status: установлен11 через прежний подписанный helper, результат success; Previous.app10 сохранён. История на месте. Новые разрешения TCC не запрашивались; сохранение захвата этим не доказано.
- Publication: commit8788d978d5eabfb5aee1ec35939a0e40674a71b8 опубликован в codex/recording-prototype, PR1 открыт, не слит; репозиторий PUBLIC. MIT/README/SECURITY доступны в ветке; main не обновлён. gitleaks проверил7 коммитов без утечек.
- Clean checkout: verify-build11 на8788d97, tracked tree чистое, ci-local exit0 (.build/ci-clean11-mirror.log). FluidAudio получен нативным SwiftPM mirror на исходную закреплённую ревизию9830ce835881c0d0d40f90aabfaae3a6da5bebfb; Package.resolved и исходники не менялись.
- Validation: финальный worktree ci-local exit0; package-employee exit0; установленный MCP initialize/list/ping/EOF exit0;523 RU/EN ключа и42 шаблона; native calendar/editor bold-preview-cancel; English/system переключение; обычный запуск и Bitrix settings без SecurityAgent. Подключение закрыто macOS до явного пользовательского действия; ключ не удалён.
- Release: локальный AxisCopilot-11-arm64.zip, size563856154, SHA256 f54c3236adc7762828ca7f79f834b7735e4a39f3f96d0c08826610aebc9d022d. HTTPS latest.json опубликован и прочитан: версия0.3.1, build11, arm64, size/SHA совпадают с локальным архивом; полный HTTPS GET ZIP выполнен ведущим агентом потоком curl | shasum (session32032, exit0), SHA256 совпал. Content-Length HTTPS и серверный размер563856154 совпали с локальным архивом. Установленная11 сообщает актуальную совместимую версию.
- Publisher fix: реальный запуск выявил неверную передачу необязательного prefix для codesign --extract-certificates; раздельная форма exit1, форма с равенством exit0. Обе проверки сертификата исправлены, полная подготовка ZIP/JSON завершилась exit0.
- Gate: Jev final delta safe_to_apply0.21, composite0.645, correctness confidence0.07, все3 утверждения проверок verified. Конкретного дефекта не указано. Stronger review поддерживает только обратимую локальную установку11 с копией10, не commit/push или центральную публикацию. Владелец явно разрешил исключение для коммита11 при успешном чистом CI перед push/публичностью/каналом. Условие выполнено; commit/push и публичность проверены. Исключение не разрешает слияние или закрытие внешней приёмки.
- Native issue: установленная11 при генерации резюме записи PR показывает общую ошибку формата данных; причина ещё проверяется, синтетический тест не закрывает этот сценарий.
- External pending: OAuth-приложение/права/тариф для штатного анализа Битрикс24, зарегистрированный CRM-виджет, конкретная живая тестовая запись, Zoom/Телемост/Granola совместно, качество эха и участников, второй Mac. Без этих проверок весь PRD не закрыт.

Владелец явно разрешил исключение Jev0.21 для коммита сборки11. После коммита чистый checkout CI прошёл; push и публичность подтверждены, центральный канал подтверждён HTTPS GET манифеста и полного архива с совпавшим SHA256. Слияние не разрешено. Блокировка на этом исключении снята; внешние сценарии остаются открытыми.


### SC-012 Обработка резюме и наблюдаемый прогресс

- Owner/Agent: Codex
- Source: сообщение владельца о бесконечном индикаторе «Резюме»,02.11.2026
- Scope: проверка завершённости ответа локальной модели, одна повторная попытка неверного JSON, понятная ошибка, сохранение прежнего результата, этапы/таймер/отмена
- Handoff: owned
- Commit:71b37e7, рабочая ветка codex/recording-prototype; без merge
- Verification: полный worktree CI12 и переносимая упаковка прошли; нативное обновление11 на12 выполнено без пароля, видны этап/таймер, отмена активной генерации и повторный запуск проверены. Полный CI чистого checkout71b37e7 прошёл, exit0; реальное синтетическое распознавание1,41с, M4A19,04с.
- Review: Jev safe_to_apply0.46, composite0.6935, test_gap confidence0.42; усиленное независимое ревью не выявило P1/P2 и поддержало фиксацию кандидата с открытой нативной приёмкой. Исключение владельца для11 к12 не применялось.
- Open: Mac заблокировался во время повторного разбора PR; результат полного прохода в UI не подтверждён. Общий канал остаётся на11 до этой приёмки и чистого CI. Исходный ответ сбойной11 не сохранён, точная причина не доказана.

Проверка16 и кандидат17 03.11.2026. Штатный updater установил16 с резервной15. Владелец подтвердил Keychain, нативно подключены сделки и привязана свежая синтетическая встреча. Плеер и чат проверены. Реальный тест REST выявил browser HTML по FILES.url; кандидат17 использует disk.file.get. То же дело2472 сверено без повторного создания: две контрольные суммы совпали, журнал completed, повтор creates0. Нативный экспорт17 ещё не принят. Реальная PR всё ещё недостаточного качества; Qwen3.5:9b не принята из-за отсутствия структурированного режима в движке и потери суммы в обходном эксперименте. Полный обновлённый CI17 выполняется; работа продолжается.
