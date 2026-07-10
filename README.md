# win11-tweaks

Един самостоятелен PowerShell скрипт, който прилага **точно** избраните WinUtil
(Chris Titus, v26.06.23) настройки на Windows 11 — **без GUI** — и после инсталира
зададен набор приложения през **winget**. Всичко се логва на екрана И във файл, за да
може резултатът да се прегледа.

A single, no-GUI PowerShell script that applies a fixed set of Chris Titus WinUtil
(v26.06.23) tweaks on Windows 11, then installs a defined app set via winget, logging
everything to console **and** a file.

## Какво прави / What it does

- **27 tweaks** (Essential + Advanced + Customize Preferences toggles) — точно каквото
  е избрано в WinUtil. Подробно: [`docs/2026-07-11-win11-tweaks-design.md`](docs/2026-07-11-win11-tweaks-design.md).
- Прави **System Restore Point пръв** (за връщане при нужда).
- После **install фаза** (winget): 13 приложения автоматично + 2 с питане (AnyDesk,
  HP Support Assistant) + активира .NET Framework 2/3/4 (Windows feature).
- **Не рестартира** сам. **Не** пипа нищо, което не е избрано.

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
| `-LogDir <път>` | Друга папка за лога (по подразбиране: папката на скрипта). |

## Добавяне на приложения / Adding apps

Редактирай масива `$AppsToInstall` най-горе в install секцията на скрипта — добави
winget ID-та (напр. `'Mozilla.Firefox'`). За приложения „с питане" — `$AppsToPrompt`.

## Забележки / Notes

- **NVIDIA App** го няма в winget → скриптът го **пропуска** (логва се); инсталирай го
  ръчно засега.
- Няма undo режим — за връщане ползвай създадения System Restore Point.
- Заземено 1:1 в WinUtil v26.06.23 (`irm christitus.com/win`).
