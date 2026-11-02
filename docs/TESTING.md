# Проверка среза A, 02.11.2026

Среда: Apple M4 Max, 36 GiB, macOS 27.0.1, Swift 6.4 Command Line Tools без полного Xcode; whisper.cpp 1.9.5; multilingual small 487601967 байт, SHA256 `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b`.

## Автоматические проверки

`bash scripts/ci-local.sh` запускает:

1. CoreChecks: WAV clipping/roundtrip/truncation, манифест и interrupted recovery, изоляция путей, orphan WAV, ошибка записи и повторное сохранение буфера, короткий остаток и разрыв времени, изоляция повреждённого манифеста/WAV/пустой папки, whisper JSON offsets/silence/malformed. 10 проверок прошли.
2. Release-сборку .app и проверку ad-hoc подписи.
3. Диагностику наличия whisper-cli и модели без начала захвата.
4. Синтез русской фразы голосом Milena, 16 kHz mono WAV, два источника с разными смещениями времени, реальное распознавание whisper-cli, проверку цены в тексте, сохранение/повторную загрузку JSON и экспорт M4A с проверкой длительности.

В debug-сборке 19,11 секунды синтетической записи обработаны и экспортированы за 3,21 секунды после исправлений. Это один файловый прогон, не задержка живой транскрипции, не p95 и не оценка точности. Полная запись M4A действительно создана. Прослушивание пока не является автоматической проверкой.

## Интерфейс и разрешения

Собранное приложение установлено в пользовательскую Applications. Визуально проверено основное окно, пустая история, выбор источника, два индикатора и явный старт. Кнопка обновления источников возвращает явную ошибку отказа macOS; запись при этом не начинается. После обновления привязки разрешения через штатные настройки macOS живой тест выполнен. Источник QuickTime Player с синтетической русской речью плюс физический микрофон: оба индикатора получали данные, транскрипция появилась во время записи. За 30 секунд сохранено 8 WAV: по 4 на источник, микрофон 29,316 с, аудио приложения 29,760 с. Последние фрагменты короче 8 с: 5,316 и 5,760 с. Ошибок/failed chunks нет, состояние completed, 11 строк текста, M4A 94438 байт. После перезапуска история и текст сохранились, запись не возобновилась. Нажатие отметки времени не вызвало ошибки; субъективное качество воспроизведения не оценивалось. На микрофонном фоне модель выдала ложные слова и метки «музыка», а на границе фразы встречаются искажения. Это ограничение текущего распознавания; точность для продаж ещё не принята.

## Ручной приёмочный сценарий

1. Разрешить микрофон и запись экрана/системного аудио. Выбрать приложение с синтетической речью, не захватывать чужую рабочую встречу ради теста.
2. Запустить запись, сказать русскую тестовую фразу в микрофон, воспроизвести другую фразу в выбранном приложении. Оба индикатора должны получать данные; текст должен появиться в ходе записи.
3. Остановить после неполных 8 секунд последнего фрагмента. Убедиться, что есть финальный текст и M4A, оба источника слышны, отметки времени совпадают.
4. Перезапустить приложение: история и текст доступны; запись не возобновляется. Проверить переход по времени и повторную транскрипцию при неправильном пути к модели.
5. Отдельно проверить Zoom, Телемост, наушники, 30-минутную встречу и параллельную Granola. До этого совместимость с ними не считать принятой.

## Ограничения

Нет диаризации людей внутри канала «Собеседники». Без гарантии точности чисел, названий и границ фраз. Нет пословного стриминга, подавления эха или измеренного p95. При аварии теряется ещё не записанный из RAM фрагмент. Если диск недоступен, финальный фрагмент может остаться несохранённым; состояние interrupted предупреждает об этом. Нет синхронизации, удаления через UI, CRM, MCP и суфлёра в этом срезе.

## Комплект сотруднику

Статический whisper.cpp собран из проверенного архива 1.9.5 с CMake (baseline armv8.2-a, GGML_NATIVE=OFF, OpenMP=OFF). `otool -L` показывает только системные библиотеки/фреймворки; `vtool` показывает minos 15.0 и у приложения, и у CLI. Во встроенном комплекте выполнено реальное распознавание двух источников и M4A export: PASS, 9,12 с обработки/экспорта для 13,89 с синтетического архива. Это проверка на текущем M4, не тест второго Mac или macOS 15. Архив содержит модель и LICENSE whisper.cpp, не содержит Meetings и ключей.

## Фирменный интерфейс

После запроса владельца добавлены закреплённая зелёная шапка со знаком Аксис и нижние ссылки на активные продукты. Живой визуальный проход: пустое состояние, сохранённая встреча, прокрутка транскрипции и настройки. Полосы остаются на месте, ссылки доступны через accessibility. Найденное перекрытие заголовка системной панелью NavigationSplitView устранено переходом на HSplitView; повторный визуальный проход подтвердил читаемость. Сборка переносимого комплекта после изменения: PASS, реальное русское распознавание двух источников и экспорт M4A за 4,72 с для 13,89 с синтетического архива. Повторный захват Zoom/Телемоста этим тестом не проверяется.

Версия 0.1.1: AppIcon.icns включает 10 представлений от 16 до 1024 пикселей, CFBundleIconFile указывает AppIcon, ресурс копируется в bundle. Ссылка на выведенный из разработки продукт «Модель» удалена. Переносимый комплект v2 собран и прошёл bundled-диагностику, реальное русское распознавание двух источников и M4A export (1,22 с для 13,89 с синтетического архива).

Коммит реализации 83ba8f8 проверен через scripts/ci-local.sh в свежем чистом клоне: 10 проверок ядра, release-сборка и подпись .app, диагностика, реальное русское распознавание двух источников, абсолютные отметки времени, повторная загрузка манифеста и M4A export. Всё PASS, 1,45 с обработки/экспорта для 19,04 с синтетического архива. Jev escalation safe_to_apply=0.23 сохранён; 02.11.2026 владелец явно разрешил коммит и push вопреки этому gate. Последующий коммит содержит только протокол проверки и статус.

## Echo hotfix candidate 0.1.2

User reported duplicate remote speech in microphone/app tracks during a live Telemost meeting. Raw ScreenCaptureKit microphone input had no voice processing. A second reproduction path existed: timestamp playback buttons remained enabled during recording although full playback was disabled.

Microphone now uses native AVAudioEngine VoiceProcessingIO, AGC disabled, minimum other-audio ducking, input connected to a muted mixer for device rendering. System audio remains isolated through ScreenCaptureKit. Both use host clock timestamps. Playback is guarded in both UI and model and stopped before recording. Source labels are microphone/meeting audio; no identity inference is claimed. Audio-device configuration changes fail visibly and interrupt recording; teardown runs outside the engine notification queue.

Observed red/green: `--verify-voice-processing` failed for an unconfigured engine, then passed with voice processing enabled on both IO nodes and AGC off. Local `scripts/ci-local.sh` passed 10 core checks, release build/signature, native configuration check (no capture), Russian ASR/M4A fixture (1.81 s processing / 19.04 s archive). These are configuration and pipeline checks, not a physical echo reduction or simultaneous-talk acceptance test.

Jev review of this bounded fix escalated: safe_to_apply=0.20, correctness confidence=0.17; test claims verified=0.91. Independent review identified missing device-change handling, corrected before delivery. No new app was installed over the active meeting. Owner decision and live acoustic verification remain required; no claim that echo has already disappeared. Historical transcript/source assignments are unchanged.

Final candidate reproduced in fresh checkout plus complete candidate patch (.build/clean-echo-012): 10 core checks, release/signature, native configuration and Russian ASR/M4A PASS; final processing 6.91 s / archive 19.04 s. Independent re-review confirmed device-change observer correction and no additional Critical/Important findings. Employee Apple Silicon ZIP v3 rebuilt successfully with final binary; remains a test candidate.

Local update applied after owner requested immediate correction and independent re-review cleared Critical/Important findings. Previous live session gracefully stopped and verified completed (189 chunks, M4A 729.856 s), without printing/exporting transcript. Installed version 0.1.2 signature verified. macOS requested Touch ID during refresh of existing screen/audio permission; user authentication pending. No automatic restart of capture. Jev escalation remains disclosed; no commit/push or general release claim.

Owner confirmed Touch ID. Existing permission was re-added to the installed binary; system-audio discovery succeeded without capture. App moved (same signed bundle, no rebuild) from user Applications to /Applications/AxisCopilot.app at owner request; signature verification, launch and system-audio discovery succeeded again. History remains visible. No live echo measurement yet.

## Meeting experience candidate 0.2.0

Full candidate reproduced in isolated checkout .build/clean-meeting-020. CoreChecks including playback intervals and speaker/manual-assignment contracts, release application, diagnostics, native voice-processing configuration, actual muted AVAudioPlayer playback at seven rates, updater signature/version/architecture rejection and rollback, Russian ASR and M4A export all passed. Final ASR/export took 1.42 seconds for 19.04 seconds of synthetic archive. This checkout uses an ignored shallow official FluidAudio mirror at the exact pinned upstream revision; no client data or credentials are included.

Employee bundle native playback verification passed all seven rates, pause, seek, end/restart and stop. Pitch was not measured. Bundled local speaker inference processed 60.86 seconds of harmless synthetic Daniel, Samantha and Milena speech in 6.70 seconds, producing three consistent recurring labels across 8-second chunks and both source channels. Short overlap tail remained unknown; reliable overlap detection and real-meeting speaker accuracy are not established.

Build 4 bootstrap-installed at /Applications/AxisCopilot.app after confirming no capture. Prior 0.1.2 binary preserved. Native UI verified play/pause, volume zero, 1.5 rate and seek to 12 seconds on synthetic history. Saved-session transcript collapsed because capture controls consumed vertical space; build 5 hides capture setup for saved idle meetings and reserves transcript height, while retaining retry/status for failed or pending transcription. Independent review found and then verified correction of the hidden-retry regression.

Permanent certificate identity and matching designated requirements verified across signed fixtures. First transition from ad-hoc returned system-audio permission denial; owner action requested. Actual permission retention through installed signed updater is pending. No capture started during this acceptance. Local publication remains held after Jev low-confidence escalation; stronger independent review cleared only reversible local install, with no Critical/Important finding. No commit/push or distribution clearance is implied.

Final build 5 repeated isolated ci-local PASS after layout/recovery correction: 1.44 seconds ASR/export for 19.04 seconds synthetic archive. Portable employee package PASS: 0.99 seconds for 13.89 seconds archive. SHA256 ZIP v5: `8786c49006009f2d73a7ac82868817eef1ea799b22ba2f31842e84f4aeed4ba5`.

Owner confirmed bootstrap permission refresh on build 4. Native signed updater selected final build 5, validated and installed it, retained Previous.app and relaunched. Helper result reports success; installed executable SHA256 equals final employee executable. In fresh build 5 instance, system-audio discovery successfully populated application picker without another grant. No microphone/capture retention claim: recording was not started.

Native final layout displays transcript and fixed player together. Timestamp at 16 seconds sought and played with both concurrent phrase highlights; pause, volume zero and 1.5 rate visible. Search «стоимость» filtered text. Local analysis completed in UI, profile renamed «Тестовый голос», phrase manually assigned through speaker menu, name persisted after history selection. CUA menu item requires Return after selection; initial selection alone did not apply assignment. A CUA automatic relaunch during helper swap briefly produced old/new idle processes; old instance quit via UI, one current process remains. This exposes a narrow single-instance hardening opportunity, not a capture test.

Manual transcript scrolling disabled following and exposed «К текущей фразе»; activating it restored following. Manual phrase assignment survived leaving/reopening synthetic history. Final stronger-reasoner source/log review supports private branch and owner-review alpha with no Important/Critical blocker, while preserving all physical capture and real-meeting limitations. Canonical smart-commit explicitly stops on low safe_to_apply, so owner exception requested and commit/push remain pending. No repeated Jev calls were made to obtain a more favorable score.

Owner then explicitly approved commit and push of the reviewed 0.2.0 candidate to private codex/recording-prototype despite Jev 0.28/0.23. This is a recorded exception, not a successful automated gate. No merge authorized; other-lead cross-review and live meeting acceptance remain outstanding.
