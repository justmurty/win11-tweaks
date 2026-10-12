# win11-tweaks

A single PowerShell script that applies a fixed set of Windows 11 tweaks,
then installs a defined application set (winget +
direct downloads), and finally enables the .NET features. A window asks the setup questions and
shows the run as it goes (see [The window](#the-window)); `-Console` keeps it in the console.
Every detail goes to a log file for later.

## What it does

- **56 tweaks** — 25 standard (Essential + Advanced + Customize Preferences toggles) + 31
  custom (shortcut-arrow off, Spotlight off + the **Windows (dark)** theme with its dark wallpaper,
  the **MSUHost Cursors** mouse pointer inside a theme of ours, **MSUHost (dark)**,
  **Ultimate Performance** on a PC — a laptop keeps **Windows' own power plan** (the "Ultimate on the
  charger, Balanced on battery" plan of v1.6 / v1.7 is removed); a Ryzen X3D
  with two CCDs (7950X3D, 9950X3D...) keeps **Balanced**: AMD's V-Cache driver needs its core parking,
  mouse acceleration off, DNS → Cloudflare,
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
    Work Folders, Windows Media Player Legacy (the new Media Player stays), and **VBScript**
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
  - **Copilot** removed (the Copilot app and Microsoft 365 Copilot, for every user and new accounts), its
    "share" button on taskbar previews and Click to Do off; **Paint** and **Media Player** always stay;
    **Windows Error Reporting** off;
    the **Sticky / Filter / Toggle Keys** pop-ups (5× Shift in a game) off; **no automatic restart**
    while someone is signed in; **hibernation off** on a PC (frees `hiberfil.sys`); **no network while
    asleep on battery** on a laptop;
  - **monitors on their highest refresh rate** (a 144 / 165 Hz monitor often comes set to 60 Hz) — on a PC,
    over **DisplayPort** (an HDMI screen is only logged with what it could do: an older cable, a KVM or an
    adapter can fail at a rate Windows lists and leave the screen black), at the very end: without the real
    GPU driver Windows only offers 60 Hz, and that driver often arrives during the run (if a screen stayed at
    60 Hz, run the script again once the driver is in).

  New in v1.10.0: **Brave** next to Google Chrome — its box in the window is empty; picked, it goes in
  for every user and onto the taskbar. The taskbar now pins **the browsers picked**: Chrome, Brave or
  both (Chrome too only when it was picked, not just because it is on the PC). **A new mouse pointer**
  on every PC: **MSUHost Cursors** (Windows 11 Cursors Concept by JepriCreations), inside the theme **MSUHost (dark)**
  (the Windows (dark) theme with these cursors), so it stays after a restart and when the theme is
  picked again in Settings (credits: [`assets/CURSORS.md`](assets/CURSORS.md)). The window's footer
  shows only the counts (no "low-end").

  New in v1.9.0: **Low-end PC** — a box in the window, empty by default (see [Low-end PC](#low-end-pc)):
  for a weak PC it turns off animations, transparency, Windows Search and its indexing, background apps,
  Game DVR and Storage Sense, starts Windows with every processor, makes Defender's scans lighter, puts a
  plugged-in laptop on Best performance, and at the end keeps the launchers (Steam, Discord, Battle.net…)
  from starting with Windows. And **no install can hold the run any more**: one that takes over 30 minutes
  (a setup waiting on a question nobody sees) is stopped and listed as failed, and the run goes on.

  New in v1.8.1: **Core Isolation (Memory Integrity) stays on** — the script no longer
  turns it off. A PC that ran an earlier version has it off: turn it on in Windows Security > Device
  security > Core isolation (Windows checks the drivers first), then restart. Fixed: **the taskbar pins
  disappeared after the first restart** — they now go through Windows' own taskbar layout (see below).
  New: **ASUS DriverHub**
  on an ASUS motherboard (ASUS's own driver tool — Armoury Crate no longer offers drivers): at the end
  of the run its page opens, and **Install all** there puts in the board's drivers (ASUS has no way to
  do that without the click). **Roland's driver** when a Rubix 22 / 24 / 44 audio interface is plugged
  in. While it runs, and until its window is closed, **the PC doesn't sleep and the screen stays on**;
  a window that can no longer draw leaves the whole run and its summary in the console. A download that
  stopped part-way (Razer's server drops connections) now gets its rest instead of failing as "not signed".
  **Windows activation**: when Windows is not activated, the run's first step puts in the product key that
  comes with the script and activates Windows online (Settings > Activation opens if that does not work).

  New in v1.8.0: **one app list, everything picked** — take off what you don't want (a row at a time,
  or all); **PC or laptop is detected**, not asked; the apps for **this PC's hardware** are found, not
  asked (NVIDIA App, AMD / Intel chipset drivers, Intel Driver & Support Assistant, Adrenalin, NZXT CAM,
  Armoury Crate, Alienware Command Center); **what is already installed goes to the latest**; new apps
  (U.GG, Rockstar Games Launcher, TreeSize, qBittorrent, MSI Afterburner, Razer Synapse, Vencord, iTunes,
  Apple Devices);
  a laptop keeps Windows' own power plan; the Windows (dark) theme; Copilot removed.

  New in v1.7.0: **a window** that asks the setup
  questions and shows the run (see [The window](#the-window)), **a call no longer turns the game
  down** (Windows lowers every other sound by 80% while a call runs — set to "Do nothing"), and the
  **clipboard history (Win+V)** is on from the first press (on this PC only, nothing synced to the cloud).

  Fixed in v1.6.0: Activity History no longer breaks the clipboard history (Win+V), Get Help stays
  (the Settings troubleshooters need it), "ConsumerFeatures" now also works on Pro. Details:
  [`docs/2026-07-11-win11-tweaks-design.md`](docs/2026-07-11-win11-tweaks-design.md).
- Shows the **MSUHost banner** and asks **`Continue? (Y/n)`**. **PC or laptop** is detected from what
  the PC reports: a laptop / notebook / convertible case or a Mobile power profile = laptop; a desktop
  case = PC, even with a UPS "battery"; otherwise a battery = laptop. `-Machine` overrides it. A laptop
  gets no power plan of ours (Windows' own stays); hibernation and the panel's refresh rate stay as
  they are.
- The window lists **every app, picked** — but **Brave** (empty, click it to add it): click one to leave it out, a row's name (Games, Tools...) for
  the whole row, **Deselect all** / **Select all**. **Drivers & hardware** lists only what this PC's
  hardware needs. The run lists only what it installs: the apps taken off, and the ones for hardware
  this PC does not have, are in the log only. Visual C++, DirectX (Microsoft's End-User Runtime - the
  D3DX / XInput / XAudio files older games and MSI Afterburner need) and .NET 3.5 always go in. On the
  console (no window) everything goes in but Brave.
- Then the **install phase**: **12 Visual C++ redists** + **21 winget apps**
  (incl. **Brave** when it is picked, VLC, Lightshot, TurboTop, WinRAR, TreeSize, qBittorrent, MSI Afterburner; **iTunes** and **Apple
  Devices** from the Microsoft Store, the way Apple offers them for Windows 11; **NZXT CAM** only
  where an NZXT device is found) + **direct downloads** from the vendor (**Google Chrome**, **Bitwarden**,
  **Parsec**, **Google Play Games**, **FL Studio**, **U.GG**, **Rockstar Games Launcher**, **Razer
  Synapse** — just Synapse and Razer App Engine it runs on, silent —, **Vencord** into the signed-in
  user's Discord; **NVIDIA App**
  only if an NVIDIA GPU is present — found by its PCI ID, so also before its driver is in) + on a PC the
  **drivers from the maker's own site** (not Windows Update), picked by the hardware: **AMD Chipset
  Software** on a Ryzen board, **Intel Chipset Device Software** on an Intel one plus **Intel Driver &
  Support Assistant** with any Intel device (it keeps the Intel drivers current), **AMD Software:
  Adrenalin** with a Radeon card and no NVIDIA one (every download must carry the vendor's signature or
  it isn't run; a laptop keeps its maker's drivers; nothing of this in a virtual machine) +
  **Alienware Command Center** on Alienware / Dell G-series hardware and **Armoury Crate** on an ASUS
  ROG / TUF / PRIME / ProArt board or a ROG / TUF laptop (ASUS's installer downloads it in the
  background; it finishes after a restart), desktop or laptop; **ASUS DriverHub** on any ASUS
  motherboard in a PC (the version ASUS's own feed names, signed by ASUS — its page opens at the end:
  **Install all**); **Roland's Rubix driver** when a Rubix 22 / 24 / 44 is plugged in (USB). Every direct
  download is checked to be whole — a server that drops the connection part-way (Razer's did) is asked for
  the rest for as long as it comes. It also applies the
  **WinRAR license** and enables **.NET 3.5**
  (incl. 2.0/3.0) **and .NET 4** via DISM (like "Turn Windows features on/off").
- At the end, the **taskbar**: File Explorer, **This PC** and the browsers picked — **Google Chrome**,
  **Brave** or both — pinned (a browser left out is not pinned even when it is on the PC; one an
  earlier run pinned stays on a re-run that doesn't pick it); the pins Windows
  comes with (Edge, Store, Microsoft 365 Copilot, Outlook) gone. Through Windows' own taskbar layout
  (this user's *Start Layout* policy → `%LOCALAPPDATA%\win11-tweaks\TaskbarLayout.xml`), so the pins
  stay after a restart; a pin you take off stays off, and a re-run doesn't touch a taskbar you changed.
- Already-installed apps (found via `winget list` + Add/Remove Programs) **go to the latest**:
  `winget upgrade`; FL Studio and AMD's chipset software (no updater of their own) when the vendor's
  latest file is newer than the installed version; the other direct downloads update themselves.
  An update that fails is a warning in the log, not a failure (one that hangs, e.g. on a question
  about the app running, is stopped after 15 minutes — check that app). DirectX and Visual C++
  2005–2013 are out of support and left alone.
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
irm https://win.msuhost.com | iex
```

(`win.msuhost.com` is a Cloudflare redirect to the script on `main`; the full address works too:
`irm https://gitlab.msuhost.com/superuser/win11-tweaks/-/raw/main/Invoke-Win11Tweaks.ps1 | iex`.)

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

## The window

The one-liner (and the `.bat`) open a dark window — nothing to install, it is part of the script
(WPF, built into Windows). Three screens:

- **Set up this PC** — the PC, its Windows and PC / laptop (detected), then the apps: every one
  picked but Brave (empty — click it to add it; picked, it is pinned to the taskbar too), in rows (Games, Chat & streaming, Media, Tools, Internet, and Drivers & hardware with only
  what this PC needs); click an app to leave it out, a row's name for the whole row, **Deselect all**
  / **Select all**; what always goes in. When Windows is **not activated**, a **Windows** row on top
  with **Windows 11 Pro** (picked): at Start the run's first step puts in the product key that comes
  with the script and activates Windows online (Windows' own licensing — no `slmgr`, so it works
  without VBScript too); with no key, a key Windows refuses, or no activation (no internet), Settings >
  System > Activation opens instead. The key never goes to the log — only its last 5 characters.
  Then **Performance**: the PC's RAM, cores / threads and disk (SSD / HDD), and the **Low-end PC**
  box — empty; pick it on a weak PC (see [Low-end PC](#low-end-pc)).
  **Start** (or Enter) / **Cancel** — Cancel changes nothing.
- **The run** — the clock, then the phases on one line down the left: Tweaks (n / N, then the
  groups), Apps (the last ones done with their times, the one installing now with its own clock,
  the next ones), .NET 3.5 (downloading in the background next to the apps), Finishing. **Log**
  opens the log; **Stop** asks first, then stops after the step running now (an installer that
  has started finishes) — the summary covers what ran.
- **Done** — how it went (OK · skipped · failed), every app it installed with its time, what needs a
  look, what to do now. **Open log**, **Close**, and **Restart now** when Windows needs a restart
  to finish.

The run itself is the same as in the console — the window only shows it (it has its own thread,
so it never waits on an installer). Once the window is up, the PowerShell window hides behind it:
the one the one-liner opens for the run closes with the window at the end; your own PowerShell
window (or the `.bat`'s) comes back with the summary line and the log path. If the window goes
early or has an error, the console comes back and shows the run — and if it can no longer draw
after the run, the console shows the whole run with its summary and what to do next (**Restart
the PC to finish**). From **Start** until the window is closed, Windows doesn't go to sleep or
turn the screen off (a laptop could sleep mid-install, and on a test PC the window broke once when
the screen came back on); closing the window gives Windows its own timers back. Without a desktop (SSH, a
service), with `-Console`, `-Detailed` or `-Reboot`, or if the window cannot open, the console
shows the run (below).

## Low-end PC

The **Low-end PC** box (window) or `-LowEnd` (console / `.bat`) adds, before the apps install:

| What | Where Windows has it |
|------|----------------------|
| Animations and shadows off ("Adjust for best performance") — **font smoothing and thumbnails stay** | System Properties > Advanced > Performance |
| Transparency off | Settings > Personalization > Colors |
| Windows Search and its indexing off (the service is Disabled) — Start still finds apps and settings; a search in File Explorer reads the files themselves (slower) | Services > Windows Search |
| Background apps off — Store apps only; Steam, Discord & co. are desktop apps and not affected | Settings > Apps > Installed apps > Advanced options |
| Game DVR off — Game Bar's recording (Win+Alt+R); OBS records, Game Bar stays | Settings > Gaming > Captures |
| Storage Sense off | Settings > System > Storage |
| Every processor at boot | msconfig > Boot > Advanced options > Number of processors |
| Defender's scheduled scans at low priority, at most 20% CPU — the same protection, a scan takes longer | (Defender preferences) |
| A laptop on the charger: Best performance (a PC has Ultimate Performance already; on battery it is left) | Settings > System > Power > Power mode |

and at the end, after the installs: **the launchers don't start with Windows** — Steam, Discord, Battle.net,
Epic, Ubisoft, Rockstar, U.GG, the EA app — switched off the way Task Manager > Startup apps does; they open as
usual when you start them. Lightshot, TurboTop, Razer Synapse, NZXT CAM and Nextcloud keep starting (they
have to run to work). Epic and Ubisoft add themselves on their first start — off in their own settings.

The animations and the processor count take effect at the next start: the end says **Restart**. Without the
box none of this is touched — nor turned back from an earlier run. "Number of processors" stays at this PC's
count: after a CPU with more cores, run the script again with the box (or clear the box in msconfig).
Hardware-accelerated GPU scheduling and Game Mode stay as they are (Game Mode is on anyway).

## The console

With `-Console` (and wherever there is no window): a rail down the left, from the questions to
the result:

```
  ┌  MSUHost  win11-tweaks 1.9.0
  ?  Continue? (Y/n) › y
  ├─ WIN11-TEST · Windows 11 Pro 25H2 (26200) · PC · all 27 apps
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

The log is written to **`%TEMP%\win11-tweaks\`** (out of the way - not on the Desktop), named:

```
win11-tweaks_YYYYMMDD_HHMMSS.log
```

The window shows the log path (and opens it: **Log** / **Open log**), the console shows it at the end. The
script's own "Temporary Files" cleanup leaves that folder alone, so earlier runs' logs stay too.
`-LogDir <folder>` puts the log elsewhere. Lines are timestamped and levelled
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
| `-Console` | The rail in the console instead of the window. |
| `-LowEnd` | The **Low-end PC** box picked (the console: on) — see [Low-end PC](#low-end-pc). |
| `-Detailed` | The full log on the console instead of the rail (the log file is always full). |
| `-Machine PC\|Laptop` | PC or laptop without detecting it (`Laptop`: Windows' own power plan, keeps hibernation and the panel's refresh rate; `PC`: Ultimate, no battery tweaks). |
| `-Reboot` | Reboot 15s after finishing (cancel with Ctrl+C). An unattended run: the console, no window. |
| `-LogDir <path>` | Different folder for the log (default: `%TEMP%\win11-tweaks`). |

## Adding apps

Edit the arrays near the top of the install section of the script: `$script:AppsToInstall`
for winget apps (add winget IDs, e.g. `'Mozilla.Firefox'`), `$script:DirectApps` for
direct-download apps, or `$script:VendorApps` for apps that belong on one vendor's hardware
(`Hardware` is a regex matched against the PC's manufacturer + model). A new app shows up in the
window's list, picked — in its row if it is in `$script:AppGroups`, else under Other; one whose box
should start empty (installed only when picked in the window, never from the console) also goes in
`$script:AppsOffByDefault`, like Brave. If everyone
must get it without a choice, also add its winget ID to `$script:RuntimeApps`; an app for some
hardware only goes in `$script:HardwareApps` (with its check).

## Notes

- **NVIDIA App** and **FL Studio** are not (reliably) on winget → the script downloads them
  **directly from the vendor** and installs them silently. NVIDIA App runs **only** if an NVIDIA
  GPU is present.
- **Vencord** comes from the Vencord organisation's GitHub releases (its command-line installer — not
  code-signed, Vencord says so on its page). It patches the signed-in user's Discord and closes
  Discord for that; without Discord it is left out (the log says "needs Discord").
- Some direct installers return a non-standard exit code even on success (FL Studio returns
  `1223`), so the script verifies the actual install via Add/Remove Programs instead of trusting
  the exit code.
- winget gets the same check: when it reports a failure, the script looks for the app before
  calling it FAILED. Battle.net's setup finishes after winget has stopped waiting for it (winget
  says "Installation abandoned"), so in that case the script gives it up to 5 minutes to land.
- **No undo and no restore point** — if you want to roll back, take a snapshot/backup yourself
  before the real run. The script remembers a few things on the PC under `HKLM\SOFTWARE\win11-tweaks`:
  `PromoAppsRemoved` (the date the promo apps went — later runs leave Store apps alone) and
  `PcPowerPlan` (the power plan it made, so a re-run reuses it; v1.6 / v1.7's `LaptopPowerPlan` goes
  with its plan). The old Start
  layout is kept as `start2.bin.win11-tweaks.bak` next to the new one.
- **winget needs an interactive session** — run via `Run-Win11Tweaks.bat` (double-click) or the
  one-liner in a PowerShell window on the PC itself, not over SSH/remoting (winget fails with
  `0x8A15000F` otherwise).
- **.NET 3.5** pulls its payload from Windows Update. It's started early (in parallel with the app
  installs) and the script **waits** for it to finish at the end, showing a live one-line heartbeat.
  On a normal connection this is seconds; on a WU-throttled box it can take ~30 min. Ctrl+C stops
  the script there (the summary is still written — see [The log](#the-log)), and .NET 3.5 keeps
  installing in the background (`/NoRestart`, so no surprise reboot — just don't reboot until
  it's done). The last steps (taskbar pins, old components, refresh rate, VBScript) come after that
  wait, so after a Ctrl+C there run the script again once .NET 3.5 is done. When Windows is already
  waiting for a restart (a Windows update, or the components an earlier run removed), it installs
  .NET 3.5 but finishes it only at that restart: the run then says
  `Done! (finishes at the next restart)` and ends with "Restart the PC to finish".
