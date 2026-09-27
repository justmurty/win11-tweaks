# win11-tweaks

A single, no-GUI PowerShell script that applies a fixed set of Windows 11 tweaks,
then installs a defined application set (winget +
direct downloads), and finally enables the .NET features. Everything is logged to the
console **and** a file so the run can be reviewed afterwards.

## What it does

- **35 tweaks** — 25 standard (Essential + Advanced + Customize Preferences toggles) + 10
  custom (shortcut-arrow off, Spotlight off + default wallpaper, Ultimate Performance (PC only),
  **Memory Integrity / VBS off** for gaming, mouse acceleration off, DNS → Cloudflare,
  Explorer → This PC, taskbar cleanup (Search / Task view / Widgets / Chat / Resume off),
  **web/Bing + Store search in Start off**, remove the Edge desktop shortcut). Details:
  [`docs/2026-07-11-win11-tweaks-design.md`](docs/2026-07-11-win11-tweaks-design.md).
- Shows the **MSUHost banner**, asks **`Continue? (Y/n)`** and **`PC or Laptop?`** (`1` PC / `2` Laptop).
  On a laptop the **Ultimate Performance** power plan is skipped (it keeps the CPU from idling —
  heat and battery drain) and **NZXT CAM** isn't installed (it's for desktop NZXT coolers/cases).
- Then the **install phase**: **12 Visual C++ redists** + **15 winget apps**
  (incl. VLC, Lightshot, TurboTop, WinRAR; NZXT CAM on a PC only) + **6 direct-download**
  (**Google Chrome**, **NVIDIA App** only if an NVIDIA GPU is present, **Bitwarden**, **Parsec**,
  **Google Play Games**, **FL Studio**) + **Alienware Command Center**, installed automatically
  (no prompt) only on Alienware / Dell G-series hardware, desktop or laptop. It also applies the
  **WinRAR license** and enables **.NET 3.5**
  (incl. 2.0/3.0) **and .NET 4** via DISM (like "Turn Windows features on/off").
- **Pins "This PC"** and **Google Chrome** to the taskbar (via a temporary helper that is deleted
  afterwards), and unpins Microsoft Edge + Microsoft Store.
- Already-installed apps are **skipped** (checked via `winget list` + Add/Remove Programs).
- Makes **no** restore point and does **not** reboot on its own (unless `-Reboot`). Nothing that
  isn't selected is touched.

## Requirements

- Windows 11
- Run **as Administrator** (it edits HKLM and services)
- winget (App Installer) for the install phase (modern Windows 11 ships it by default)

## How to run

### 1) One-liner

Open **PowerShell** and run:

```powershell
irm https://gitlab.msuhost.com/superuser/win11-tweaks/-/raw/main/Invoke-Win11Tweaks.ps1 | iex
```

This downloads and runs the latest script directly. If the window isn't elevated, the script
asks for admin rights (UAC), saves itself to `%LOCALAPPDATA%\win11-tweaks\` and re-launches
that copy in a new elevated window. (Open PowerShell as Administrator to skip the UAC prompt.)

### 2) Download + double-click

Download the repo (or a [release](https://gitlab.msuhost.com/superuser/win11-tweaks/-/releases)),
extract it, and **double-click `Run-Win11Tweaks.bat`** — it self-elevates (UAC), runs the script
in a visible window, and leaves it open at the end. For a preview: `Run-Win11Tweaks.bat -DryRun`.

### 3) Manual

```powershell
# preview only - no changes:
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Win11Tweaks.ps1 -DryRun

# apply for real:
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Win11Tweaks.ps1
```

Open PowerShell/Terminal **as administrator**, `cd` to the script's folder, and run it. On
PowerShell 7 use `pwsh` instead of `powershell`.

## The log

The log is written **in the same folder as the script**, named:

```
win11-tweaks_YYYYMMDD_HHMMSS.log
```

The script prints the full log path at the start and end. Lines are timestamped and levelled
(`[DEBUG] [INFO] [OK] [WARN] [ERROR]`), with a summary table at the end. A compact
`*_results.txt` is written alongside it. The console stays concise; the log file always has full
detail (use `-Detailed` for verbose console output).

Each item in the summary gets one status: `OK`, `WARN` (applied, but a step failed — see the
log), `FAILED`, `SKIPPED` (not needed, or not for this machine), `DRYRUN`, or `BACKGROUND`
(a Windows feature — normally .NET 3.5 — still installing). If you stop the run with Ctrl+C,
the summary still covers what ran. (That holds in Windows PowerShell, which the `.bat` and a
default Windows 11 shell use; PowerShell 7 has an open bug where Ctrl+C can skip it.)

## Flags

| Flag | Effect |
|------|--------|
| `-DryRun` | Log what it WOULD do, change **nothing**. Run this first. |
| (none) | Actually apply the tweaks + install the apps. |
| `-Detailed` | Verbose console output (the log file is always full). |
| `-Machine PC\|Laptop` | Skip the "PC or Laptop?" question (`Laptop` skips Ultimate Performance and NZXT CAM). |
| `-Reboot` | Reboot 15s after finishing (cancel with Ctrl+C). |
| `-LogDir <path>` | Different folder for the log (default: the script's folder). |

## Adding apps

Edit the arrays near the top of the install section of the script: `$script:AppsToInstall`
for winget apps (add winget IDs, e.g. `'Mozilla.Firefox'`), `$script:DirectApps` for
direct-download apps, or `$script:VendorApps` for apps that belong on one vendor's hardware
(`Hardware` is a regex matched against the PC's manufacturer + model).

## Notes

- **NVIDIA App** and **FL Studio** are not (reliably) on winget → the script downloads them
  **directly from the vendor** and installs them silently. NVIDIA App runs **only** if an NVIDIA
  GPU is present.
- Some direct installers return a non-standard exit code even on success (FL Studio returns
  `1223`), so the script verifies the actual install via Add/Remove Programs instead of trusting
  the exit code.
- winget gets the same check: when it reports a failure, the script looks for the app before
  calling it FAILED. Battle.net's setup finishes after winget has stopped waiting for it (winget
  says "Installation abandoned"), so in that case the script gives it up to 5 minutes to land.
- **No undo and no restore point** — if you want to roll back, take a snapshot/backup yourself
  before the real run.
- **winget needs an interactive session** — run via `Run-Win11Tweaks.bat` (double-click) or the
  one-liner in a PowerShell window on the PC itself, not over SSH/remoting (winget fails with
  `0x8A15000F` otherwise).
- **.NET 3.5** pulls its payload from Windows Update. It's started early (in parallel with the app
  installs) and the script **waits** for it to finish at the end, showing a live one-line heartbeat.
  On a normal connection this is seconds; on a WU-throttled box it can take ~30 min. Ctrl+C stops
  the script there (the summary is still written — see [The log](#the-log)), and .NET 3.5 keeps
  installing in the background (`/NoRestart`, so no surprise reboot — just don't reboot until
  it's done).
