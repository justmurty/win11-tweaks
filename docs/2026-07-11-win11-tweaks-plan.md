# win11-tweaks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single, no-GUI PowerShell script that applies the 27 selected WinUtil
tweaks and then installs a defined app set via winget, with DEBUG logging to console
and file, plus a `-DryRun` mode — runnable on Win11 to produce a log for review.

**Architecture:** One self-contained `Invoke-Win11Tweaks.ps1`. A handful of DryRun-aware
primitive helpers (`Set-Reg`, `Set-Svc`, `Remove-Appx`, `Invoke-Step`, `Update-Explorer`,
`Install-App`, `Enable-Feature`) mirror WinUtil's apply engine. An ordered data table of
27 tweak objects (each with an `Apply` scriptblock) is executed by a runner that logs
per-item status; then an install phase runs; then a summary prints. `Start-Transcript`
captures everything to the log file.

**Tech Stack:** Windows PowerShell 5.1 / PowerShell 7+ on Windows 11. No external modules.
winget for installs. No Pester (Windows-only runtime; see Testing Strategy).

## Global Constraints

- **Source of truth:** Chris Titus WinUtil **v26.06.23** (`irm christitus.com/win`). All
  registry paths/values/services/scripts/appx are verbatim from the spec
  (`docs/2026-07-11-win11-tweaks-design.md` §5 + appendices A/B/C). Do not invent values.
- **Platform:** Windows 11; **must run elevated** (Administrator). Refuse otherwise.
- **No GUI, no undo, no auto-reboot.** A System Restore Point is created **first**.
- **Toggles: apply ON only.** OFF toggles / unchecked items are never touched.
- **Per-tweak apply order:** `service → registry → InvokeScript → appx`.
- **Registry helper:** ensure `HKU:` PSDrive; create missing key path; if value is
  `<RemoveEntry>` remove the property, else `Set-ItemProperty -Type -Value -Force`.
- **Service helper:** KeepServiceStartup — change startup only if current == OriginalType;
  normalize `"Disable"` → `"Disabled"`; skip+warn if service missing.
- **Appx helper:** `Get-AppxPackage $Name -AllUsers | Remove-AppxPackage -AllUsers` **and**
  `Get-AppxProvisionedPackage -Online | ? DisplayName -like $Name | Remove-AppxProvisionedPackage -Online`.
- **winget install flags:** `install <id> --accept-package-agreements --accept-source-agreements --source winget --silent`.
- **Explorer restart deferred:** tweaks needing it set a flag; one restart at the very end.
- **DryRun makes zero system changes** — every helper logs `[DRYRUN] would …` and returns.
- **Logging:** default DEBUG. `Start-Transcript` + structured `Write-Log` lines
  `yyyy-MM-dd HH:mm:ss.fff [LEVEL] [Id] message`.

## Testing Strategy (read first)

This script is **Windows-only** and mutates the live registry/services/appx, so it cannot
be unit-tested on the authoring machine (macOS, no PowerShell). Verification tiers:

1. **Static:** PSScriptAnalyzer + AST parse via `pwsh` (install PowerShell locally if
   absent) — catches syntax/lint errors. This is the only automated gate available here.
2. **Dry run (primary acceptance):** user runs `-DryRun` on the Win11 target; the produced
   log is reviewed to confirm every intended action is listed and no errors occur.
3. **Real run:** user runs without `-DryRun`; log reviewed for per-item OK/FAILED.

Each task's "verify" step therefore = review the code against the spec + (where possible)
parse it. The **DryRun log on Win11** is the definition of done for the whole script.

## File Structure

- `Invoke-Win11Tweaks.ps1` — the entire script (params, helpers, data, runner, install,
  summary). Single file so the user can download-and-run one thing.
- `README.md` — what it does, how to run (elevated, `-ExecutionPolicy Bypass`), `-DryRun`
  first, where the log is, how to send it back.
- `.gitignore` — ignore `logs/` and `*.log`.
- `docs/2026-07-11-win11-tweaks-design.md` — spec (already written).
- `docs/2026-07-11-win11-tweaks-plan.md` — this plan.

The script is authored top-to-bottom in the order below; tasks are reviewable slices of
that one file, each ending at a state a reviewer could accept/reject.

---

### Task 1: Repo scaffold + script bootstrap

**Files:**
- Create: `Invoke-Win11Tweaks.ps1` (top section)
- Create: `.gitignore`

**Interfaces:**
- Produces: script-scope vars `$script:DryRun` (bool), `$script:LogFile` (path),
  `$script:NeedExplorerRestart` (bool), `$script:Results` (System.Collections.Generic.List[object]).

- [ ] **Step 1: `.gitignore`**

```gitignore
logs/
*.log
```

- [ ] **Step 2: Script header, params, elevation + bootstrap**

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Applies a fixed set of WinUtil (v26.06.23) tweaks, then installs a defined app set
    via winget. No GUI. Logs everything to console + a file.
.PARAMETER DryRun
    Log what WOULD happen; make no system changes.
.PARAMETER LogDir
    Directory for the log file. Default: <script dir>\logs (fallback: Desktop).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Invoke-Win11Tweaks.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$LogDir
)

$script:DryRun = [bool]$DryRun
$script:NeedExplorerRestart = $false
$script:Results = [System.Collections.Generic.List[object]]::new()

# --- Elevation check ---
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

# --- Ensure HKU: drive (needed by some tweaks, e.g. NumLock) ---
if (-not (Test-Path 'HKU:\')) {
    New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -Scope Script | Out-Null
}

# --- Log file path ---
if (-not $LogDir) {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { [Environment]::GetFolderPath('Desktop') }
    $LogDir = Join-Path $base 'logs'
}
try { New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null }
catch { $LogDir = [Environment]::GetFolderPath('Desktop') }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:LogFile = Join-Path $LogDir "win11-tweaks_$stamp.log"

Start-Transcript -Path $script:LogFile -Append | Out-Null
```

- [ ] **Step 3: Verify** — read back: params present; admin check exits non-admin; `HKU:`
  created; `$script:LogFile` set; transcript started. (No runtime here.)

- [ ] **Step 4: Commit**

```bash
git add .gitignore Invoke-Win11Tweaks.ps1
git commit -m "feat: script bootstrap (params, elevation, logging, HKU drive)"
```

---

### Task 2: Logging + primitive helpers

**Files:**
- Modify: `Invoke-Win11Tweaks.ps1` (append helpers after bootstrap)

**Interfaces:**
- Produces:
  - `Write-Log -Level <DEBUG|INFO|OK|WARN|ERROR> -Message [-Id]` → void
  - `Set-Reg -Path -Name -Type -Value [-Id]` → void
  - `Set-Svc -Name -StartupType [-OriginalType] [-Id]` → void
  - `Remove-Appx -Name [-Id]` → void
  - `Invoke-Step -Description -Action <scriptblock> [-Id]` → void (runs Action unless DryRun)
  - `Update-Explorer -Action <refresh|restart>` → void
  - `Install-App -Id <wingetId> [-Name]` → bool (installed/ok)
  - `Enable-Feature -Name <featureName>` → void

- [ ] **Step 1: `Write-Log`**

```powershell
function Write-Log {
    param(
        [ValidateSet('DEBUG','INFO','OK','WARN','ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message,
        [string]$Id = ''
    )
    $ts  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $tag = if ($Id) { "[$Id] " } else { '' }
    $line = "{0} [{1,-5}] {2}{3}" -f $ts, $Level, $tag, $Message
    $color = switch ($Level) {
        'OK'    {'Green'}  'WARN' {'Yellow'} 'ERROR' {'Red'}
        'DEBUG' {'DarkGray'} default {'Gray'}
    }
    Write-Host $line -ForegroundColor $color   # captured by Start-Transcript
}
```

- [ ] **Step 2: `Set-Reg`** (mirrors WinUtil `Set-WinUtilRegistry`)

```powershell
function Set-Reg {
    param([string]$Path,[string]$Name,[string]$Type,[string]$Value,[string]$Id='')
    if ($script:DryRun) {
        if ($Value -eq '<RemoveEntry>') { Write-Log DEBUG "[DRYRUN] would remove $Path\$Name" $Id }
        else { Write-Log DEBUG "[DRYRUN] would set $Path\$Name = $Value ($Type)" $Id }
        return
    }
    try {
        if (-not (Test-Path $Path)) {
            Write-Log DEBUG "creating key $Path" $Id
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        if ($Value -ne '<RemoveEntry>') {
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop | Out-Null
            Write-Log OK "set $Path\$Name = $Value" $Id
        } else {
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Log OK "removed $Path\$Name" $Id
        }
    } catch { Write-Log WARN "reg $Path\$Name failed: $($_.Exception.Message)" $Id }
}
```

- [ ] **Step 3: `Set-Svc`** (mirrors `Set-WinUtilService` + KeepServiceStartup)

```powershell
function Set-Svc {
    param([string]$Name,[string]$StartupType,[string]$OriginalType,[string]$Id='')
    if ($StartupType -eq 'Disable') { $StartupType = 'Disabled' }   # WinUtil quirk
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Log WARN "service $Name not found; skipping" $Id; return }
    if ($OriginalType -and ($svc.StartType.ToString() -ne $OriginalType)) {
        Write-Log INFO "service $Name already customized ($($svc.StartType)); leaving as-is" $Id
        return
    }
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would set service $Name -> $StartupType" $Id; return }
    try {
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        Write-Log OK "service $Name -> $StartupType" $Id
    } catch { Write-Log WARN "service $Name failed: $($_.Exception.Message)" $Id }
}
```

- [ ] **Step 4: `Remove-Appx`** (mirrors `Remove-WinUtilAPPX`)

```powershell
function Remove-Appx {
    param([string]$Name,[string]$Id='')
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would remove appx '$Name' (+provisioned)" $Id; return }
    try {
        Get-AppxPackage $Name -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object DisplayName -like $Name |
            Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
        Write-Log OK "removed appx '$Name'" $Id
    } catch { Write-Log WARN "appx '$Name' failed: $($_.Exception.Message)" $Id }
}
```

- [ ] **Step 5: `Invoke-Step`, `Update-Explorer`, `Install-App`, `Enable-Feature`**

```powershell
function Invoke-Step {
    param([string]$Description,[scriptblock]$Action,[string]$Id='')
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would run: $Description" $Id; return }
    Write-Log INFO "run: $Description" $Id
    try { & $Action; Write-Log OK "done: $Description" $Id }
    catch { Write-Log WARN "step '$Description' failed: $($_.Exception.Message)" $Id }
}

function Update-Explorer {
    param([ValidateSet('refresh','restart')][string]$Action='refresh')
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would $Action explorer"; return }
    if ($Action -eq 'restart') {
        Write-Log INFO "restarting explorer"
        taskkill.exe /F /IM explorer.exe 2>$null | Out-Null
        Start-Process explorer.exe
    } else {
        # broadcast WM_SETTINGCHANGE
        if (-not ([System.Management.Automation.PSTypeName]'Win32Refresh').Type) {
            Add-Type -Namespace Native -Name Win32Refresh -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=false)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.IntPtr lpdwResult);
'@
        }
        $r=[IntPtr]::Zero
        [Native.Win32Refresh]::SendMessageTimeout([IntPtr]0xffff,0x1A,[IntPtr]::Zero,"ImmersiveColorSet",0x2,100,[ref]$r) | Out-Null
    }
}

function Install-App {
    param([string]$Id,[string]$Name)
    $label = if ($Name) { "$Name ($Id)" } else { $Id }
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would winget install $Id"; return $true }
    Write-Log INFO "winget install $label"
    try {
        $p = Start-Process -FilePath winget -NoNewWindow -Wait -PassThru -ArgumentList `
            "install $Id --accept-package-agreements --accept-source-agreements --source winget --silent"
        if ($p.ExitCode -eq 0) { Write-Log OK "installed $label"; return $true }
        Write-Log WARN "winget exit $($p.ExitCode) for $label"; return $false
    } catch { Write-Log WARN "winget failed for $label : $($_.Exception.Message)"; return $false }
}

function Enable-Feature {
    param([string]$Name)
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would enable Windows feature $Name"; return }
    Write-Log INFO "enable Windows feature $Name"
    try { Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart -ErrorAction Stop | Out-Null; Write-Log OK "feature $Name enabled" }
    catch { Write-Log WARN "feature $Name failed: $($_.Exception.Message)" }
}
```

- [ ] **Step 6: Verify** — each helper guards `$script:DryRun`; `Set-Svc` normalizes
  "Disable" and honors KeepServiceStartup; `Set-Reg` handles `<RemoveEntry>` + path
  creation; `Remove-Appx` does AllUsers + provisioned. Commit.

```bash
git add Invoke-Win11Tweaks.ps1
git commit -m "feat: DryRun-aware primitive helpers mirroring WinUtil engine"
```

---

### Task 3: Tweak data table (27 items)

**Files:**
- Modify: `Invoke-Win11Tweaks.ps1` (append `$script:Tweaks` array)

**Interfaces:**
- Consumes: all Task 2 helpers.
- Produces: `$script:Tweaks` = ordered array of
  `[pscustomobject]@{ Id; Content; Category; Apply=[scriptblock] }`, RestorePoint first.

Encode **all 27** items from spec §5 (+ appendices A/B/C) — exact paths/values/scripts.
The three worked examples below fix the exact object shape and the three operation
patterns (registry-only; service+registry+script; appx+script). Encode the remaining
24 identically. Full ID list to cover, in order:
`WPFTweaksRestorePoint, WPFTweaksActivity, WPFTweaksConsumerFeatures,
WPFTweaksDeliveryOptimization, WPFTweaksDiskCleanup, WPFTweaksEndTaskOnTaskbar,
WPFTweaksDisableExplorerAutoDiscovery, WPFTweaksLocation, WPFTweaksServices,
WPFTweaksTelemetry, WPFTweaksDeleteTempFiles, WPFTweaksDeBloat, WPFTweaksWPBT,
WPFTweaksEdgeDebloat, WPFTweaksRemoveOneDrive, WPFTweaksRightClickMenu,
WPFTweaksWindowsAI, WPFToggleDarkMode, WPFToggleShowExt, WPFToggleGameMode,
WPFToggleLoginBlur, WPFToggleNumLock, WPFToggleStandbyFix, WPFToggleHideSettingsHome,
WPFToggleStartMenuRecommendations, WPFToggleBatteryPercentage, WPFToggleTaskbarAlignment`.

- [ ] **Step 1: Table opening + worked examples**

```powershell
$script:Tweaks = @(

  # 1 — RestorePoint (registry + script). MUST be first.
  [pscustomobject]@{ Id='WPFTweaksRestorePoint'; Content='Restore Point - Create'; Category='Essential'; Apply={
      $id='WPFTweaksRestorePoint'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -Type 'DWord' -Value '0'
      Invoke-Step -Id $id -Description 'create system restore point' -Action {
          if (-not (Get-ComputerRestorePoint)) { Enable-ComputerRestore -Drive $Env:SystemDrive }
          Checkpoint-Computer -Description 'System Restore Point created by WinUtil' -RestorePointType MODIFY_SETTINGS
      }
  }}

  # 2 — Activity History (registry-only pattern)
  [pscustomobject]@{ Id='WPFTweaksActivity'; Content='Activity History - Disable'; Category='Essential'; Apply={
      $id='WPFTweaksActivity'; $p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
      Set-Reg -Id $id -Path $p -Name 'EnableActivityFeed'    -Type DWord -Value '0'
      Set-Reg -Id $id -Path $p -Name 'PublishUserActivities' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $p -Name 'UploadUserActivities'  -Type DWord -Value '0'
  }}

  # 12 — DeBloat (appx + script pattern)
  [pscustomobject]@{ Id='WPFTweaksDeBloat'; Content='Unwanted Pre-Installed Apps - Remove'; Category='Essential'; Apply={
      $id='WPFTweaksDeBloat'
      $apps=@('Microsoft.WindowsFeedbackHub','Microsoft.BingNews','Microsoft.BingSearch',
        'Microsoft.BingWeather','Clipchamp.Clipchamp','Microsoft.Todos','Microsoft.PowerAutomateDesktop',
        'Microsoft.MicrosoftSolitaireCollection','Microsoft.WindowsSoundRecorder','Microsoft.MicrosoftStickyNotes',
        'Microsoft.Windows.DevHome','Microsoft.Paint','Microsoft.OutlookForWindows','Microsoft.WindowsAlarms',
        'Microsoft.StartExperiencesApp','Microsoft.GetHelp','Microsoft.ZuneMusic',
        'MicrosoftCorporationII.QuickAssist','MSTeams')
      foreach ($a in $apps) { Remove-Appx -Id $id -Name $a }
      Invoke-Step -Id $id -Description 'uninstall classic Teams' -Action {
          $t="$Env:LocalAppData\Microsoft\Teams\Update.exe"
          if (Test-Path $t) { Start-Process $t -ArgumentList '-uninstall' -Wait; Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
      }
  }}

  # ... encode the remaining 24 here, same shape, values verbatim from spec §5 + appendices ...
)
```

- [ ] **Step 2: Service+registry+script example (encode as WPFTweaksLocation / WPFTweaksServices / WPFTweaksTelemetry / WPFTweaksWindowsAI)**

```powershell
  # 8 — Location (service + registry)
  [pscustomobject]@{ Id='WPFTweaksLocation'; Content='Location Tracking - Disable'; Category='Essential'; Apply={
      $id='WPFTweaksLocation'
      Set-Svc -Id $id -Name 'lfsvc' -StartupType 'Disable' -OriginalType 'Manual'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' -Name 'Value' -Type String -Value 'Deny'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' -Name 'SensorPermissionState' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SYSTEM\Maps' -Name 'AutoUpdateEnabled' -Type DWord -Value '0'
  }}
```

For toggles needing explorer restart (ShowExt, StartMenuRecommendations, TaskbarAlignment),
end their `Apply` with `$script:NeedExplorerRestart = $true`. For DarkMode, after the two
registry writes call `Update-Explorer -Action refresh`. For RightClickMenu, its script does
`Stop-Process -Name explorer` inside `Invoke-Step`; also set `$script:NeedExplorerRestart=$true`.

- [ ] **Step 3: Verify coverage** — count `$script:Tweaks.Count` must be **27**; every ID
  from the list above present exactly once; RestorePoint index 0. Cross-check each object's
  registry/service/script/appx against spec §5. Commit.

```bash
git add Invoke-Win11Tweaks.ps1
git commit -m "feat: encode 27 selected tweaks as data table"
```

---

### Task 4: Runner

**Files:**
- Modify: `Invoke-Win11Tweaks.ps1` (append runner + env banner call)

**Interfaces:**
- Consumes: `$script:Tweaks`, `Write-Log`, `$script:Results`, `$script:NeedExplorerRestart`.
- Produces: populates `$script:Results` with `@{Phase;Id;Content;Status;Detail}`.

- [ ] **Step 1: Env banner + tweak loop**

```powershell
function Write-Banner {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Log INFO "=== win11-tweaks start ==="
    Write-Log DEBUG ("host={0} user={1}" -f $env:COMPUTERNAME, $env:USERNAME)
    Write-Log DEBUG ("os={0} build={1}" -f $os.Caption, $os.BuildNumber)
    Write-Log DEBUG ("psver={0} mode={1}" -f $PSVersionTable.PSVersion, ($(if($script:DryRun){'DRYRUN'}else{'APPLY'})))
    Write-Log DEBUG ("log={0}" -f $script:LogFile)
}

function Invoke-Tweaks {
    $n = $script:Tweaks.Count; $i = 0
    foreach ($t in $script:Tweaks) {
        $i++
        Write-Log INFO ("|> [{0}/{1}] {2}" -f $i,$n,$t.Content) $t.Id
        $status='OK'; $detail=''
        try { & $t.Apply }
        catch { $status='FAILED'; $detail=$_.Exception.Message; Write-Log ERROR "tweak failed: $detail" $t.Id }
        Write-Log ($(if($status -eq 'OK'){'OK'}else{'ERROR'})) ("<| {0}" -f $status) $t.Id
        $script:Results.Add([pscustomobject]@{Phase='Tweak';Id=$t.Id;Content=$t.Content;Status=$status;Detail=$detail})
    }
}
```

- [ ] **Step 2: Verify** — loop logs `|> [n/27]` and `<|` per item; failure is caught and
  recorded, never aborts; results appended. Commit.

```bash
git add Invoke-Win11Tweaks.ps1
git commit -m "feat: tweak runner with env banner and per-item results"
```

---

### Task 5: Install phase

**Files:**
- Modify: `Invoke-Win11Tweaks.ps1` (append install phase)

**Interfaces:**
- Consumes: `Install-App`, `Enable-Feature`, `Write-Log`, `$script:Results`.
- Produces: appends `Phase='Install'` result rows.

- [ ] **Step 1: Lists + install function**

```powershell
$script:AppsToInstall = @(
    'Microsoft.DirectX','RevoUninstaller.RevoUninstaller','Google.Chrome',
    'Nextcloud.NextcloudDesktop','Bitwarden.Bitwarden','Discord.Discord','Valve.Steam',
    'EpicGames.EpicGamesLauncher','OBSProject.OBSStudio','Blizzard.BattleNet',
    'Ubisoft.Connect','CPUID.HWMonitor','NZXT.CAM'
)
$script:AppsToPrompt = @(
    @{ Id='AnyDesk.AnyDesk';           Name='AnyDesk' },
    @{ Id='HPInc.HPSupportAssistant';  Name='HP Support Assistant' }
)
$script:DotNetFeatures = @('NetFx3','NetFx4-AdvSrvs')

function Invoke-InstallPhase {
    Write-Log INFO "=== install phase ==="
    foreach ($f in $script:DotNetFeatures) {
        Enable-Feature -Name $f
        $script:Results.Add([pscustomobject]@{Phase='Install';Id=$f;Content=".NET feature $f";Status='DONE';Detail=''})
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Log ERROR "winget not found; skipping app installs. Install 'App Installer' (Microsoft.DesktopAppInstaller) and re-run."
        $script:Results.Add([pscustomobject]@{Phase='Install';Id='winget';Content='winget missing';Status='SKIPPED';Detail='no winget'})
        Write-Log WARN "NVIDIA App: SKIPPED (not on winget; install manually)"
        return
    }
    $auto=$script:AppsToInstall; $i=0
    foreach ($id in $auto) {
        $i++; Write-Log INFO ("|> [{0}/{1}] install {2}" -f $i,$auto.Count,$id)
        $ok = Install-App -Id $id
        $script:Results.Add([pscustomobject]@{Phase='Install';Id=$id;Content=$id;Status=($(if($ok){'OK'}else{'FAILED'}));Detail=''})
    }
    foreach ($a in $script:AppsToPrompt) {
        if ($script:DryRun -or -not [Environment]::UserInteractive) {
            Write-Log INFO "prompt-app $($a.Name): skipped (dryrun/non-interactive)"
            $script:Results.Add([pscustomobject]@{Phase='Install';Id=$a.Id;Content=$a.Name;Status='SKIPPED';Detail='prompt'}); continue
        }
        $ans = Read-Host "Install $($a.Name)? (y/N)"
        if ($ans -match '^(y|yes)$') {
            $ok = Install-App -Id $a.Id -Name $a.Name
            $script:Results.Add([pscustomobject]@{Phase='Install';Id=$a.Id;Content=$a.Name;Status=($(if($ok){'OK'}else{'FAILED'}));Detail=''})
        } else {
            Write-Log INFO "$($a.Name): declined by user"
            $script:Results.Add([pscustomobject]@{Phase='Install';Id=$a.Id;Content=$a.Name;Status='SKIPPED';Detail='declined'})
        }
    }
    Write-Log WARN "NVIDIA App: SKIPPED (not on winget; install manually — can be added later)"
    $script:Results.Add([pscustomobject]@{Phase='Install';Id='NVIDIA.App';Content='NVIDIA App';Status='SKIPPED';Detail='not on winget'})
}
```

- [ ] **Step 2: Verify** — .NET features enabled first; winget-missing path logs+skips
  cleanly; prompted apps use Read-Host and honor DryRun/non-interactive; NVIDIA recorded as
  SKIPPED. Commit.

```bash
git add Invoke-Win11Tweaks.ps1
git commit -m "feat: winget install phase (auto + prompted apps, .NET feature, NVIDIA skip)"
```

---

### Task 6: Main flow + summary + finish

**Files:**
- Modify: `Invoke-Win11Tweaks.ps1` (append main invocation + summary + Stop-Transcript)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Summary + main**

```powershell
function Write-Summary {
    Write-Log INFO "=== summary ==="
    $groups = $script:Results | Group-Object Status
    foreach ($g in $groups) { Write-Log INFO ("{0,-8}: {1}" -f $g.Name, $g.Count) }
    $script:Results | Where-Object Status -in 'FAILED' | ForEach-Object {
        Write-Log ERROR ("FAILED  {0} — {1}" -f $_.Content, $_.Detail)
    }
    Write-Log INFO ("full log: {0}" -f $script:LogFile)
    Write-Log WARN "A reboot / sign-out is recommended to fully apply changes."
}

# --- main ---
try {
    Write-Banner
    if ($script:DryRun) { Write-Log WARN "DRY RUN — no changes will be made." }
    Invoke-Tweaks
    Invoke-InstallPhase
    if ($script:NeedExplorerRestart -and -not $script:DryRun) { Update-Explorer -Action restart }
    Write-Summary
}
finally {
    Stop-Transcript | Out-Null
}
```

- [ ] **Step 2: Verify** — main order is banner → tweaks → install → single explorer
  restart → summary; `Stop-Transcript` in `finally`. Commit.

```bash
git add Invoke-Win11Tweaks.ps1
git commit -m "feat: main flow, summary table, transcript teardown"
```

---

### Task 7: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README** (BG + EN), covering: what it does (27 tweaks + install list,
  link to spec), how to run elevated with `-ExecutionPolicy Bypass`, **`-DryRun` first**, where
  the log is written, and "send me the log". Include the exact one-liner:
  `powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Win11Tweaks.ps1 -DryRun`.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README with run instructions and log guidance"
```

---

### Task 8: Static validation (syntax/lint)

**Files:** none (tooling)

- [ ] **Step 1: Ensure PowerShell available** — if `pwsh` missing on the authoring machine,
  install it (`brew install --cask powershell` on macOS) **or** run this step on the Win11
  target. Skip gracefully if neither is possible and rely on Task 10.

- [ ] **Step 2: AST parse**

Run:
```bash
pwsh -NoProfile -Command "$e=$null;[System.Management.Automation.Language.Parser]::ParseFile('Invoke-Win11Tweaks.ps1',[ref]$null,[ref]$e);if($e){$e;exit 1}else{'PARSE OK'}"
```
Expected: `PARSE OK` (no parser errors).

- [ ] **Step 3: Lint (best-effort)**

Run:
```bash
pwsh -NoProfile -Command "if(Get-Module -ListAvailable PSScriptAnalyzer){Invoke-ScriptAnalyzer -Path .\Invoke-Win11Tweaks.ps1 -Severity Warning,Error}else{'PSScriptAnalyzer not installed - skipped'}"
```
Expected: no Error-severity findings (Warnings reviewed).

- [ ] **Step 4: Commit any fixes**

```bash
git add Invoke-Win11Tweaks.ps1
git commit -m "fix: address syntax/lint findings"
```

---

### Task 9: Publish to GitLab

**Files:** none (git)

- [ ] **Step 1: Init + first commit** (if not already a repo)

```bash
git -C ~/Workspace/win11-tweaks init
git -C ~/Workspace/win11-tweaks add -A
git -C ~/Workspace/win11-tweaks commit -m "feat: initial win11-tweaks script + docs"
```

- [ ] **Step 2: Create GitLab project + push** — create `msuhost/win11-tweaks` on
  `gitlab.msuhost.com` (via API/PAT-in-URL per brain convention) and push `main`.
  Expected: repo visible with script, README, docs.

---

### Task 10: Acceptance — DryRun on Win11 (definition of done)

**Files:** none (user action)

- [ ] **Step 1:** User runs on the Win11 machine:
  `powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Win11Tweaks.ps1 -DryRun`
- [ ] **Step 2:** User sends back `logs\win11-tweaks_*.log`.
- [ ] **Step 3:** Review log: env banner correct; all 27 tweaks show `[DRYRUN] would …`
  lines matching the spec; install phase lists 13 apps + 2 prompts (skipped in dryrun) +
  .NET features + NVIDIA skip; summary counts sane; zero unexpected ERRORs.
- [ ] **Step 4:** On approval, user runs without `-DryRun`; send that log; review OK/FAILED.

---

## Self-Review

- **Spec coverage:** §5 (27 tweaks)→Task 3; §6 substitutions→Task 2 (`Update-Explorer`) +
  Task 3 notes; §6a install phase→Task 5; §7 architecture/helpers→Tasks 1–2,4,6; §8
  logging→Tasks 1,2,4,6; §9 DryRun→every helper; §10 safety (RP first, no reboot,
  continue-on-fail, elevation)→Tasks 1,3,4,6; §12 deliverables→Tasks 1,7,9; appendices
  A/B→Task 3 data. No gaps.
- **Placeholder scan:** the only intentional "encode the rest" is Task 3, backed by the
  full ID list + 3 worked patterns + the verbatim spec §5 in the same repo (not a
  placeholder — a DRY pointer to co-located authoritative data). No TBD/TODO elsewhere.
- **Type consistency:** helper names/params identical across tasks (`Set-Reg`, `Set-Svc
  -OriginalType`, `Remove-Appx -Name`, `Install-App -Id -Name` returns bool,
  `Update-Explorer -Action`). `$script:Results` row shape uniform. `$script:NeedExplorerRestart`
  set in Task 3, consumed in Task 6.
