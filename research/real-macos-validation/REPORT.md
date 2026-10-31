# WMac: реальная проверка с AX и Screen Recording — 31 октября 2026

В проверенных сценариях не обнаружено миниатюры другого окна. Подтверждены реальные кадры, выбор соответствующего AX-окна, безопасные placeholders при неоднозначности и отбрасывание устаревшего захвата. Это результат ограниченного практического прохода, а не доказательство для всех приложений и конфигураций macOS.

## Среда и разрешения

- macOS 26.7.1, build 25G241, Apple M4 Pro.
- Один встроенный Color LCD: 3456 × 2234 Retina. Несколько дисплеев недоступны.
- Приложения: Microsoft Edge 156.0.4314.50 (у давно работающего PID 718 ранее наблюдался framework 156.0.4314.42), Cursor 3.27.22, CotEditor 7.1.3, Finder 26.4, штатный WMacMultiFixture.
- Terminal 2.15 установлен, но Computer Use отказал в управлении им. Обходов ограничения не использовано.
- Проверялся Debug `.build/products/Debug/WMac.app`, обычный запуск через LaunchServices, диагностический PID 39966.
- В конце проверки сам Debug показывает `Accessibility: enabled` и `Screen Recording: enabled`; real thumbnails включены.
- Разрешения предоставлены обычными System Settings после явных подтверждений пользователя. Прямых изменений TCC, `tccutil`, сбросов базы или отключения защиты не было.
- При настройке обнаружены разные копии WMac с одним bundle ID. Существующая запись Accessibility показывала в Finder Release из distribution. Повторное Add не дало Debug доступ; после удаления старой записи и добавления точного Debug доступ заработал. Состояние Release после этого не проверялось. Предыдущий успешный AX-статус при запуске из host не доказывал собственного разрешения обычного запуска Debug.

## Матрица

| Сценарий | Результат | Доказательство / ограничение |
| --- | --- | --- |
| Несколько окон с разными заголовками | PASS | Два окна штатной фикстуры: на кадрах видны Window 1/2. Выбор каждой карточки активировал соответствующее содержимое. CotEditor A/B также дал правильные кадры и точный выбор A. |
| Одинаковые заголовки | PASS | `--same-title`: два окна с одинаковым title и разными позициями получили правильные кадры. Выбор второй карточки показал тело Window 1. |
| Одинаковый размер и полное наложение | PASS | `--same-title --overlap`: оба frame `(225,630,420,212)`, обе карточки — placeholders. Resolver вернул ambiguous с кандидатами `[10839,10838]` для каждого AX-окна. Выбор AX-окна оставался доступным. |
| Изменение геометрии | PASS | Zoom фикстуры сохранил identity и CGWindowID, обновил revision и кадр. Move & Resize → Left в CotEditor изменил A с `(154,338,1376,568)` на `(0,33,348,1084)`; кадр остался от A. |
| Изменение геометрии конкурента в открытом popup | PASS | При zoom одного из полностью совпадающих окон неоднозначность исчезла и появились правильные кадры. Обратный zoom вернул одинаковые рамки: оба прежних изображения удалены, обе карточки снова placeholders. |
| Изменение заголовка / вкладки | PASS, без кадров Edge | В собственном тестовом окне Edge открыта вторая локальная вкладка B. Два окна стали иметь одинаковый title B. Переключение на вкладку A обновило соответствующую карточку на месте. Resolver продолжал отклонять изображения с titleMismatch. |
| Закрытие и создание похожего окна | PASS с деградацией | CotEditor A закрыт и повторно открыт по тому же пути. Новое окно получило новый AX UUID, lifecycle и CGWindowID; его кадр содержал A. Между закрытием и повторным открытием список был недоступен из-за AX -25205, изображения не показывались. |
| Сворачивание / восстановление | PASS | Фикстура Window 2 стала minimized, захват завершился ошибкой и карточка получила placeholder. Выбор восстановил именно Window 2; новый захват успешен. |
| Быстрые popup / асинхронные операции | PASS в выполненном проходе | Несколько открытий/закрытий и переключений между WMacMultiFixture и CotEditor. Есть реальный `captureDiscardedStale` после смены контекста. Финальные кадры CotEditor не содержали изображения фикстуры. |
| Переключение окон и приложений | PASS | Точные выборы фикстуры, CotEditor и Cursor; штатный Probe отдельно проверил exact PID и last-active window. |
| Chromium: Cursor | PASS | `Cursor Agents` сопоставлен с CG 7423; реальный кадр визуально соответствовал активированному окну. |
| Chromium: Microsoft Edge | PASS по безопасности; изображения отсутствуют | Для обычных и локальных тестовых окон resolver возвращает titleMismatch. Чужие изображения не назначались; выбор A/B работал. Нормализация заголовков и geometry-only fallback не добавлялись. |
| Finder | FAIL: перечисление AX | При собственном AX-разрешении Debug сохраняется `Window subrole temporarily unavailable (AX -25212)`. Показано состояние временной недоступности, изображений и произвольного выбора нет. Причина конкретного неподдерживаемого AX-элемента не установлена. |
| Fullscreen | PASS: базовый сценарий | Window 1 переведено в fullscreen, затем popup получен из обычного рабочего пространства. Кадр соответствовал Window 1; выбор вернул его. Escape восстановил обычное окно. В этом состоянии AX перечислял только одно окно фикстуры. |
| Несколько дисплеев | NOT TESTED | Доступен один дисплей. |
| Полная матрица Spaces | NOT TESTED | Проверен переход, связанный с одним fullscreen-окном. Произвольные дополнительные Spaces и их сочетания не проверялись. |
| Terminal | NOT TESTED | Ограничение инструмента Computer Use. |

## Идентичности и решения

Все строки ниже доступны в `window-previews-2026-10-31.log`; заголовки в журнале скрыты, пиксели не записывались.

| Случай | WindowIdentity / версия | Графическое решение |
| --- | --- | --- |
| Фикстура PID 40987 Window 2 | AX A93106F7-5D69-4632-8DD1-01813F4C82F7, lifecycle 3, revision 3 | uniqueTitleAndGeometry → CG 10513, captureSucceeded |
| Та же Window 2 после minimize | Тот же UUID/lifecycle, revision 11, minimized=true, AXDialog | CG 10513 подтверждён; captureFailed за 26 мс → placeholder |
| После восстановления | Тот же UUID/lifecycle, revision 12, AXStandardWindow | CG 10513, captureSucceeded за 145 мс |
| CotEditor A до закрытия | AX B2CAE0BA-AE0A-4418-965E-2C6B92AF5EC4, lifecycle 6 | CG 10598; revision 15→19 при изменении геометрии |
| CotEditor A после повторного открытия | AX 5137434E-5F8A-4C58-81B9-5B6EE0B1919A, lifecycle 17, revision 38 | Новый CG 10720, captureSucceeded |
| Полная неоднозначность PID 51791 | AX 9A8E412F-EC8F-4CA0-A33A-832EBE0CD3A4 и C9F467A5-4E34-4D2D-A911-01805B16C8C0, lifecycle 26/27, revision 49/50 | У обоих candidates [10839,10838], multipleGraphicsCandidates, ambiguous, association D62A3CC8-DA98-4C97-A921-9767198A3D9A; захват не начат |
| Устаревший асинхронный кадр | PID 51791, lifecycle 26, revision 52 | CG 10839: captureStarted → captureDiscardedStale в 15:31:52.793 |
| Cursor PID 95676 | AX 9A41A8FC-EB82-4551-9275-864335EB04BA, lifecycle 28, revision 56 | uniqueTitleAndGeometry → CG 7423, captureSucceeded за 178 мс |

Журнал этого прохода содержит 37 captureStarted: 35 captureSucceeded, 1 captureFailed (свёрнутое окно), 1 captureDiscardedStale. Также зарегистрированы 6 ambiguous-решений, 6 повторно подтверждённых cache hits и 3 cacheInvalidated. Не каждый из 35 кадров проверялся отдельным кликом; визуальные сверки и выбор выполнялись для описанных в матрице окон.

Причины отсутствия изображений: неоднозначность двух кандидатов; противоречащие заголовки Edge; отказ SCK для свёрнутого окна; неизвестный AX-снимок Finder или CotEditor. Ослабления критериев ради миниатюр не было.

## Изменения и проверки

- `7dd0b28` (первый проход): исправлены объяснение AX-недоступности и журналирование причин отсутствия изображения.
- `f15ac01` (текущий проход, main): в существующий GUI fixture добавлены `--same-title` и `--overlap`. Различимое тело Window 1/2 сохранено. Обычный режим фикстуры не изменён.
- Продуктовый resolver, пороги, критерии допуска к захвату и публикации кадров не менялись. Большого набора новых тестов нет.
- `./scripts/test.sh`: PASS после изменения фикстуры, 160 модельных и 25 GUI-проверок, failures=0; AX exercised. Внутри выполнена Debug-сборка и проверена постоянная подпись.
- `./scripts/build.sh Release`: PASS. Первый запуск одновременно с Debug получил build.db locked; последовательный повтор прошёл успешно. Эта инфраструктурная ошибка сохранена в исходном build-release.log.
- `./scripts/verify-build.sh`: PASS после последних изменений: universal arm64/x86_64, bundle metadata, minimum macOS 14, подписи, Hardened Runtime и entitlements.
- `git diff --check`: PASS; рабочее дерево после коммита чистое.
- Отдельный `WMacProbe --require-ax` прошёл в первом проходе. Текущий test.sh повторно выполнил реальные AX-действия; разрешение Probe не использовалось как доказательство разрешения WMac.
- `.idd/verification.yaml` отсутствует, применён repository fallback.

Полные локальные логи текущего прохода (тесты, сборки и WindowPreviews) были сохранены в игнорируемом `.build/real-macos-validation/with-screen-access/`; в исследовательскую ветку они не включены. Итоги команд зафиксированы выше. Первый проход без Screen Recording приведён в [отдельном отчёте](first-pass-no-screen-recording.md).

## Focused Intent Drift Audit

Mode: preserve-current-intent для test fixture; satisfy-current-intent не требовался, так как продуктовый алгоритм не менялся.

Scope: IDD-0010 §§5–7, 11.5, 14; IDD-0005 — идентичность, безопасный выбор, AX-недоступность; изменения только в Sources/Fixture/main.swift.

Specs used as intent: IDD-0010, IDD-0005. Engineering rules applied: ENG-0001 и ENG-0003 (Always), ENG-0002 (публичные операции окон). Структура Engineering без изменений относительно проверенного первого прохода; не обнаружено несогласованных ID/INDEX/Applicability.

Behavior changed: только явно выбираемые параметры developer fixture. Behavior preserved: обычная фикстура, весь shipping runtime, AX↔CG matching, снимки/поколения/кэш, приватность и настройки. Public contracts preserved: публичные Apple API, точный AX-выбор, независимость CGWindowID от WindowIdentity. Compatibility/data constraints: продуктовые данные и схемы не менялись. Tests changed: существующая фикстура расширена двумя флагами, новых unit-сценариев нет. Verification result: назначенные repository checks PASS и практические результаты выше. Engineering conformance: engineering-match в изменённом scope. Intent-drift-audit result: matches-intent для проверенных требований безопасности; missing-verification для полной матрицы Spaces, дополнительных дисплеев и Terminal. Отказы AX Finder/CotEditor остаются runtime findings, без неподтверждённого объявления новой продуктовой семантики.

Тестовые окна Edge и CotEditor закрыты, все запущенные вручную фикстуры завершены. Восстановленный пользовательский Untitled CotEditor не изменялся и оставлен открытым. Debug WMac оставлен запущенным. Оба диагностических log stream остановлены.
