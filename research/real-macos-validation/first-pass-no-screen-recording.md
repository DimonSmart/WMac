# WMac — проверка на реальной macOS, 29 октября 2026

Это первый проход без Screen Recording. Актуальные результаты после выдачи разрешений: [отчёт от 31 октября](REPORT.md).

Главный критерий соответствия настоящей миниатюры активируемому окну НЕ ПОДТВЕРЖДЁН: у Debug WMac Screen Recording не выдан. Чужих изображений не наблюдалось, поскольку все карточки показывали placeholders. Это не доказательство корректности реального захвата.

## Среда

- macOS 26.7.1 (25G241), Apple M4 Pro.
- Один встроенный Color LCD, 3456 × 2234 Retina. Других дисплеев нет.
- Debug WMac: Accessibility enabled (прочитано в Settings → Permissions), Screen Recording not granted (Settings → Window Previews).
- WMacProbe: AX trusted, отдельный процесс и идентичность. `--require-ax` успешно выполнен.
- Microsoft Edge: установленная версия 156.0.4314.50; запущенный процесс использует framework 156.0.4314.42. PID 718. Проверены обычные Work-окна и точный выбор InPrivate-окна.
- Cursor 3.27.22: проверено восстановление карточкой окна Cursor Agents, затем возвращено исходное свёрнутое состояние.
- Finder 26.4: попытка проверки, отказ чтения AXSubrole с AX -25212.
- Terminal 2.15 установлен и запущен, но Computer Use отказал в управлении приложением по правилам инструмента. Обходов не использовано.
- До проверки уже работал Release WMac. Его процесс не завершался; действия и новые диагностические записи относятся к Debug PID 70339.

## Практические результаты

PASS ниже относится к AX-идентичности и выбору. Реальный захват и AX↔CG/SCK во всех сценариях NOT TESTED.

| Сценарий | Результат | Наблюдение |
| --- | --- | --- |
| Несколько окон | PASS (AX) | Два созданных локальных Edge A/B среди пяти окон. Выбор карточки A/B подтверждён URL и текстом страницы. InPrivate-карточка активировала соответствующее окно. |
| Одинаковые заголовки | PASS (AX) | Две страницы с одинаковым title, синим A и красным B. Выбор второй карточки вернул страницу A. |
| Одинаковая геометрия и перекрытие | PASS (AX), NOT TESTED (resolver) | У A/B одинаковый frame (0,33,1728,1006), окна перекрыты. Изображений нет из-за разрешения, runtime-неоднозначность не проверена. |
| Изменение размеров | PASS (AX) | Публичное действие zoom изменило frame A на (0,33,1708,986). AX UUID и lifecycle=1 сохранились, revision 1→6. Перетаскивание не проверено. |
| Изменение заголовка | PASS (AX) | Навигация A/B к страницам с одинаковым title обновила названия карточек. Переключение вкладок отдельно не проверено. |
| Закрытие/создание | PASS (AX) | После закрытия A число карточек 5→4, после создания 4→5. UUID 1651B681-5A45-4004-A11A-6224184E499A/lifecycle=1 заменён E2FD21D7-C8F1-492A-8A63-AA7F97EFC641/lifecycle=6. |
| Сворачивание/восстановление | PASS (AX) | Свёрнутая карточка A восстановила именно A при существующем B с тем же заголовком; Cursor Agents также восстановлен по карточке. |
| Переключение окон/приложений | PASS (AX) | Edge A/B/InPrivate и Cursor; штатный Probe проверил точный PID и last-active window. |
| Асинхронный захват/быстрые popup | NOT TESTED | Без Screen Recording SCK не вызывается; гонки публикации кадров не проверены на машине. |
| Finder | FAIL (перечисление AX) | AXSubrole одного из элементов не прочитан: -25212. Безопасная деградация сохраняется; список не выдаётся за подтверждённый. |
| Несколько дисплеев | NOT TESTED | Доступен один дисплей. |
| Spaces/fullscreen | NOT TESTED | Не проверены в этом проходе. |

## Исправления

1. При доступном Accessibility отказ чтения AX больше не выдаётся за отсутствие разрешения. Popup показывает временную недоступность списка.
2. Opt-in журнал получает `axEnumerationUnavailable` с точной причиной; ошибки subrole и minimized различимы.
3. Пропуск изображения без Screen Recording теперь достигает существующей проверки сервиса и логируется для каждого окна: WindowIdentity, lifecycle, revision, frame, minimized и `screenRecordingPermissionMissing`.

Правила resolver, пороги соответствия, фильтрация AX и требования к публикации изображений не изменены. Finder AX -25212 остаётся ограничением: неподтверждённый набор окон не принимается. Новые тесты не добавлены для этих изменений сообщений и журналирования.

Все наблюдавшиеся placeholders объясняются отсутствием Screen Recording. Для Finder до миниатюр не дошло из-за отказа AX. Выбранного CGWindowID, графических кандидатов и исходов SCK в этом проходе нет: захват не выполнялся. Реальное отклонение неоднозначного графического соответствия не подтверждено; существующие модельные проверки неоднозначности проходят.

## Автоматическая проверка

- `./scripts/build.sh Debug`: PASS, постоянная подпись проверена.
- `./scripts/build.sh Release`: PASS после последнего изменения.
- `./scripts/test.sh`: PASS до и после исправлений. Финальный `test-final.log`: 160 PASS UNIT, UNIT RESULT failures=0; 25 PASS GUI, RESULT failures=0; AX exercised.
- `.build/products/Debug/WMacProbe .build/products/Debug --require-ax`: PASS, failures=0; AX exercised. Выполнено до изменений диагностических сообщений; финальный test.sh повторно прошёл реальные AX-действия после изменений.
- `./scripts/verify-build.sh`: PASS после последнего изменения; universal arm64/x86_64, minimum macOS 14, bundle metadata, подписи, Hardened Runtime и Debug/Release entitlements.
- `git diff --check`: PASS.
- `.idd/verification.yaml` отсутствует; использован repository fallback, штатные scripts.

Логи: build-debug.log, build-release-final.log, test.log, probe-require-ax.log, test-final.log, verify-build-final.log, window-previews-live.log. Заголовки в диагностическом журнале скрыты; изображения не сохранялись.

## Focused Intent Drift Audit

Mode: preserve-current-intent.

Scope: IDD-0010 §§3.2, 5, 6.7, 9, 11.5, 14; IDD-0005, граница ошибок и диагностики предпросмотра.

Specs used as intent: IDD-0010, IDD-0005.

Engineering rules applied: ENG-0001, ENG-0003 (Always), ENG-0002 (управление окнами). Структура Engineering проверена: четыре уникальных файла, H1/INDEX/Applicability согласованы, allocator ENG-0005; archive, неоднозначных секций и нормативных command blocks нет.

Behavior changed: исправлено объяснение недоступности списка и дополнен явно включаемый журнал.

Behavior preserved: AX-идентичность, действия выбора, графическое сопоставление, безопасные placeholders, отсутствие автоматических TCC-запросов.

Public contracts preserved: публичные Apple API, отсутствие частных AX↔CG-преобразований, отдельность семантического окна и CGWindowID.

Compatibility/data constraints: схема настроек и пользовательские данные не менялись; TCC вручную не изменялся.

Code areas changed: Sources/WMac/WindowPreview.swift, Sources/Core/Accessibility.swift.

Tests changed: none; existing verification is sufficient for low-impact diagnostic/message edits.

Verification result: автоматические проверки PASS; реальная графическая матрица NOT VERIFIED.

Engineering conformance: engineering-match, новых границ сервисов и непубличных API нет.

Intent-drift-audit result: исправленный отказ соответствует IDD-0010 §3.2; no new implementation drift observed in changed scope. Classification missing-verification для реальных миниатюр, гонок SCK, Spaces/fullscreen и нескольких дисплеев. Finder AX enumeration failure остаётся открытым runtime finding.

Remaining risks: отсутствие доказательств реального AX↔CG/SCK соответствия. Для продолжения пользователь должен выдать Debug WMac Screen & System Audio Recording через обычные System Settings, при необходимости перезапустить WMac. Разрешение WMacProbe отдельно и не доказывает разрешение WMac.

Тестовые окна Edge и два созданных окна Finder закрыты. Исходное свёрнутое состояние Cursor восстановлено. Debug WMac оставлен запущенным для дальнейшей проверки.
