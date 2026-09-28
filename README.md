# win11-tweaks

A single, no-GUI PowerShell script that applies a fixed set of Windows 11 tweaks,
then installs a defined application set (winget +
direct downloads), and finally enables the .NET features. The console shows a compact view of
the run (see [The console](#the-console)); every detail goes to a log file for later.

## What it does

- **55 tweaks** — 25 standard (Essential + Advanced + Customize Preferences toggles) + 30
  custom (shortcut-arrow off, Spotlight off + default wallpaper, **Ultimate Performance** on a PC — on a
  laptop **Ultimate on the charger, Balanced on battery** (one plan, it switches by itself); a Ryzen X3D
  with two CCDs (7950X3D, 9950X3D...) keeps **Balanced**: AMD's V-Cache driver needs its core parking,
  **Memory Integrity / VBS off** for gaming, mouse acceleration off, DNS → Cloudflare,
  Explorer → This PC, taskbar cleanup (Search / Task view / Widgets / Chat / Resume off),
  **web/Bing, Store, highlights and cloud results in Start search off**, remove the Edge desktop
  shortcut, and since v1.6.0:
  - **tips, suggestions and ads off** — Start (tips / promoted apps, account nags, the phone panel),
    "Let's finish setting up your device", the welcome page after updates, suggestions in Settings,
    ad and backup-nag notifications, OneDrive banners in Explorer, feedback surveys, the Settings
    **Home page** (Game Pass / Microsoft 365 cards; Settings opens on System);
  - **Start's pinned ads cleared** (an empty Start layout — once per profile, a re-run keeps your pins);
  - **lock screen** without Spotlight pictures, fun facts or widgets;
  - **more apps removed** — Widgets (the whole app, not just the button), Phone Link + Cross Device,
    dead Microsoft apps (Cortana, Maps, Mail and Calendar, Skype, 3D Viewer, Mixed Reality Portal, the old
    Xbox Console Companion), and on the **first run only** promo apps (Spotify, Disney+, TikTok,
    Instagram, Facebook, LinkedIn, Candy Crush, Prime Video, Family Safety, Movies & TV) — a re-run
    leaves Store apps you installed since alone; **OEM trialware** Store apps (McAfee, Dropbox and
    Booking.com promos, HP / Dell / ASUS promo apps — hardware tools stay); desktop McAfee / Norton /
    ExpressVPN have no silent uninstall, so the summary lists them WARN with the tool that removes them;
  - removed apps **stay removed** (Windows Update's reinstall entries for the new Outlook, Dev Home and
    Cross Device are deleted);
  - **old components removed** at the end, after .NET 3.5 (Windows completes the removal at the next
    restart) — Steps Recorder, Math Recognizer, Internet Explorer mode, PowerShell ISE, Print Management,
    Work Folders, Windows Media Player Legacy (kept when it is the only video player), and **VBScript**
    last, after the installs (command-line activation with `slmgr.vbs` needs it — activate in Settings,
    or add it back under Optional features; **kept on AMD machines**: AMD's chipset installer runs a
    VBScript);
  - **Edge** doesn't preload or run after it's closed, downloads no local AI model, no news / promo
    tabs / default-browser and sign-in nags / sidebar;
  - **rarely used services to Manual** — Fax, Downloaded Maps Manager, Retail Demo, Phone Service, Mobile
    Hotspot, Geolocation, Parental Controls, Assigned Access Manager, Windows Insider, Payments and NFC,
    Wallet, WAP Push, Smart Card, Remote Desktop (+ Configuration, UserMode
    Port Redirector), Telephony, TCP/IP NetBIOS Helper; **Disabled**: Connected User Experiences and
    Telemetry, Routing and Remote Access (a service that is Disabled is never raised to Manual);
  - **Copilot** "share" button on taskbar previews and Click to Do off; **Windows Error Reporting** off;
    the **Sticky / Filter / Toggle Keys** pop-ups (5× Shift in a game) off; **no automatic restart**
    while someone is signed in; **hibernation off** on a PC (frees `hiberfil.sys`); **no network while
    asleep on battery** on a laptop;
  - **monitors on their highest refresh rate** (a 144 / 165 Hz monitor often comes set to 60 Hz) — on a PC,
    over **DisplayPort** (an HDMI screen is only logged with what it could do: an older cable, a KVM or an
    adapter can fail at a rate Windows lists and leave the screen black), at the very end: without the real
    GPU driver Windows only offers 60 Hz, and that driver often arrives during the run (if a screen stayed at
    60 Hz, run the script again once the driver is in).

  New since v1.6.0 (in the one-liner now, in the next release): **a call no longer turns the game
  down** (Windows lowers every other sound by 80% while a call runs — set to "Do nothing"), and the
  **clipboard history (Win+V)** is on from the first press (on this PC only, nothing synced to the cloud).

  Fixed in v1.6.0: Activity History no longer breaks the clipboard history (Win+V), Get Help stays
  (the Settings troubleshooters need it), "ConsumerFeatures" now also works on Pro. Details:
  [`docs/2026-07-11-win11-tweaks-design.md`](docs/2026-07-11-win11-tweaks-design.md).
- Shows the **MSUHost banner**, asks **`Continue? (Y/n)`**, then two small menus (one option per line,
  answered with `Select [1/2]`). **`Is this a PC or a Laptop?`** — `[1] PC` / `[2] Laptop`.
  On a laptop the power plan is **Ultimate on the charger, Balanced on battery** (plain Ultimate would
  keep the CPU from idling on battery), hibernation and the panel's refresh rate stay as they are, and
  **NZXT CAM** isn't installed (it's for desktop NZXT coolers/cases).
- Then **`[1] Gele, is that you?`** / **`[2] New user`**. `1`: the full app set, as always. `2`: one **`(Y/n)`**
  question per app (Enter = yes) before anything is downloaded; after the last answer the run goes on
  by itself and installs only the picked apps (the rest show as SKIPPED "not selected"). Visual C++,
  DirectX and .NET 3.5 are always installed. NVIDIA App is only offered with an NVIDIA card, Alienware
  Command Center only on Alienware / Dell G hardware. Then **`Keep these Windows apps?`** — Paint and
  Media Player (Enter keeps them, `n` removes them; Gele isn't asked — they go). Otherwise the tweaks
  are the same for both.
- Then the **install phase**: **12 Visual C++ redists** + **15 winget apps**
  (incl. VLC, Lightshot, TurboTop, WinRAR; NZXT CAM on a PC only) + **6 direct-download**
  (**Google Chrome**, **NVIDIA App** only if an NVIDIA GPU is present — found by its PCI ID, so also
  before its driver is in, **Bitwarden**, **Parsec**, **Google Play Games**, **FL Studio**) + on a PC the
  **drivers from the maker's own site** (not Windows Update), picked by the hardware: **AMD Chipset
  Software** on a Ryzen board, **Intel Chipset Device Software** on an Intel one, **AMD Software:
  Adrenalin** with a Radeon card and no NVIDIA one (every download must carry the vendor's signature or
  it isn't run; a laptop keeps its maker's drivers; nothing of this in a virtual machine) +
  **Alienware Command Center**, installed only on
  Alienware / Dell G-series hardware, desktop or laptop (a New user is asked). It also applies the
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

## The console

A rail down the left, from the questions to the result:

```
  ┌  MSUHost  win11-tweaks 1.6.0
  ?  Continue? (Y/n) › y
  ?  Who is it?  1 Gele  2 New user  › 1
  ├─ WIN11-TEST · Windows 11 Pro 25H2 (26200) · PC · Gele
  ├─ Tweaks
  │  √ Privacy           telemetry, activity history, location, error reports        4.3s
  │  ! Edge              Microsoft Edge - Debloat: 1 step(s) failed - see the log     140ms
  ├─ Apps
  │  √ Battle.net                      + desktop icon                              1m 18s
  │  × Google Chrome                   installer exit code 1603, see the log       1m 01s
  │  ► Epic Games Launcher             installing                                   00:07
  ├─ .NET 3.5   ready · downloaded next to the apps
  ├─ Finishing
  └─ Done in 19m 29s   93 OK · 7 skipped · 0 failed
     ► Restart the PC to finish. Windows completes some changes only at a restart.
```

The tweaks show as groups once they're done; every app gets its line with its time; the step
running now is one live line with a clock, redrawn in place. Problems are listed again at the
end. It uses only the 16 console colours and characters every Windows console font has, so it
looks the same in Windows Terminal and in the old console. `-Detailed` shows the full log on
the console instead (the old view).

## The log

The log is written **in the same folder as the script**, named:

```
win11-tweaks_YYYYMMDD_HHMMSS.log
```

The console shows the log path at the end. Lines are timestamped and levelled
(`[DEBUG] [INFO] [OK] [WARN] [ERROR]`), with a summary table at the end. A compact
`*_results.txt` is written alongside it. The log file always has every detail (use `-Detailed`
to see it on the console as the run goes).

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
| `-Detailed` | The full log on the console instead of the rail (the log file is always full). |
| `-Machine PC\|Laptop` | Skip the "PC or Laptop?" question (`Laptop`: Ultimate only on the charger, keeps hibernation and the panel's refresh rate, no NZXT CAM; `PC`: plain Ultimate, no battery tweaks). |
| `-Reboot` | Reboot 15s after finishing (cancel with Ctrl+C). |
| `-LogDir <path>` | Different folder for the log (default: the script's folder). |

## Adding apps

Edit the arrays near the top of the install section of the script: `$script:AppsToInstall`
for winget apps (add winget IDs, e.g. `'Mozilla.Firefox'`), `$script:DirectApps` for
direct-download apps, or `$script:VendorApps` for apps that belong on one vendor's hardware
(`Hardware` is a regex matched against the PC's manufacturer + model). A new app is offered to a
New user automatically; if everyone must get it without being asked, also add its winget ID to
`$script:RuntimeApps`.

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
  before the real run. The script remembers a few things on the PC under `HKLM\SOFTWARE\win11-tweaks`:
  `PromoAppsRemoved` (the date the promo apps went — later runs leave Store apps alone) and
  `PcPowerPlan` / `LaptopPowerPlan` (the power plan it made, so a re-run reuses it). The old Start
  layout is kept as `start2.bin.win11-tweaks.bak` next to the new one.
- **winget needs an interactive session** — run via `Run-Win11Tweaks.bat` (double-click) or the
  one-liner in a PowerShell window on the PC itself, not over SSH/remoting (winget fails with
  `0x8A15000F` otherwise).
- **.NET 3.5** pulls its payload from Windows Update. It's started early (in parallel with the app
  installs) and the script **waits** for it to finish at the end, showing a live one-line heartbeat.
  On a normal connection this is seconds; on a WU-throttled box it can take ~30 min. Ctrl+C stops
  the script there (the summary is still written — see [The log](#the-log)), and .NET 3.5 keeps
  installing in the background (`/NoRestart`, so no surprise reboot — just don't reboot until
  it's done). The last steps (old components, refresh rate, VBScript) come after that wait, so
  after a Ctrl+C there run the script again once .NET 3.5 is done. When Windows is already
  waiting for a restart (a Windows update, or the components an earlier run removed), it installs
  .NET 3.5 but finishes it only at that restart: the run then says
  `Done! (finishes at the next restart)` and ends with "Restart the PC to finish".
