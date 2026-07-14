# win11-tweaks

A single, no-GUI PowerShell script that applies a fixed set of Chris Titus WinUtil
(v26.06.23) tweaks on Windows 11, then installs a defined application set (winget +
direct downloads), and finally enables the .NET features. Everything is logged to the
console **and** a file so the run can be reviewed afterwards.

## What it does

- **35 tweaks** — 25 from WinUtil (Essential + Advanced + Customize Preferences toggles) + 10
  custom (shortcut-arrow off, Spotlight off + default wallpaper, Ultimate Performance,
  **Memory Integrity / VBS off** for gaming, mouse acceleration off, DNS → Cloudflare,
  Explorer → This PC, taskbar cleanup (Search / Task view / Widgets / Chat / Resume off),
  **web/Bing + Store search in Start off**, remove the Edge desktop shortcut). Details:
  [`docs/2026-07-11-win11-tweaks-design.md`](docs/2026-07-11-win11-tweaks-design.md).
- Shows the **MSUHost banner**, asks **`Continue? (Y/n)`** and **`PC or Laptop?`** (`1` PC / `2` Laptop).
- Then the **install phase**: **12 Visual C++ redists** + **16 winget apps**
  (incl. Razer Synapse 4, VLC, Lightshot, TurboTop, WinRAR) + **6 direct-download**
  (**Google Chrome**, **NVIDIA App** only if an NVIDIA GPU is present, **Bitwarden**, **Parsec**,
  **Google Play Games**, **FL Studio**) + **machine-specific**: **HP Support Assistant**
  (Laptop only) and **Alienware Command Center** (PC only) — installed automatically per the
  PC/Laptop answer, no prompt. It also applies the **WinRAR license** and enables **.NET 3.5**
  (incl. 2.0/3.0) **and .NET 4** via DISM (like "Turn Windows features on/off").
- **Pins "This PC"** to the taskbar (with the This PC icon) via a temporary helper that is
  deleted afterwards, and unpins Microsoft Edge + Microsoft Store.
- Already-installed apps are **skipped** (checked via `winget list` + Add/Remove Programs).
- Makes **no** restore point and does **not** reboot on its own (unless `-Reboot`). Nothing that
  isn't selected is touched.

## Requirements

- Windows 11
- Run **as Administrator** (it edits HKLM and services)
- winget (App Installer) for the install phase (modern Windows 11 ships it by default)

## How to run

### 1) One-liner (like WinUtil)

Open **PowerShell as Administrator** and run:

```powershell
irm https://gitlab.msuhost.com/superuser/win11-tweaks/-/raw/main/Invoke-Win11Tweaks.ps1 | iex
```

This downloads and runs the latest script directly. It must be an **elevated** PowerShell
(there is no `.bat` self-elevation in this flow).

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

## Flags

| Flag | Effect |
|------|--------|
| `-DryRun` | Log what it WOULD do, change **nothing**. Run this first. |
| (none) | Actually apply the tweaks + install the apps. |
| `-Detailed` | Verbose console output (the log file is always full). |
| `-Machine PC\|Laptop` | Skip the "PC or Laptop?" question (gates HP / Alienware). |
| `-Reboot` | Reboot 15s after finishing (cancel with Ctrl+C). |
| `-LogDir <path>` | Different folder for the log (default: the script's folder). |

## Adding apps

Edit the arrays near the top of the install section of the script: `$script:AppsToInstall`
for winget apps (add winget IDs, e.g. `'Mozilla.Firefox'`), `$script:DirectApps` for
direct-download apps, or `$script:MachineApps` for PC/Laptop-gated apps.

## Notes

- **NVIDIA App** and **FL Studio** are not (reliably) on winget → the script downloads them
  **directly from the vendor** and installs them silently. NVIDIA App runs **only** if an NVIDIA
  GPU is present.
- Some direct installers return a non-standard exit code even on success (FL Studio returns
  `1223`), so the script verifies the actual install via Add/Remove Programs instead of trusting
  the exit code.
- **No undo and no restore point** — if you want to roll back, take a snapshot/backup yourself
  before the real run.
- **winget needs an interactive session** — run via `Run-Win11Tweaks.bat` (double-click) or the
  one-liner in an interactive elevated shell, not over SSH/remoting (winget fails with
  `0x8A15000F` otherwise).
- **.NET 3.5** pulls its payload from Windows Update — it succeeds on a machine with internet; on
  a box with WU blocked it keeps trying up to 30 minutes and then moves on.
- Grounded 1:1 in WinUtil v26.06.23 (`irm christitus.com/win`).
