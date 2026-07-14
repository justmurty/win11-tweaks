# win11-tweaks

Един самостоятелен PowerShell скрипт, който прилага **точно** избраните WinUtil
(Chris Titus, v26.06.23) настройки на Windows 11 — **без GUI** — и после инсталира
зададен набор приложения през **winget**. Всичко се логва на екрана И във файл, за да
може резултатът да се прегледа.

A single, no-GUI PowerShell script that applies a fixed set of Chris Titus WinUtil
(v26.06.23) tweaks on Windows 11, then installs a defined app set via winget, logging
everything to console **and** a file.

## Какво прави / What it does

- **35 tweaks** — 25 от WinUtil (Essential + Advanced + Customize Preferences toggles) + 10
  custom (shortcut-arrow off, Spotlight off + default тапет, Ultimate Performance,
  **Memory Integrity/VBS off** за gaming, mouse acceleration off, DNS→Cloudflare, Explorer→This PC,
  taskbar cleanup: Search hide / Task view / Widgets / Chat / Resume off, **web/Bing search в Start off**,
  remove Edge desktop shortcut). Подробно: [`docs/2026-07-11-win11-tweaks-design.md`](docs/2026-07-11-win11-tweaks-design.md).
- Показва **MSUHost банер**, пита **`Continue? (Y/n)`** и **`PC или Laptop?`** (`1` PC / `2` Laptop).
- После **install фаза**: **12 Visual C++ redist** + **17 winget приложения** автоматично
  (вкл. Razer Synapse 4, VLC, Lightshot, TurboTop) + **5 директно от сайта**
  (**NVIDIA App** само при NVIDIA GPU, **Bitwarden**, **Parsec**, **Google Play Games**, **FL Studio**) + **machine-специфични**:
  **HP Support Assistant** (само Laptop) и **Alienware Command Center** (само PC) — без питане, според избора;
  поставя **WinRAR лиценз** (`rarreg.key`) и
  активира **.NET 3.5** (вкл. 2.0/3.0) **и .NET 4** (през DISM, като "Turn Windows features on/off").
- **Pin-ва "This PC" в taskbar** (с иконата на This PC) чрез временен helper, който се трие след това.
- Вече инсталирано приложение се **прескача** (проверка през `winget list` + Add/Remove Programs).
- **Не** прави Restore Point и **не рестартира** сам (освен с `-Reboot`). **Не** пипа нищо,
  което не е избрано.

## Изисквания / Requirements

- Windows 11
- Пуска се **като Администратор** (пипа HKLM и услуги)
- winget (App Installer) — за install фазата (модерен Win11 го има по подразбиране)

## Пускане / How to run

**1) Първо DryRun (нищо не се променя — само лог за преглед):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Win11Tweaks.ps1 -DryRun
```

**2) Реално прилагане:**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Win11Tweaks.ps1
```

> Отвори PowerShell/Terminal **като администратор**, `cd` до папката със скрипта, и
> пусни командата. На PowerShell 7 ползвай `pwsh` вместо `powershell`.

### По-лесно: launcher `.bat`

Вместо командата горе, може просто да **двойно-цъкнеш `Run-Win11Tweaks.bat`** —
самоелевира се (UAC), пуска скрипта във видим прозорец и го оставя отворен накрая.
За preview: `Run-Win11Tweaks.bat -DryRun`.

## Логът / The log

Логът се записва **в същата папка, където е скриптът**, с име:

```
win11-tweaks_YYYYMMDD_HHMMSS.log
```

Скриптът печата пълния път до лога в началото и в края. **Прати ми този файл**, за да
видя дали всичко е минало (кое е `OK`, кое `WARN/FAILED`).

Редовете в лога са с таймстамп и ниво: `[DEBUG] [INFO] [OK] [WARN] [ERROR]`, плюс
таблица-обобщение накрая.

## Режими / Modes

| Флаг | Ефект |
|------|-------|
| `-DryRun` | Логва какво БИ направил, но **не пипа** системата. Пусни това първо. |
| (без флаг) | Реално прилага tweaks + инсталира приложенията. |
| `-Reboot` | Рестартира машината 15s след края (спира се с Ctrl+C). |
| `-LogDir <път>` | Друга папка за лога (по подразбиране: папката на скрипта). |
| `-Machine PC\|Laptop` | Прескача въпроса „PC или Laptop?" (gate за HP/Alienware). |

## Добавяне на приложения / Adding apps

Редактирай масива `$AppsToInstall` най-горе в install секцията на скрипта — добави
winget ID-та (напр. `'Mozilla.Firefox'`). За приложения „с питане" — `$AppsToPrompt`.

## Забележки / Notes

- **NVIDIA App** го няма в winget → скриптът го тегли **директно от сайта на NVIDIA**
  (намира текущата версия) и го слага тихо - **само ако има NVIDIA видеокарта**, иначе пропуска.
- **Няма undo и НЕ се прави Restore Point** — ако искаш връщане назад, направи си сам
  snapshot/бекъп преди реалния пуск.
- **winget иска интерактивна сесия** — пускай през `Run-Win11Tweaks.bat` (двойно-цъкане),
  не през SSH/отдалечено (иначе winget гърми с `0x8A15000F`).
- **.NET 3.5** тегли payload само от Windows Update/медия — на машина с интернет минава; при
  блокиран WU гръмва timeout след 300s и продължава.
- Заземено 1:1 в WinUtil v26.06.23 (`irm christitus.com/win`).
