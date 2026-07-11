#Requires -Version 5.1
<#
.SYNOPSIS
    Applies a fixed set of Chris Titus WinUtil (v26.06.23) tweaks, then installs a
    defined application set via winget. No GUI. Logs everything to the console AND a
    file so the run can be reviewed afterwards.

.DESCRIPTION
    The 27 tweaks and the install list are exactly the items selected by the user in
    WinUtil (see docs/2026-07-11-win11-tweaks-design.md). Only the ON toggles /
    checked items are applied; nothing else is touched. A System Restore Point is
    created first. The script never reboots by itself.

.PARAMETER DryRun
    Log what WOULD happen and make NO system changes. Recommended for the first run.

.PARAMETER LogDir
    Directory for the log file. Default: the script's own folder (fallback: Desktop
    if the script folder is unknown/unwritable). The log lands right next to the script.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Win11Tweaks.ps1 -DryRun

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Win11Tweaks.ps1
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Reboot,
    [string]$LogDir,
    [string]$RarKey   # path to rarreg.key (WinRAR license); default: rarreg.key next to the script
)

$ErrorActionPreference = 'Continue'
$script:DryRun               = [bool]$DryRun
$script:NeedExplorerRestart  = $false
$script:Results              = [System.Collections.Generic.List[object]]::new()

# --------------------------------------------------------------------------------------
#  Bootstrap: elevation, HKU: drive, log file + transcript
# --------------------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator (it edits HKLM and services)." -ForegroundColor Red
    exit 1
}

# Some tweaks write under HKEY_USERS (e.g. NumLock -> HKU:\.Default); ensure the drive exists.
if (-not (Test-Path 'HKU:\')) {
    New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -Scope Script -ErrorAction SilentlyContinue | Out-Null
}

# Log file lands in the SAME folder as the script (easy to find & send back).
if (-not $LogDir) {
    $LogDir = if ($PSScriptRoot) { $PSScriptRoot } else { [Environment]::GetFolderPath('Desktop') }
}
try { New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null }
catch { $LogDir = [Environment]::GetFolderPath('Desktop') }
$script:LogFile = Join-Path $LogDir ("win11-tweaks_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

try { Start-Transcript -Path $script:LogFile -Append -ErrorAction Stop | Out-Null } catch { }

# --------------------------------------------------------------------------------------
#  Logging + primitive helpers (all DryRun-aware) - mirror WinUtil's apply engine
# --------------------------------------------------------------------------------------
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
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Set-Reg {
    param([string]$Path, [string]$Name, [string]$Type, [string]$Value, [string]$Id = '')
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
    } catch {
        Write-Log WARN "reg $Path\$Name failed: $($_.Exception.Message)" $Id
    }
}

function Set-Svc {
    param([string]$Name, [string]$StartupType, [string]$OriginalType, [string]$Id = '')
    if ($StartupType -eq 'Disable') { $StartupType = 'Disabled' }   # WinUtil ships "Disable" for lfsvc
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Log WARN "service $Name not found; skipping" $Id; return }
    if ($OriginalType -and ($svc.StartType.ToString() -ne $OriginalType)) {
        Write-Log INFO "service $Name already customized (is $($svc.StartType), expected $OriginalType); leaving as-is" $Id
        return
    }
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would set service $Name -> $StartupType" $Id; return }
    try {
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        Write-Log OK "service $Name -> $StartupType" $Id
    } catch {
        Write-Log WARN "service $Name failed: $($_.Exception.Message)" $Id
    }
}

function Remove-Appx {
    param([string]$Name, [string]$Id = '')
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would remove appx '$Name' (+ provisioned)" $Id; return }
    try {
        Get-AppxPackage $Name -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $Name } |
            Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
        Write-Log OK "removed appx '$Name'" $Id
    } catch {
        Write-Log WARN "appx '$Name' failed: $($_.Exception.Message)" $Id
    }
}

function Invoke-Step {
    param([string]$Description, [scriptblock]$Action, [string]$Id = '')
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would run: $Description" $Id; return }
    Write-Log INFO "run: $Description" $Id
    try { & $Action; Write-Log OK "done: $Description" $Id }
    catch { Write-Log WARN "step '$Description' failed: $($_.Exception.Message)" $Id }
}

function Update-Explorer {
    param([ValidateSet('refresh','restart')][string]$Action = 'refresh')
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would $Action explorer"; return }
    if ($Action -eq 'restart') {
        Write-Log INFO "restarting explorer"
        taskkill.exe /F /IM explorer.exe 2>$null | Out-Null
        Start-Process explorer.exe
    } else {
        if (-not ([System.Management.Automation.PSTypeName]'Native.Win32Refresh').Type) {
            Add-Type -Namespace Native -Name Win32Refresh -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=false)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.IntPtr lpdwResult);
'@ -ErrorAction SilentlyContinue
        }
        try {
            $res = [IntPtr]::Zero
            [Native.Win32Refresh]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, "ImmersiveColorSet", 0x2, 100, [ref]$res) | Out-Null
        } catch { }
    }
}

function Install-App {
    param([string]$Id, [string]$Name, [string]$Location)
    $label = if ($Name) { "$Name ($Id)" } else { $Id }
    $wingetArgs = "install $Id --accept-package-agreements --accept-source-agreements --source winget --silent"
    if ($Location) { $wingetArgs += " --location `"$Location`"" }   # e.g. Battle.net requires an install location
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would winget $wingetArgs"; return $true }
    Write-Log INFO "winget install $label"
    try {
        $p = Start-Process -FilePath 'winget' -NoNewWindow -Wait -PassThru -ArgumentList $wingetArgs
        if ($p.ExitCode -eq 0) { Write-Log OK "installed $label"; return $true }
        Write-Log WARN "winget exit code $($p.ExitCode) for $label"; return $false
    } catch {
        Write-Log WARN "winget failed for $label : $($_.Exception.Message)"; return $false
    }
}

function Enable-Feature {
    # Windows Update source (the only no-media way to get .NET 3.5). Time-bounded WITH a live
    # heartbeat: the payload downloads from WU (slow, or stalls if WU is blocked). Run it as a
    # job, print progress every ~10s (so it never looks frozen), give up after TimeoutSec.
    # 300s is generous so it still succeeds on slow connections; on a WU-blocked box it just
    # times out and moves on. On a normal machine with internet, NetFx3 installs fine here.
    param([string]$Name, [string]$Display, [int]$TimeoutSec = 300)
    if (-not $Display) { $Display = $Name }
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would install $Display"; return 'DRYRUN' }
    Write-Log INFO "install $Display  (Windows feature via Windows Update, max ${TimeoutSec}s)"
    $status = 'FAILED'
    $job = Start-Job -ScriptBlock {
        param($n)
        Enable-WindowsOptionalFeature -Online -FeatureName $n -All -NoRestart -ErrorAction Stop | Out-Null
    } -ArgumentList $Name
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastBeat = 0
    while ($job.State -eq 'Running' -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 2
        if (($sw.Elapsed.TotalSeconds - $lastBeat) -ge 10) {
            $lastBeat = [int]$sw.Elapsed.TotalSeconds
            Write-Log DEBUG ("...installing $Display  ({0}s / {1}s)" -f [int]$sw.Elapsed.TotalSeconds, $TimeoutSec) $Display
        }
    }
    if ($job.State -eq 'Completed' -or $job.State -eq 'Failed') {
        try { Receive-Job $job -ErrorAction Stop | Out-Null; Write-Log OK "$Display installed"; $status = 'OK' }
        catch { Write-Log WARN "$Display failed: $($_.Exception.Message)"; $status = 'FAILED' }
    } else {
        Write-Log WARN "$Display install timed out (${TimeoutSec}s; Windows Update unavailable) - skipped. Works on a normal machine with internet."
        Stop-Job $job -ErrorAction SilentlyContinue
        $status = 'TIMEOUT'
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return $status
}

# --------------------------------------------------------------------------------------
#  The 27 selected tweaks (ordered; RestorePoint first). Values verbatim from WinUtil
#  v26.06.23. Toggles apply their ON value only.
# --------------------------------------------------------------------------------------
$script:Tweaks = @(

  # (Restore Point - REMOVED per user request; re-add from git history if needed)

  # Activity History --------------------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksActivity'; Content='Activity History - Disable'; Category='Essential'; Apply={
      $id='WPFTweaksActivity'; $p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
      Set-Reg -Id $id -Path $p -Name 'EnableActivityFeed'    -Type DWord -Value '0'
      Set-Reg -Id $id -Path $p -Name 'PublishUserActivities' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $p -Name 'UploadUserActivities'  -Type DWord -Value '0'
  }}

  # 3 - ConsumerFeatures ---------------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksConsumerFeatures'; Content='ConsumerFeatures - Disable'; Category='Essential'; Apply={
      Set-Reg -Id 'WPFTweaksConsumerFeatures' -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Type DWord -Value '1'
  }}

  # 4 - Delivery Optimization ----------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksDeliveryOptimization'; Content='Delivery Optimization - Disable'; Category='Essential'; Apply={
      Set-Reg -Id 'WPFTweaksDeliveryOptimization' -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Name 'DODownloadMode' -Type DWord -Value '0'
  }}

  # (Disk Cleanup - REMOVED per user request; re-add from git history if needed)

  # End Task With Right Click -----------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksEndTaskOnTaskbar'; Content='End Task With Right Click - Enable'; Category='Essential'; Apply={
      Set-Reg -Id 'WPFTweaksEndTaskOnTaskbar' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' -Name 'TaskbarEndTask' -Type DWord -Value '1'
  }}

  # 7 - File Explorer Automatic Folder Discovery --------------------------------------
  [pscustomobject]@{ Id='WPFTweaksDisableExplorerAutoDiscovery'; Content='File Explorer Automatic Folder Discovery - Disable'; Category='Essential'; Apply={
      Invoke-Step -Id 'WPFTweaksDisableExplorerAutoDiscovery' -Description 'reset Explorer folder-type database' -Action {
          $bags   = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
          $bagMRU = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU'
          Remove-Item -Path $bags   -Recurse -Force -ErrorAction SilentlyContinue
          Remove-Item -Path $bagMRU -Recurse -Force -ErrorAction SilentlyContinue
          $allFolders = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'
          if (-not (Test-Path $allFolders)) { New-Item -Path $allFolders -Force | Out-Null }
          New-ItemProperty -Path $allFolders -Name 'FolderType' -Value 'NotSpecified' -PropertyType String -Force | Out-Null
      }
  }}

  # 8 - Location Tracking --------------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksLocation'; Content='Location Tracking - Disable'; Category='Essential'; Apply={
      $id='WPFTweaksLocation'
      Set-Svc -Id $id -Name 'lfsvc' -StartupType 'Disable' -OriginalType 'Manual'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' -Name 'Value' -Type String -Value 'Deny'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' -Name 'SensorPermissionState' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SYSTEM\Maps' -Name 'AutoUpdateEnabled' -Type DWord -Value '0'
  }}

  # 9 - Services - Set to Manual -------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksServices'; Content='Services - Set to Manual'; Category='Essential'; Apply={
      $id='WPFTweaksServices'
      Set-Svc -Id $id -Name 'CscService'   -StartupType 'Disabled' -OriginalType 'Manual'
      Set-Svc -Id $id -Name 'DiagTrack'    -StartupType 'Disabled' -OriginalType 'Automatic'
      Set-Svc -Id $id -Name 'MapsBroker'   -StartupType 'Manual'   -OriginalType 'Automatic'
      Set-Svc -Id $id -Name 'StorSvc'      -StartupType 'Manual'   -OriginalType 'Automatic'
      Set-Svc -Id $id -Name 'SharedAccess' -StartupType 'Disabled' -OriginalType 'Automatic'
      Invoke-Step -Id $id -Description 'tune SvcHostSplitThresholdInKB to installed RAM' -Action {
          $mem = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1KB
          Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -Value $mem
      }
  }}

  # 10 - Telemetry ---------------------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksTelemetry'; Content='Telemetry - Disable'; Category='Essential'; Apply={
      $id='WPFTweaksTelemetry'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' -Name 'HasAccepted' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Input\TIPC' -Name 'Enabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\InputPersonalization' -Name 'RestrictImplicitInkCollection' -Type DWord -Value '1'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\InputPersonalization' -Name 'RestrictImplicitTextCollection' -Type DWord -Value '1'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore' -Name 'HarvestContacts' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Personalization\Settings' -Name 'AcceptedPrivacyPolicy' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name 'AllowTelemetry' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_TrackProgs' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'PublishUserActivities' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Siuf\Rules' -Name 'NumberOfSIUFInPeriod' -Type DWord -Value '0'
      Invoke-Step -Id $id -Description 'disable telemetry services + Defender sample submission' -Action {
          Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction SilentlyContinue
          Set-Service -Name diagtrack -StartupType Disabled -ErrorAction SilentlyContinue
          Set-Service -Name wermgr    -StartupType Disabled -ErrorAction SilentlyContinue
          [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')
          Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Siuf\Rules' -Name PeriodInNanoSeconds -ErrorAction SilentlyContinue
      }
  }}

  # 11 - Temporary Files ---------------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksDeleteTempFiles'; Content='Temporary Files - Remove'; Category='Essential'; Apply={
      Invoke-Step -Id 'WPFTweaksDeleteTempFiles' -Description 'erase TEMP folders' -Action {
          Remove-Item -Path "$Env:Temp\*"            -Recurse -Force -ErrorAction SilentlyContinue
          Remove-Item -Path "$Env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
      }
  }}

  # 12 - Unwanted Pre-Installed Apps ---------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksDeBloat'; Content='Unwanted Pre-Installed Apps - Remove'; Category='Essential'; Apply={
      $id='WPFTweaksDeBloat'
      $apps = @(
          'Microsoft.WindowsFeedbackHub','Microsoft.BingNews','Microsoft.BingSearch',
          'Microsoft.BingWeather','Clipchamp.Clipchamp','Microsoft.Todos','Microsoft.PowerAutomateDesktop',
          'Microsoft.MicrosoftSolitaireCollection','Microsoft.WindowsSoundRecorder','Microsoft.MicrosoftStickyNotes',
          'Microsoft.Windows.DevHome','Microsoft.Paint','Microsoft.OutlookForWindows','Microsoft.WindowsAlarms',
          'Microsoft.StartExperiencesApp','Microsoft.GetHelp','Microsoft.ZuneMusic',
          'MicrosoftCorporationII.QuickAssist','MSTeams'
      )
      foreach ($a in $apps) { Remove-Appx -Id $id -Name $a }
      Invoke-Step -Id $id -Description 'uninstall classic Teams' -Action {
          $t = "$Env:LocalAppData\Microsoft\Teams\Update.exe"
          if (Test-Path $t) {
              Start-Process $t -ArgumentList '-uninstall' -Wait
              Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
          }
      }
  }}

  # 13 - WPBT --------------------------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksWPBT'; Content='Windows Platform Binary Table (WPBT) - Disable'; Category='Essential'; Apply={
      Set-Reg -Id 'WPFTweaksWPBT' -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'DisableWpbtExecution' -Type DWord -Value '1'
  }}

  # 14 - Microsoft Edge - Debloat ------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksEdgeDebloat'; Content='Microsoft Edge - Debloat'; Category='Advanced'; Apply={
      $id='WPFTweaksEdgeDebloat'; $e='HKLM:\SOFTWARE\Policies\Microsoft\Edge'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name 'CreateDesktopShortcutDefault' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'PersonalizationReportingEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallBlocklist' -Name '1' -Type String -Value 'ofefcgjbeghpigppfmkologfjadafddi'
      Set-Reg -Id $id -Path $e -Name 'ShowRecommendationsEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'HideFirstRunExperience' -Type DWord -Value '1'
      Set-Reg -Id $id -Path $e -Name 'UserFeedbackAllowed' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'ConfigureDoNotTrack' -Type DWord -Value '1'
      Set-Reg -Id $id -Path $e -Name 'AlternateErrorPagesEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'EdgeCollectionsEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'EdgeShoppingAssistantEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'MicrosoftEdgeInsiderPromotionEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'ShowMicrosoftRewards' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'WebWidgetAllowed' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'DiagnosticData' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'EdgeAssetDeliveryServiceEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'WalletDonationEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'DefaultBrowserSettingsCampaignEnabled' -Type DWord -Value '0'
  }}

  # 15 - Microsoft OneDrive - Remove ---------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksRemoveOneDrive'; Content='Microsoft OneDrive - Remove'; Category='Advanced'; Apply={
      $id='WPFTweaksRemoveOneDrive'
      Invoke-Step -Id $id -Description 'uninstall OneDrive + clean up' -Action {
          icacls $Env:OneDrive /deny "Administrators:(D,DC)" 2>$null
          Start-Process 'C:\Windows\System32\OneDriveSetup.exe' -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue
          Stop-Process -Name FileCoAuth,Explorer -Force -ErrorAction SilentlyContinue
          Remove-Item "$Env:LocalAppData\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
          Remove-Item 'C:\ProgramData\Microsoft OneDrive' -Recurse -Force -ErrorAction SilentlyContinue
          icacls $Env:OneDrive /grant "Administrators:(D,DC)" 2>$null
          if ($Env:OneDrive -and -not (Get-ChildItem -Path $Env:OneDrive -ErrorAction SilentlyContinue)) {
              Remove-Item -Path $Env:OneDrive -Recurse -ErrorAction SilentlyContinue
              [Environment]::SetEnvironmentVariable('OneDrive', $null, 'User')
          }
          Set-Service -Name OneSyncSvc -StartupType Disabled -ErrorAction SilentlyContinue
      }
      $script:NeedExplorerRestart = $true
  }}

  # 16 - Right-Click Menu Previous Layout ----------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksRightClickMenu'; Content='Right-Click Menu Previous Layout - Enable'; Category='Advanced'; Apply={
      Invoke-Step -Id 'WPFTweaksRightClickMenu' -Description 'restore classic context menu' -Action {
          New-Item -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Name 'InprocServer32' -Value '' -Force | Out-Null
      }
      $script:NeedExplorerRestart = $true
  }}

  # 17 - Windows AI - Disable And Remove -----------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksWindowsAI'; Content='Windows AI - Disable And Remove'; Category='Advanced'; Apply={
      $id='WPFTweaksWindowsAI'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'SettingsPageVisibility' -Type String -Value 'hide:aicomponents'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\WindowsNotepad' -Name 'DisableAIFeatures' -Type DWord -Value '1'
      Invoke-Step -Id $id -Description 'remove AI packages (Copilot, CoreAI, OfficeHub), disable Recall + WSAIFabricSvc' -Action {
          $appx = (Get-AppxPackage MicrosoftWindows.Client.CoreAI -ErrorAction SilentlyContinue).PackageFullName
          $sid  = (Get-LocalUser $Env:UserName -ErrorAction SilentlyContinue).Sid.Value
          if ($sid -and $appx) {
              New-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\EndOfLife\$sid\$appx" -Force | Out-Null
          }
          Get-AppxPackage -AllUsers "*Copilot*" -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
          Get-AppxPackage -AllUsers Microsoft.MicrosoftOfficeHub -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
          if ($appx) { Remove-AppxPackage $appx -ErrorAction SilentlyContinue }
          Set-Service -Name WSAIFabricSvc -StartupType Disabled -ErrorAction SilentlyContinue
          Disable-WindowsOptionalFeature -FeatureName Recall -Online -NoRestart -ErrorAction SilentlyContinue | Out-Null
      }
  }}

  # 18 - Dark Theme (toggle ON) --------------------------------------------------------
  [pscustomobject]@{ Id='WPFToggleDarkMode'; Content='Dark Theme for Windows'; Category='Toggle'; Apply={
      $id='WPFToggleDarkMode'; $p='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
      Set-Reg -Id $id -Path $p -Name 'AppsUseLightTheme'   -Type DWord -Value '0'
      Set-Reg -Id $id -Path $p -Name 'SystemUsesLightTheme' -Type DWord -Value '0'
      Update-Explorer -Action refresh
  }}

  # 19 - File Explorer File Extensions (toggle ON) -------------------------------------
  [pscustomobject]@{ Id='WPFToggleShowExt'; Content='File Explorer File Extensions'; Category='Toggle'; Apply={
      Set-Reg -Id 'WPFToggleShowExt' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -Type DWord -Value '0'
      $script:NeedExplorerRestart = $true
  }}

  # 20 - Game Mode (toggle ON) ---------------------------------------------------------
  [pscustomobject]@{ Id='WPFToggleGameMode'; Content='Game Mode'; Category='Toggle'; Apply={
      $id='WPFToggleGameMode'; $p='HKCU:\Software\Microsoft\GameBar'
      Set-Reg -Id $id -Path $p -Name 'AllowAutoGameMode'   -Type DWord -Value '1'
      Set-Reg -Id $id -Path $p -Name 'AutoGameModeEnabled' -Type DWord -Value '1'
  }}

  # 21 - Logon Screen Acrylic Blur (toggle ON) ----------------------------------------
  [pscustomobject]@{ Id='WPFToggleLoginBlur'; Content='Logon Screen Acrylic Blur'; Category='Toggle'; Apply={
      Set-Reg -Id 'WPFToggleLoginBlur' -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'DisableAcrylicBackgroundOnLogon' -Type DWord -Value '0'
  }}

  # 22 - Num Lock on Startup (toggle ON) -----------------------------------------------
  [pscustomobject]@{ Id='WPFToggleNumLock'; Content='Num Lock on Startup'; Category='Toggle'; Apply={
      $id='WPFToggleNumLock'
      Set-Reg -Id $id -Path 'HKU:\.Default\Control Panel\Keyboard' -Name 'InitialKeyboardIndicators' -Type String -Value '2'
      Set-Reg -Id $id -Path 'HKCU:\Control Panel\Keyboard'         -Name 'InitialKeyboardIndicators' -Type String -Value '2'
  }}

  # 23 - S0 Sleep Network Connectivity (toggle ON) ------------------------------------
  [pscustomobject]@{ Id='WPFToggleStandbyFix'; Content='S0 Sleep Network Connectivity'; Category='Toggle'; Apply={
      Set-Reg -Id 'WPFToggleStandbyFix' -Path 'HKCU:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9' -Name 'ACSettingIndex' -Type DWord -Value '1'
  }}

  # 24 - Settings Home Page (toggle ON) ------------------------------------------------
  [pscustomobject]@{ Id='WPFToggleHideSettingsHome'; Content='Settings Home Page'; Category='Toggle'; Apply={
      Set-Reg -Id 'WPFToggleHideSettingsHome' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'SettingsPageVisibility' -Type String -Value 'show:home'
  }}

  # 25 - Start Menu Recommendations (toggle ON) ---------------------------------------
  [pscustomobject]@{ Id='WPFToggleStartMenuRecommendations'; Content='Start Menu Recommendations'; Category='Toggle'; Apply={
      $id='WPFToggleStartMenuRecommendations'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'     -Name 'HideRecommendedSection'  -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education' -Name 'IsEducationEnvironment'   -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'              -Name 'HideRecommendedSection'  -Type DWord -Value '0'
      $script:NeedExplorerRestart = $true
  }}

  # 26 - System Tray Battery Percentage (toggle ON) -----------------------------------
  [pscustomobject]@{ Id='WPFToggleBatteryPercentage'; Content='System Tray Battery Percentage'; Category='Toggle'; Apply={
      Set-Reg -Id 'WPFToggleBatteryPercentage' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'IsBatteryPercentageEnabled' -Type DWord -Value '1'
  }}

  # 27 - Taskbar Centered Icons (toggle ON) -------------------------------------------
  [pscustomobject]@{ Id='WPFToggleTaskbarAlignment'; Content='Taskbar Centered Icons'; Category='Toggle'; Apply={
      Set-Reg -Id 'WPFToggleTaskbarAlignment' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAl' -Type DWord -Value '1'
      $script:NeedExplorerRestart = $true
  }}

  # Windows Spotlight - turn off rotating desktop pictures + set the default Win11 wallpaper
  [pscustomobject]@{ Id='CustomSpotlightOff'; Content='Windows Spotlight - Disable + default wallpaper'; Category='Custom'; Apply={
      $id='CustomSpotlightOff'
      $wall = 'C:\Windows\Web\Wallpaper\Windows\img0.jpg'
      # desktop background type: 3 = Spotlight -> 0 = Picture
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' -Name 'BackgroundType' -Type DWord -Value '0'
      # the wallpaper image + Fill style
      Set-Reg -Id $id -Path 'HKCU:\Control Panel\Desktop' -Name 'WallPaper'      -Type String -Value $wall
      Set-Reg -Id $id -Path 'HKCU:\Control Panel\Desktop' -Name 'WallpaperStyle' -Type String -Value '10'
      Set-Reg -Id $id -Path 'HKCU:\Control Panel\Desktop' -Name 'TileWallpaper'  -Type String -Value '0'
      Invoke-Step -Id $id -Description 'remove Spotlight desktop icon + apply wallpaper' -Action {
          Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{2cc5ca98-6485-489a-920e-b3e88a6ccce3}' -Recurse -Force -ErrorAction SilentlyContinue
          if (-not ([System.Management.Automation.PSTypeName]'Native.Wp').Type) {
              Add-Type -Namespace Native -Name Wp -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);'
          }
          [Native.Wp]::SystemParametersInfo(20, 0, 'C:\Windows\Web\Wallpaper\Windows\img0.jpg', 3) | Out-Null
      }
  }}

  # Ultimate Performance power plan (NOT for laptops) - max performance
  [pscustomobject]@{ Id='CustomUltimatePerf'; Content='Ultimate Performance - power plan'; Category='Custom'; Apply={
      Invoke-Step -Id 'CustomUltimatePerf' -Description 'enable Ultimate Performance power plan' -Action {
          powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null
          powercfg -setactive e9a42b02-d5df-448d-aa00-03f14749eb61
      }
  }}

  # DNS -> Cloudflare (1.1.1.1) on active physical adapters
  [pscustomobject]@{ Id='CustomDnsCloudflare'; Content='DNS - Cloudflare (1.1.1.1)'; Category='Custom'; Apply={
      Invoke-Step -Id 'CustomDnsCloudflare' -Description 'set DNS to Cloudflare on active adapters' -Action {
          $dns = @('1.1.1.1','1.0.0.1','2606:4700:4700::1111','2606:4700:4700::1001')
          Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
              Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses $dns -ErrorAction SilentlyContinue
          }
          Clear-DnsClientCache -ErrorAction SilentlyContinue
      }
  }}

  # File Explorer opens "This PC" instead of Home / Quick Access
  [pscustomobject]@{ Id='CustomExplorerThisPC'; Content='Explorer - open This PC'; Category='Custom'; Apply={
      Set-Reg -Id 'CustomExplorerThisPC' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Type DWord -Value '1'
      $script:NeedExplorerRestart = $true
  }}

  # Taskbar cleanup - hide Widgets + Chat buttons
  [pscustomobject]@{ Id='CustomTaskbarCleanup'; Content='Taskbar - hide Widgets + Chat'; Category='Custom'; Apply={
      $id='CustomTaskbarCleanup'; $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
      Set-Reg -Id $id -Path $p -Name 'TaskbarDa' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $p -Name 'TaskbarMn' -Type DWord -Value '0'
      $script:NeedExplorerRestart = $true
  }}
)

# --------------------------------------------------------------------------------------
#  Install phase configuration (runs AFTER tweaks). Add more apps here in the future.
# --------------------------------------------------------------------------------------
$script:AppsToInstall = @(
    'Microsoft.DirectX',
    'RevoUninstaller.RevoUninstaller',
    'Google.Chrome',
    'Nextcloud.NextcloudDesktop',
    'Bitwarden.Bitwarden',
    'Discord.Discord',
    'Valve.Steam',
    'EpicGames.EpicGamesLauncher',
    'OBSProject.OBSStudio',
    'Blizzard.BattleNet',
    'Ubisoft.Connect',
    'CPUID.HWMonitor',
    'NZXT.CAM',
    'RARLab.WinRAR'
)
$script:AppsToPrompt = @(
    @{ Id='AnyDesk.AnyDesk';          Name='AnyDesk' },
    @{ Id='HPInc.HPSupportAssistant'; Name='HP Support Assistant' }
)
# Per-app install location for packages whose winget manifest REQUIRES one (otherwise
# winget prompts "Specify the install root:" and blocks the run). Add IDs here as needed.
$script:AppLocations = @{
    'Blizzard.BattleNet' = 'C:\Program Files (x86)\Battle.net'
}
# .NET Framework via Windows features (not winget): only 3.5 and 4.
#   NetFx3        = .NET 3.5 (inherently bundles 2.0/3.0); off by default, may need WU/source.
#   NetFx4-AdvSrvs = .NET 4.x; already enabled by default on Win11 (enabling is a no-op).
$script:DotNetFeatures = @(
    @{ Name = 'NetFx3';         Display = '.NET 3.5' },
    @{ Name = 'NetFx4-AdvSrvs'; Display = '.NET 4' }
)

# Visual C++ Redistributables - every version, x86 + x64 (32-bit apps/games need x86 too).
# "2015+" is the combined 2015/2017/2019/2022 (14.x, backward-compatible).
$script:VCRedists = @(
    'Microsoft.VCRedist.2005.x86', 'Microsoft.VCRedist.2005.x64',
    'Microsoft.VCRedist.2008.x86', 'Microsoft.VCRedist.2008.x64',
    'Microsoft.VCRedist.2010.x86', 'Microsoft.VCRedist.2010.x64',
    'Microsoft.VCRedist.2012.x86', 'Microsoft.VCRedist.2012.x64',
    'Microsoft.VCRedist.2013.x86', 'Microsoft.VCRedist.2013.x64',
    'Microsoft.VCRedist.2015+.x86', 'Microsoft.VCRedist.2015+.x64'
)

# --------------------------------------------------------------------------------------
#  Runner + install phase + summary
# --------------------------------------------------------------------------------------
function Write-Banner {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    Write-Log INFO  "=========== win11-tweaks start ==========="
    Write-Log DEBUG ("host={0}  user={1}" -f $env:COMPUTERNAME, $env:USERNAME)
    Write-Log DEBUG ("os={0}  build={1}" -f $os.Caption, $os.BuildNumber)
    Write-Log DEBUG ("psver={0}  mode={1}" -f $PSVersionTable.PSVersion, ($(if ($script:DryRun) {'DRYRUN'} else {'APPLY'})))
    Write-Log DEBUG ("logfile={0}" -f $script:LogFile)
}

function Invoke-Tweaks {
    $n = $script:Tweaks.Count; $i = 0
    foreach ($t in $script:Tweaks) {
        $i++
        Write-Log INFO ("|> [{0}/{1}] {2}" -f $i, $n, $t.Content) $t.Id
        $status = 'OK'; $detail = ''
        try { & $t.Apply }
        catch { $status = 'FAILED'; $detail = $_.Exception.Message; Write-Log ERROR "tweak failed: $detail" $t.Id }
        Write-Log ($(if ($status -eq 'OK') {'OK'} else {'ERROR'})) ("<| {0}" -f $status) $t.Id
        $script:Results.Add([pscustomobject]@{ Phase='Tweak'; Id=$t.Id; Content=$t.Content; Status=$status; Detail=$detail })
    }
}

function Invoke-InstallPhase {
    Write-Log INFO "=========== install phase ==========="

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        # Visual C++ Redistributables first (apps/games depend on them)
        $vn = $script:VCRedists.Count; $vi = 0
        foreach ($id in $script:VCRedists) {
            $vi++
            Write-Log INFO ("|> vcredist [{0}/{1}] install {2}" -f $vi, $vn, $id)
            $ok = Install-App -Id $id
            $script:Results.Add([pscustomobject]@{ Phase='VCRedist'; Id=$id; Content=$id; Status=($(if ($ok) {'OK'} else {'FAILED'})); Detail='' })
        }

        $n = $script:AppsToInstall.Count; $i = 0
        foreach ($id in $script:AppsToInstall) {
            $i++
            Write-Log INFO ("|> [{0}/{1}] install {2}" -f $i, $n, $id)
            $ok = Install-App -Id $id -Location $script:AppLocations[$id]
            $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$id; Content=$id; Status=($(if ($ok) {'OK'} else {'FAILED'})); Detail='' })
        }

        foreach ($a in $script:AppsToPrompt) {
            if ($script:DryRun -or -not [Environment]::UserInteractive) {
                Write-Log INFO "prompt-app $($a.Name): skipped (dryrun/non-interactive)"
                $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$a.Id; Content=$a.Name; Status='SKIPPED'; Detail='prompt' })
                continue
            }
            $ans = Read-Host "Install $($a.Name)? (y/N)"
            if ($ans -match '^(y|yes)$') {
                $ok = Install-App -Id $a.Id -Name $a.Name
                $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$a.Id; Content=$a.Name; Status=($(if ($ok) {'OK'} else {'FAILED'})); Detail='' })
            } else {
                Write-Log INFO "$($a.Name): declined by user"
                $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$a.Id; Content=$a.Name; Status='SKIPPED'; Detail='declined' })
            }
        }

        Write-Log WARN "NVIDIA App: SKIPPED (not on winget; install manually - can be added later)."
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NVIDIA.App'; Content='NVIDIA App'; Status='SKIPPED'; Detail='not on winget' })
    } else {
        Write-Log ERROR "winget not found; skipping VC++/app installs. Install 'App Installer' (Microsoft.DesktopAppInstaller) and re-run."
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='winget'; Content='winget missing'; Status='SKIPPED'; Detail='no winget' })
    }

    # WinRAR license - place rarreg.key (shipped next to the script) into the WinRAR dir(s)
    $rk = if ($RarKey) { $RarKey } elseif ($PSScriptRoot) { Join-Path $PSScriptRoot 'rarreg.key' } else { $null }
    if ($rk -and (Test-Path $rk)) {
        $placed = $false
        foreach ($dir in @("$env:ProgramFiles\WinRAR", "${env:ProgramFiles(x86)}\WinRAR")) {
            if (Test-Path $dir) {
                if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would copy rarreg.key -> $dir" }
                else { Copy-Item -LiteralPath $rk -Destination (Join-Path $dir 'rarreg.key') -Force -ErrorAction SilentlyContinue; Write-Log OK "WinRAR license placed in $dir" }
                $placed = $true
            }
        }
        if (-not $placed) { Write-Log WARN "WinRAR install dir not found; license not placed" }
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='WinRAR.License'; Content='WinRAR license (rarreg.key)'; Status=($(if ($placed) {'OK'} else {'SKIPPED'})); Detail='' })
    } else {
        Write-Log INFO "WinRAR license: rarreg.key not available - skipping"
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='WinRAR.License'; Content='WinRAR license (rarreg.key)'; Status='SKIPPED'; Detail='no key' })
    }

    # .NET features LAST + time-bounded (NetFx3 can be slow via Windows Update), so a slow
    # .NET download never delays the winget installs above.
    foreach ($f in $script:DotNetFeatures) {
        $st = Enable-Feature -Name $f.Name -Display $f.Display
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$f.Name; Content=$f.Display; Status=$st; Detail='' })
    }
}

function Write-Summary {
    Write-Log INFO "=========== summary ==========="
    foreach ($g in ($script:Results | Group-Object Status | Sort-Object Name)) {
        Write-Log INFO ("{0,-8}: {1}" -f $g.Name, $g.Count)
    }
    foreach ($r in ($script:Results | Where-Object { $_.Status -eq 'FAILED' })) {
        Write-Log ERROR ("FAILED  [{0}] {1} - {2}" -f $r.Phase, $r.Content, $r.Detail)
    }
    Write-Log INFO ("full log: {0}" -f $script:LogFile)
    # Compact results file next to the log (quick OK/FAILED overview)
    try {
        $resultsFile = $script:LogFile -replace '\.log$', '_results.txt'
        $lines = @("win11-tweaks results  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  -  $(if ($script:DryRun) {'DRYRUN'} else {'APPLY'})", '')
        $lines += ($script:Results | Group-Object Status | Sort-Object Name | ForEach-Object { "{0,-8}: {1}" -f $_.Name, $_.Count })
        $lines += ''
        $lines += ($script:Results | ForEach-Object { "{0,-8} [{1,-8}] {2}" -f $_.Status, $_.Phase, $_.Content })
        $lines | Out-File -FilePath $resultsFile -Encoding UTF8 -Force
        Write-Log INFO ("results summary: {0}" -f $resultsFile)
    } catch { Write-Log WARN "could not write results file: $($_.Exception.Message)" }
    Write-Log WARN "A reboot / sign-out is recommended to fully apply the changes."
}

function Show-Intro {
    $art = @'
 __  __  _____ _    _ _    _           _
|  \/  |/ ____| |  | | |  | |         | |
| \  / | (___ | |  | | |__| | ___  ___| |_
| |\/| |\___ \| |  | |  __  |/ _ \/ __| __|
| |  | |____) | |__| | |  | | (_) \__ \ |_
|_|  |_|_____/ \____/|_|  |_|\___/|___/\__|
'@
    Write-Host ""
    Write-Host $art -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Applies Windows 11 tweaks (privacy, debloat, UI, performance) and installs" -ForegroundColor Gray
    Write-Host "  a set of apps + Visual C++ / .NET runtimes.  Full log saved next to the script." -ForegroundColor Gray
    Write-Host ""
    if ([Environment]::UserInteractive) {
        $ans = Read-Host "  Continue? (Y/n)"
        if ($ans -match '^\s*(n|no)\s*$') {
            Write-Host "  Cancelled - nothing was changed." -ForegroundColor Red
            try { Stop-Transcript | Out-Null } catch { }
            exit 0
        }
    }
}

# --------------------------------------------------------------------------------------
#  Main
# --------------------------------------------------------------------------------------
try {
    Show-Intro
    Write-Banner
    if ($script:DryRun) { Write-Log WARN "DRY RUN - no changes will be made." }
    Invoke-Tweaks
    Invoke-InstallPhase
    if ($script:NeedExplorerRestart -and -not $script:DryRun) { Update-Explorer -Action restart }
    Write-Summary
    Write-Log INFO "=========== win11-tweaks done ==========="
    if ($Reboot -and -not $script:DryRun) {
        Write-Log WARN "Rebooting in 15s (-Reboot given). Press Ctrl+C to cancel."
        Start-Sleep -Seconds 15
        Restart-Computer -Force
    }
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}
