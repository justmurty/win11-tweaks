# win11-tweaks — Design Spec

**Date:** 2026-07-11
**Author:** superuser + Claude
**Status:** Draft for review
**Target repo:** `gitlab.msuhost.com/msuhost/win11-tweaks`

---

## 1. Goal

A single, self-contained PowerShell script that applies **exactly** the the reference config
tweaks the user selected in the screenshot — **no GUI**, verbose DEBUG logging to
console **and** to a log file, so the script can be run on a Windows 11 machine and
the resulting log handed back for verification ("did it actually happen, what
succeeded, what failed").

Non-goals: no GUI, no interactive menus, no undo/revert engine (a System Restore
Point is created instead), no tweaks other than the 27 selected.

## 2. Source of truth

The screenshot is **the reference config, release `v26.06.23`**, i.e. exactly what
`irm the-reference-config | iex` serves today. All operations below were extracted
verbatim from that build's embedded `tweaks` config and its apply engine
(`the tweaks engine`, `the registry helper`, `the service helper`,
`the appx helper`, `the explorer-update helper`).

> Note: a newer `main` branch replaced the single `WPFTweaksDeBloat` item with a
> per-app removal panel and tweaked a couple of scripts (e.g. Windows AI). We
> deliberately follow **v26.06.23**, because that is the version the user runs.
> Minor UI label discrepancy ("Win11 Creator" tab) does not affect any tweak.

## 3. the reference config apply semantics we replicate

For each selected item, the reference config applies its sub-parts in this **order**:
`service → registry → InvokeScript → appx`. We mirror it. Details:

- **registry**: ensure `HKU:` PSDrive exists; create the key path if missing
  (`New-Item -Force`); if `Value == "<RemoveEntry>"` remove the property, else
  `Set-ItemProperty -Type -Value -Force`. On **apply** the written value is always
  the `Value` field (never `<RemoveEntry>`, which only appears in `OriginalValue`).
- **service**: **KeepServiceStartup** guard — only change a service's startup type
  if its *current* start type still equals the tweak's `OriginalType` (i.e. it has
  not already been customized by the user/another program). If the service is
  missing, log a warning and skip. Normalize the value `"Disable"` → `"Disabled"`
  (the reference config ships `"Disable"` for `lfsvc`, which is not a valid `Set-Service`
  value; we normalize so the intended effect actually applies).
- **InvokeScript**: run the ported command block (see §6 for the reference-internal
  substitutions we make, since functions like `the explorer-update helper` and
  `$sync.ThemeButton` do not exist outside the GUI).
- **appx**: for each package pattern, `Get-AppxPackage $Name -AllUsers |
  Remove-AppxPackage -AllUsers` **and** `Get-AppxProvisionedPackage -Online |
  ? DisplayName -like $Name | Remove-AppxProvisionedPackage -Online`.

## 4. Toggle semantics (decision: **apply ON only**)

"Customize Preferences" toggles encode a desired state. Per the user's decision,
the script applies **only the toggles that are ON** in the screenshot (writes each
toggle's `Value`). Toggles left OFF and unchecked checkboxes are **not touched**.
Some ON toggles are the Windows default (`DefaultState: true`) and are therefore
effectively idempotent no-ops (e.g. Game Mode, Taskbar Centered Icons, Settings
Home Page, Start Menu Recommendations = *shown*) — they are still applied as
requested, and flagged as such in the log.

## 5. The 27 selected operations (exact)

### Essential Tweaks (13)

| # | Id | Content | Operations |
|---|----|---------|-----------|
| 1 | WPFTweaksRestorePoint | Restore Point - Create | reg `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore\SystemRestorePointCreationFrequency=0` (DWord); script: `Enable-ComputerRestore -Drive $Env:SystemDrive` if no RP exists, then `Checkpoint-Computer -Description "System Restore Point created by the reference config" -RestorePointType MODIFY_SETTINGS`. **Runs FIRST.** |
| 2 | WPFTweaksActivity | Activity History - Disable | reg `HKLM:\SOFTWARE\Policies\Microsoft\Windows\System`: `EnableActivityFeed=0`, `PublishUserActivities=0`, `UploadUserActivities=0` (DWord) |
| 3 | WPFTweaksConsumerFeatures | ConsumerFeatures - Disable | reg `HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableWindowsConsumerFeatures=1` (DWord) |
| 4 | WPFTweaksDeliveryOptimization | Delivery Optimization - Disable | reg `HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization\DODownloadMode=0` (DWord) |
| 5 | WPFTweaksDiskCleanup | Disk Cleanup - Run | script: `cleanmgr.exe /d C: /VERYLOWDISK`; `Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase` |
| 6 | WPFTweaksEndTaskOnTaskbar | End Task With Right Click - Enable | reg `HKCU:\...\Explorer\Advanced\TaskbarDeveloperSettings\TaskbarEndTask=1` (DWord) |
| 7 | WPFTweaksDisableExplorerAutoDiscovery | File Explorer Automatic Folder Discovery - Disable | script: remove `...\Shell\Bags` and `...\Shell\BagMRU`; create `...\Bags\AllFolders\Shell`; set `FolderType="NotSpecified"` (String). Needs sign-out/restart. |
| 8 | WPFTweaksLocation | Location Tracking - Disable | service `lfsvc`→Disabled (from "Disable"); reg `...ConsentStore\location\Value="Deny"` (String), `...Sensor\Overrides\{BFA794E4-...}\SensorPermissionState=0` (DWord), `HKLM:\SYSTEM\Maps\AutoUpdateEnabled=0` (DWord) |
| 9 | WPFTweaksServices | Services - Set to Manual | services: `CscService`→Disabled, `DiagTrack`→Disabled, `MapsBroker`→Manual, `StorSvc`→Manual, `SharedAccess`→Disabled (each guarded by KeepServiceStartup vs its OriginalType); script: set `HKLM:\SYSTEM\CurrentControlSet\Control\SvcHostSplitThresholdInKB` = total physical RAM in KB |
| 10 | WPFTweaksTelemetry | Telemetry - Disable | 12 reg values (HKCU/HKLM, see appendix); script: `Set-MpPreference -SubmitSamplesConsent 2`, `Set-Service diagtrack Disabled`, `Set-Service wermgr Disabled`, machine env `POWERSHELL_TELEMETRY_OPTOUT=1`, remove `HKCU:\...\Siuf\Rules\PeriodInNanoSeconds` |
| 11 | WPFTweaksDeleteTempFiles | Temporary Files - Remove | script: `Remove-Item "$Env:Temp\*" -Recurse -Force`; `Remove-Item "$Env:SystemRoot\Temp\*" -Recurse -Force` |
| 12 | WPFTweaksDeBloat | Unwanted Pre-Installed Apps - Remove | appx (19): FeedbackHub, BingNews, BingSearch, BingWeather, Clipchamp, Todos, PowerAutomateDesktop, SolitaireCollection, SoundRecorder, StickyNotes, DevHome, Paint, OutlookForWindows, WindowsAlarms, StartExperiencesApp, GetHelp, ZuneMusic(Media Player), QuickAssist, MSTeams; script: uninstall classic Teams via `%LocalAppData%\Microsoft\Teams\Update.exe -uninstall` and delete its dir |
| 13 | WPFTweaksWPBT | WPBT - Disable | reg `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\DisableWpbtExecution=1` (DWord) |

### Advanced Tweaks — CAUTION (4)

| # | Id | Content | Operations |
|---|----|---------|-----------|
| 14 | WPFTweaksEdgeDebloat | Microsoft Edge - Debloat | 16 reg values under `HKLM:\SOFTWARE\Policies\Microsoft\Edge` (+ `\EdgeUpdate\CreateDesktopShortcutDefault=0`, + `\Edge\ExtensionInstallBlocklist\1="ofefcgjbeghpigppfmkologfjadafddi"`). Full list in appendix. |
| 15 | WPFTweaksRemoveOneDrive | Microsoft OneDrive - Remove | script: `icacls $Env:OneDrive /deny "Administrators:(D,DC)"`; `C:\Windows\System32\OneDriveSetup.exe /uninstall` (wait); `Stop-Process FileCoAuth,Explorer`; remove `%LocalAppData%\Microsoft\OneDrive` and `C:\ProgramData\Microsoft OneDrive`; `icacls $Env:OneDrive /grant`; clear empty OneDrive dir + user env var; `Set-Service OneSyncSvc Disabled` |
| 16 | WPFTweaksRightClickMenu | Right-Click Menu Previous Layout - Enable | script: `New-Item HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32 -Value "" -Force`; restart explorer |
| 17 | WPFTweaksWindowsAI | Windows AI - Disable And Remove | reg `HKLM:\...\Policies\Explorer\SettingsPageVisibility="hide:aicomponents"` (String), `HKLM:\SOFTWARE\Policies\WindowsNotepad\DisableAIFeatures=1` (DWord); script: CoreAI EndOfLife key, remove `*Copilot*` + `Microsoft.MicrosoftOfficeHub` appx, remove CoreAI pkg, `Set-Service WSAIFabricSvc Disabled`, `Disable-WindowsOptionalFeature -FeatureName Recall -Online -NoRestart` |

### Customize Preferences — toggles ON (10)

| # | Id | Content | Operation (ON) |
|---|----|---------|----------------|
| 18 | WPFToggleDarkMode | Dark Theme for Windows | `HKCU:\...\Themes\Personalize\AppsUseLightTheme=0`, `SystemUsesLightTheme=0` (DWord) + explorer refresh |
| 19 | WPFToggleShowExt | File Explorer File Extensions | `HKCU:\...\Explorer\Advanced\HideFileExt=0` (DWord) + explorer restart |
| 20 | WPFToggleGameMode | Game Mode | `HKCU:\Software\Microsoft\GameBar\AllowAutoGameMode=1`, `AutoGameModeEnabled=1` (DWord) *(Windows default)* |
| 21 | WPFToggleLoginBlur | Logon Screen Acrylic Blur | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\System\DisableAcrylicBackgroundOnLogon=0` (DWord) *(default)* |
| 22 | WPFToggleNumLock | Num Lock on Startup | `HKU:\.Default\Control Panel\Keyboard\InitialKeyboardIndicators=2` + `HKCU:\Control Panel\Keyboard\InitialKeyboardIndicators=2` (String) |
| 23 | WPFToggleStandbyFix | S0 Sleep Network Connectivity | `HKCU:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-...\ACSettingIndex=1` (DWord) *(default)* |
| 24 | WPFToggleHideSettingsHome | Settings Home Page | `HKCU:\...\Policies\Explorer\SettingsPageVisibility="show:home"` (String) *(default)* |
| 25 | WPFToggleStartMenuRecommendations | Start Menu Recommendations | 3× `HideRecommendedSection/IsEducationEnvironment=0` (DWord) + explorer restart *(default = recommendations shown)* |
| 26 | WPFToggleBatteryPercentage | System Tray Battery Percentage | `HKCU:\...\Explorer\Advanced\IsBatteryPercentageEnabled=1` (DWord) |
| 27 | WPFToggleTaskbarAlignment | Taskbar Centered Icons | `HKCU:\...\Explorer\Advanced\TaskbarAl=1` (DWord) + explorer restart *(default)* |

## 6. reference-internal substitutions

These GUI-only calls appear inside selected InvokeScripts and are replaced with a
standalone equivalent:

- `the explorer-update helper -action "restart"` → our `Update-Explorer -Action restart`
  (`taskkill /F /IM explorer.exe` + `Start-Process explorer.exe`).
- `the explorer-update helper` (default refresh) → our `Update-Explorer -Action refresh`
  (broadcast `WM_SETTINGCHANGE "ImmersiveColorSet"` via `SendMessageTimeout`).
- `if ($sync.ThemeButton.Content ...) { the theme helper ... }` (DarkMode) →
  **dropped** (GUI theme-button branch); the registry writes already switch dark mode,
  the refresh is preserved.

**Explorer restart is deferred:** tweaks that ask for a restart set a flag; the
script performs **one** explorer restart at the very end (DarkMode's soft refresh is
done inline). Avoids repeatedly killing explorer mid-run.

## 6a. Install software phase (winget) — runs AFTER all tweaks

Per the user's decision, once the 27 tweaks complete, the script installs the
user's chosen applications via **winget** (the reference config's default manager), plus one
Windows Feature. Lists live in clearly-commented, **easily-extensible** arrays near
the top of the script (the user plans to add more apps over time).

- **Auto-install via winget (`$AppsToInstall`, 13):** `Microsoft.DirectX`,
  `RevoUninstaller.RevoUninstaller`, `Google.Chrome`, `Nextcloud.NextcloudDesktop`,
  `Bitwarden.Bitwarden`, `Discord.Discord`, `Valve.Steam`,
  `EpicGames.EpicGamesLauncher`, `OBSProject.OBSStudio`, `Blizzard.BattleNet`,
  `Ubisoft.Connect`, `CPUID.HWMonitor`, `NZXT.CAM`.
  (IDs verified against Microsoft `winget-pkgs`; the reference-listed ones match
  the reference config, the rest — DirectX/Battle.net/NZXT — verified directly.)
- **Prompted via winget (`$AppsToPrompt`, 2):** `AnyDesk.AnyDesk`,
  `HPInc.HPSupportAssistant`. For each, `Read-Host "Install <name>? (y/N)"`; install
  only on `y`. In `-DryRun` or a non-interactive session, the prompt is skipped and
  logged as "skipped (prompt)".
- **.NET Framework 2/3/4 (Windows Feature, not winget):** exactly as the reference config's
  `WPFFeaturesdotnet` — `Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart`
  and `... -FeatureName NetFx4-AdvSrvs -All -NoRestart`. Runs in the install phase.
- **NVIDIA App:** **skipped** (not available on winget under any publisher; NVIDIA
  distributes it only via direct download). Logged as `SKIPPED — install manually`.
  A direct-download handler can be added later.
- **Winget presence:** `Get-Command winget`. If missing, log ERROR with guidance
  (install "App Installer" / `Microsoft.DesktopAppInstaller`) and skip the install
  phase (tweaks unaffected). *Modern Win11 ships winget; the reference config auto-installs it —
  a bootstrap can be added later if needed.*
- **Install command** (mirrors the reference config, `+ --accept-source-agreements` for headless
  safety):
  `winget install <id> --accept-package-agreements --accept-source-agreements --source winget --silent`
  via `Start-Process -FilePath winget -NoNewWindow -Wait`.
- **Per app:** log `▶ [n/m] install <id>`, run, capture exit code, log ✔/✖. An
  already-installed app ⇒ winget upgrades or reports no update ⇒ treated as success.
- **DryRun:** logs `[DRYRUN] would winget install <id>`, installs nothing.
- **Manager:** winget-only for now. A requested app with no winget ID is flagged in
  the log; per-app Chocolatey fallback can be added on request.
- Install results feed the final summary (installed / failed / skipped).

## 7. Script architecture (`Invoke-Win11Tweaks.ps1`)

Single self-contained `.ps1`, no external dependencies, no GUI.

- **Header:** `#Requires -RunAsAdministrator`; params `[-DryRun] [-LogDir <path>]`.
- **Bootstrap:** create `HKU:` PSDrive; set `$ErrorActionPreference` per-helper;
  `Start-Transcript` to the log file; print an environment banner (see §8).
- **Primitive helpers** (all DryRun-aware, all log via `Write-Log`):
  - `Write-Log -Level DEBUG|INFO|OK|WARN|ERROR -Message` — timestamped, colored
    console line + appended to log.
  - `Set-Reg -Path -Name -Type -Value` — mirrors `the registry helper`.
  - `Set-Svc -Name -StartupType [-OriginalType]` — mirrors `the service helper` +
    KeepServiceStartup guard + `"Disable"`→`"Disabled"` normalization.
  - `Remove-Appx -Name` — mirrors `the appx helper` (AllUsers + provisioned).
  - `Invoke-Step -Description -Action {}` — for raw command blocks: in DryRun logs the
    description and skips; else runs `Action` in try/catch and logs OK/ERROR.
  - `Update-Explorer -Action refresh|restart`.
  - `Install-App -Id` — `winget install <id> --accept-package-agreements
    --accept-source-agreements --source winget --silent`; DryRun-aware; logs.
  - `Enable-Feature -Name` — `Enable-WindowsOptionalFeature -Online -FeatureName
    <name> -All -NoRestart`; DryRun-aware; logs.
- **Tweak table:** an ordered array of objects
  `@{ Id; Content; Category; Apply = { <uses helpers> } }`, one per selected item,
  RestorePoint first.
- **Runner:** iterate the table; per item log `▶ [n/27] <Content>`; run `Apply` in
  try/catch; record `OK | FAILED (<reason>) | SKIPPED`; continue on failure (one bad
  tweak never aborts the run).
- **Install phase:** after the tweak loop — (1) enable the .NET feature(s) via
  `Enable-Feature`; (2) `Install-App` each of `$AppsToInstall`; (3) for each of
  `$AppsToPrompt`, `Read-Host` y/N then `Install-App` on yes; (4) log NVIDIA App as
  `SKIPPED`. Each step logs `▶ [n/m] …` and ✔/✖/SKIPPED. Requires winget present;
  the whole phase is skipped (logged) if winget is missing or all lists are empty.
- **Finish:** single deferred explorer restart if flagged; print a summary table
  (counts + per-item status, tweaks **and** installs); print the **log file path**
  prominently; print a "reboot recommended" notice (script never auto-reboots).

## 8. Logging / DEBUG design

- `Start-Transcript` captures *everything* (all `Write-Host`, native exe output,
  warnings, errors) to the log file — this is the raw artifact to send back.
- `Write-Log` adds structured, greppable lines:
  `2026-07-11 12:00:00.123 [INFO ] [WPFTweaksActivity] Set HKLM:\...\EnableActivityFeed = 0`.
- **Environment banner** at start (DEBUG): timestamp, hostname, Windows edition +
  build (`Get-CimInstance Win32_OperatingSystem`), PowerShell version, `IsElevated`,
  execution mode (DryRun/Apply), log file path.
- Each helper logs its intended action *before* doing it, and the outcome after, so a
  failure is always bracketed by context.
- Default verbosity is DEBUG (everything). No `-Verbose` needed.

## 9. Run modes

- **`-DryRun`** (recommended first run): performs **no** system changes. Every helper
  logs `[DRYRUN] would <action>` instead of executing. Produces a full log of the
  intended plan to review before touching the machine.
- **default (Apply):** performs the changes.

## 10. Safety

- System Restore Point created first (item 1) — the revert path (no custom undo).
- Never auto-reboots; prints a reboot/sign-out reminder (several tweaks need it).
- Runs continue past individual failures; failures are captured, not fatal.
- Requires elevation; refuses to run non-elevated (HKLM writes/services need admin).
- Execution: `powershell -ExecutionPolicy Bypass -File .\Invoke-Win11Tweaks.ps1 [-DryRun]`
  (also documented for `pwsh` 7).

## 11. Explicitly excluded (not selected in screenshot)

DNS combobox (Cloudflare), O&O ShutUp10, Ultimate Performance profiles, Xbox &
Gaming Components - Remove, and every unchecked checkbox / OFF toggle. No undo mode.

## 12. Deliverables & repo layout

```
win11-tweaks/
├─ Invoke-Win11Tweaks.ps1      # the script (the deliverable)
├─ README.md                   # how to run, how to find/send the log, what it does
├─ docs/
│  ├─ 2026-07-11-win11-tweaks-design.md   # this spec
│  └─ 2026-07-11-win11-tweaks-plan.md     # implementation plan (next step)
└─ .gitignore                  # ignore local *.log
```
Pushed to `gitlab.msuhost.com/msuhost/win11-tweaks`.

## 13. Open assumptions

- Target is Windows 11 (24H2/25H2-ish), run as Administrator, with internet not
  required (no downloads except what individual MS uninstallers do).
- `winget` is used **only** for the install phase (§6a); no tweak requires it (the
  `main` Windows-AI winget line is intentionally excluded). If the install list is
  empty or winget is absent, the tweaks still run fully.
- Log file default location: **the script's own folder** —
  `<script dir>\win11-tweaks_<yyyyMMdd_HHmmss>.log` — so it sits right next to the
  script for easy retrieval; falls back to Desktop if the script dir is unknown/unwritable.
  (Overridable with `-LogDir`.)

## Appendix A — Telemetry (item 10) full registry list

`HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo\Enabled=0`,
`HKCU:\...\Privacy\TailoredExperiencesWithDiagnosticDataEnabled=0`,
`HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy\HasAccepted=0`,
`HKCU:\Software\Microsoft\Input\TIPC\Enabled=0`,
`HKCU:\Software\Microsoft\InputPersonalization\RestrictImplicitInkCollection=1`,
`...\RestrictImplicitTextCollection=1`,
`HKCU:\...\InputPersonalization\TrainedDataStore\HarvestContacts=0`,
`HKCU:\Software\Microsoft\Personalization\Settings\AcceptedPrivacyPolicy=0`,
`HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection\AllowTelemetry=0`,
`HKCU:\...\Explorer\Advanced\Start_TrackProgs=0`,
`HKLM:\SOFTWARE\Policies\Microsoft\Windows\System\PublishUserActivities=0`,
`HKCU:\Software\Microsoft\Siuf\Rules\NumberOfSIUFInPeriod=0` (all DWord).

## Appendix B — Edge Debloat (item 14) full registry list

`HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate\CreateDesktopShortcutDefault=0`;
under `HKLM:\SOFTWARE\Policies\Microsoft\Edge`: `PersonalizationReportingEnabled=0`,
`ShowRecommendationsEnabled=0`, `HideFirstRunExperience=1`, `UserFeedbackAllowed=0`,
`ConfigureDoNotTrack=1`, `AlternateErrorPagesEnabled=0`, `EdgeCollectionsEnabled=0`,
`EdgeShoppingAssistantEnabled=0`, `MicrosoftEdgeInsiderPromotionEnabled=0`,
`ShowMicrosoftRewards=0`, `WebWidgetAllowed=0`, `DiagnosticData=0`,
`EdgeAssetDeliveryServiceEnabled=0`, `WalletDonationEnabled=0`,
`DefaultBrowserSettingsCampaignEnabled=0` (all DWord); plus
`\ExtensionInstallBlocklist\1="ofefcgjbeghpigppfmkologfjadafddi"` (String).

## Appendix C — Unwanted Pre-Installed Apps (item 12) exact package IDs

Removed via `Remove-Appx` (AllUsers + provisioned), in this order:
`Microsoft.WindowsFeedbackHub`, `Microsoft.BingNews`, `Microsoft.BingSearch`,
`Microsoft.BingWeather`, `Clipchamp.Clipchamp`, `Microsoft.Todos`,
`Microsoft.PowerAutomateDesktop`, `Microsoft.MicrosoftSolitaireCollection`,
`Microsoft.WindowsSoundRecorder`, `Microsoft.MicrosoftStickyNotes`,
`Microsoft.Windows.DevHome`, `Microsoft.Paint`, `Microsoft.OutlookForWindows`,
`Microsoft.WindowsAlarms`, `Microsoft.StartExperiencesApp`, `Microsoft.GetHelp`,
`Microsoft.ZuneMusic`, `MicrosoftCorporationII.QuickAssist`, `MSTeams`.
Then the classic-Teams uninstall via `Update.exe -uninstall`.

**Kept** (not in the reference v26.06.23 debloat list): Calculator, Photos, Camera,
Notepad, Snipping Tool, Copilot app, Phone Link, Microsoft 365 hub, Mobile Devices,
Xbox app/Game Bar/Identity/TCUI (those are a separate, *unselected* "Xbox & Gaming
Components - Remove" item).
