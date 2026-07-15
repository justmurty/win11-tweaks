#Requires -Version 5.1
<#
.SYNOPSIS
    Applies a fixed set of Windows 11 tweaks, then installs a defined application set via
    winget (plus Visual C++ redists and .NET features). No GUI. Logs everything to the
    console AND a file so the run can be reviewed afterwards.

.DESCRIPTION
    The 35 tweaks (25 standard + 10 custom) and the install list are a fixed, curated set
    (see docs/2026-07-11-win11-tweaks-design.md). Only the ON toggles / checked items are
    applied; nothing else is touched.
    The script makes NO restore point and does NOT reboot unless -Reboot is given.

.PARAMETER DryRun
    Log what WOULD happen and make NO system changes. Recommended for the first run.

.PARAMETER Reboot
    Reboot 15 seconds after finishing (cancellable with Ctrl+C). Off by default.

.PARAMETER Machine
    'PC' or 'Laptop'. Skips the interactive "PC or Laptop?" question at startup. This choice
    gates two apps: HP Support Assistant installs on Laptop only, Alienware Command Center on
    PC only. If omitted: ask interactively, or default to 'PC' when non-interactive.

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
    [switch]$Detailed,   # full/debug console output (default: concise, human-friendly; the LOG FILE is always full)
    [string]$Machine,   # 'PC' or 'Laptop' (validated in Show-Intro, NOT via [ValidateSet] - that breaks `irm|iex`)
    [string]$LogDir
)

$ErrorActionPreference = 'Continue'
# Silence ALL cmdlet progress banners (Disable-WindowsOptionalFeature, Remove-AppxProvisionedPackage,
# Get-AppxPackage, Invoke-WebRequest, ...). Those blue "Running [ooooo]" bars sometimes fail to clear and
# "stick" at the top of the console while the script keeps going underneath. We use our own [OK]/Done!
# logging, not Write-Progress, so nothing is lost. (The per-call save/restore dances become redundant now.)
$ProgressPreference = 'SilentlyContinue'
$script:DryRun               = [bool]$DryRun
$script:Detailed             = [bool]$Detailed
$script:NeedExplorerRestart  = $false
$script:NeedIconCacheClear   = $false
$script:Cancelled            = $false   # set by Show-Intro if the user answers "n" (avoids `exit`, which kills an iex host)
$script:MachineType          = ''      # 'PC' or 'Laptop' - resolved in Show-Intro; gates HP Support Assistant / Alienware
$script:DotNet35Proc         = $null   # background DISM process for .NET 3.5 (started early, finished at the end)
$script:PinHelper            = $null   # Pin-Taskbar helper path (kept after Invoke-TaskbarPins for the Chrome pin)
$script:ChromePinned         = $false  # set by Add-ChromeTaskbarPin (right after Chrome installs) - Main refreshes the taskbar if true
$script:Results              = [System.Collections.Generic.List[object]]::new()

# --------------------------------------------------------------------------------------
#  Bootstrap: elevation, HKU: drive, log file + transcript
# --------------------------------------------------------------------------------------
# Self-elevate to Administrator (the script edits HKLM + services). Works BOTH when run from a file
# (.bat / -File) AND via the `irm <url> | iex` one-liner - in the one-liner case there is no local
# file to re-run, so the elevated instance re-fetches the script from its known raw URL.
$SelfUrl = 'https://gitlab.msuhost.com/superuser/win11-tweaks/-/raw/main/Invoke-Win11Tweaks.ps1'
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Not running as Administrator - relaunching elevated (approve the UAC prompt)..." -ForegroundColor Yellow
    try {
        $psExe = (Get-Process -Id $PID).Path
        if (-not $psExe) { $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
        if ($PSCommandPath) {
            # running from a file -> relaunch the file elevated, forwarding the same parameters
            $fwd = foreach ($k in $PSBoundParameters.Keys) {
                $v = $PSBoundParameters[$k]
                if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { "-$k" } }
                else { "-$k"; ('"{0}"' -f $v) }
            }
            $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"{0}"' -f $PSCommandPath)) + $fwd
        } else {
            # running via `irm | iex` (no file) -> re-fetch from the raw URL in the elevated instance
            $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command',"irm $SelfUrl | iex")
        }
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $argList
        exit   # elevated instance launched -> close THIS original (non-admin) window
    } catch {
        Write-Host "Elevation was cancelled or failed. Please run this in an elevated PowerShell." -ForegroundColor Red
        return   # keep this window open so the message is visible
    }
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

# Start the log file (full detail ALWAYS lands here; the console stays concise unless -Detailed).
try { "win11-tweaks log  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $script:LogFile -Encoding UTF8 -Force } catch { }

# --------------------------------------------------------------------------------------
#  Logging + primitive helpers (all DryRun-aware) - the apply engine
# --------------------------------------------------------------------------------------
function Write-Log {
    # Full detail (every level) ALWAYS goes to the LOG FILE. The CONSOLE is concise by default:
    # DEBUG lines (granular reg/service/appx writes, heartbeats) are hidden unless -Detailed was given.
    param(
        [ValidateSet('DEBUG','INFO','OK','WARN','ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message,
        [string]$Id = ''
    )
    $ts  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $tag = if ($Id) { "[$Id] " } else { '' }
    # the LOG FILE gets the full line (incl. the [Id] tag, for diagnostics); the CONSOLE omits the tag
    try { Add-Content -Path $script:LogFile -Value ("{0} [{1,-5}] {2}{3}" -f $ts, $Level, $tag, $Message) -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    if ($Level -eq 'DEBUG' -and -not $script:Detailed) { return }   # concise console - hide DEBUG unless -Detailed
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host ("{0} [{1,-5}] {2}" -f $ts, $Level, $Message) -ForegroundColor $color
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
            Write-Log DEBUG "set $Path\$Name = $Value" $Id
        } else {
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Log DEBUG "removed $Path\$Name" $Id
        }
    } catch {
        Write-Log WARN "reg $Path\$Name failed: $($_.Exception.Message)" $Id
    }
}

function Set-Svc {
    param([string]$Name, [string]$StartupType, [string]$OriginalType, [string]$Id = '')
    if ($StartupType -eq 'Disable') { $StartupType = 'Disabled' }   # the manifest ships "Disable" for lfsvc
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Log WARN "service $Name not found; skipping" $Id; return }
    if ($OriginalType -and ($svc.StartType.ToString() -ne $OriginalType)) {
        Write-Log DEBUG "service $Name already customized (is $($svc.StartType), expected $OriginalType); leaving as-is" $Id
        return
    }
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would set service $Name -> $StartupType" $Id; return }
    try {
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        Write-Log DEBUG "service $Name -> $StartupType" $Id
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
        Write-Log DEBUG "removed appx '$Name'" $Id
    } catch {
        Write-Log WARN "appx '$Name' failed: $($_.Exception.Message)" $Id
    }
}

function Invoke-Step {
    param([string]$Description, [scriptblock]$Action, [string]$Id = '')
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would run: $Description" $Id; return }
    Write-Log DEBUG "run: $Description" $Id
    try { & $Action; Write-Log DEBUG "done: $Description" $Id }
    catch { Write-Log WARN "step '$Description' failed: $($_.Exception.Message)" $Id }
}

function Update-Explorer {
    param([ValidateSet('refresh','restart')][string]$Action = 'refresh')
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would $Action explorer"; return }
    if ($Action -eq 'restart') {
        Write-Log INFO "restarting explorer"
        taskkill.exe /F /IM explorer.exe 2>$null | Out-Null
        if ($script:NeedIconCacheClear) {
            # Rebuild the icon cache while explorer is stopped - otherwise a changed overlay (our removed
            # shortcut arrow) renders as a BLACK BOX from the stale cache (a well-known Windows issue).
            # Delete IMMEDIATELY (Windows auto-restarts the shell within ~1s and re-locks the cache files).
            Write-Log DEBUG "clearing icon cache (so the shortcut-arrow removal renders transparent, not a black box)"
            Remove-Item "$env:LocalAppData\IconCache.db" -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:LocalAppData\Microsoft\Windows\Explorer\iconcache_*.db" -Force -ErrorAction SilentlyContinue
        }
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

function Test-AppInstalled {
    # Return $true if the package is already installed, so Install-App can skip it.
    #  - winget list uses a locale-independent EXIT CODE (0 = found) -> catches winget-tracked installs.
    #  - the Add/Remove Programs DisplayName scan catches installs made OUTSIDE winget
    #    (e.g. an OEM/vendor app pre-installed on the PC), which 'winget list' won't see.
    param([string]$Id, [string]$NamePattern)
    if ($Id) {
        try {
            & winget list --id $Id --exact --accept-source-agreements *>$null
            if ($LASTEXITCODE -eq 0) { return $true }
        } catch { }
    }
    if ($NamePattern) {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        foreach ($k in $keys) {
            if (Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $NamePattern }) { return $true }
        }
    }
    return $false
}

function Install-App {
    # Clean console output: just "Installing <name>" then "Done!" (or "Failed"). winget's own chatter
    # (Found / Downloading / Successfully installed) is redirected to a temp file - shown only in the
    # log file on failure, never on the console.
    param([string]$Id, [string]$Name, [string]$Location, [string]$DetectName, [string]$Source)
    $label = if ($Name) { $Name } elseif ($script:AppNames.ContainsKey($Id)) { $script:AppNames[$Id] } else { $Id }
    $src = if ($Source) { $Source } else { 'winget' }   # 'msstore' for Store-only apps (e.g. Alienware Command Center)
    $wingetArgs = "install $Id --accept-package-agreements --accept-source-agreements --source $src --silent"
    if ($Location) { $wingetArgs += " --location `"$Location`"" }   # e.g. Battle.net requires an install location
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would install $label"; return $true }
    if (Test-AppInstalled -Id $Id -NamePattern $DetectName) { Write-Log OK "Already installed - $label"; return $true }
    Write-Log INFO "Installing $label"
    $wo = Join-Path $env:TEMP 'winget_out.log'
    try {
        $p = Start-Process -FilePath 'winget' -NoNewWindow -Wait -PassThru -ArgumentList $wingetArgs -RedirectStandardOutput $wo
        if ($p.ExitCode -eq 0) { Remove-Item $wo -Force -ErrorAction SilentlyContinue; Write-Log OK "Done!"; return $true }
        Write-Log WARN "Failed - $label"
        if (Test-Path $wo) { Get-Content $wo -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -Last 8 | ForEach-Object { Write-Log DEBUG "  winget> $($_.Trim())" }; Remove-Item $wo -Force -ErrorAction SilentlyContinue }
        return $false
    } catch {
        Write-Log WARN "Failed - $label : $($_.Exception.Message)"; return $false
    }
}

function Install-DirectDownload {
    # Download a vendor installer straight from a URL (or a scraped URL) and run it silently.
    # For apps NOT on winget (e.g. NVIDIA App). DryRun-aware. Returns OK/SKIPPED/FAILED/DRYRUN.
    param(
        [string]$Name,
        [string]$Url,                 # direct URL; OR give -UrlScript to compute the current one
        [scriptblock]$UrlScript,
        [string]$SilentArgs = '',     # silent-install args for the downloaded installer
        [string]$DetectName,          # ARP DisplayName -like pattern -> skip if already installed
        [scriptblock]$Require,        # optional gate; if it returns falsey, skip (e.g. NVIDIA GPU present)
        [string]$RequireMsg = 'requirement not met'
    )
    if ($Require) {
        $met = $false; try { $met = [bool](& $Require) } catch { }
        if (-not $met) { Write-Log INFO "${Name}: skipped ($RequireMsg)"; return 'SKIPPED' }
    }
    if ($DetectName -and -not $script:DryRun -and (Test-AppInstalled -NamePattern $DetectName)) {
        Write-Log OK "Already installed - $Name"; return 'OK'
    }
    if ($UrlScript) {
        try { $Url = & $UrlScript } catch { Write-Log WARN "Failed - $Name (could not resolve download URL: $($_.Exception.Message))"; return 'FAILED' }
    }
    if (-not $Url) { Write-Log WARN "Failed - $Name (no download URL found)"; return 'FAILED' }
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would install $Name (direct download from $Url)"; return 'DRYRUN' }
    Write-Log INFO "Installing $Name"
    $ext = if ($Url -match '\.msi(\?|#|$)') { 'msi' } else { 'exe' }   # MSI installers (e.g. Chrome) need msiexec
    $tmp = Join-Path $env:TEMP ("{0}_{1}.{2}" -f ($Name -replace '\W','_'), (Get-Date -Format 'yyyyMMddHHmmss'), $ext)
    Write-Log DEBUG "downloading $Name from $Url"
    try {
        $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -ErrorAction Stop
        $ProgressPreference = $pp
    } catch { Write-Log WARN "Failed - $Name (download failed: $($_.Exception.Message))"; return 'FAILED' }
    # sanity: make sure we got a real installer (MZ='MZ' = exe, or OLE 'D0 CF 11 E0' = msi), not an HTML page
    try {
        $fs = [System.IO.File]::OpenRead($tmp); $sig = New-Object byte[] 4; [void]$fs.Read($sig, 0, 4); $fs.Close()
    } catch { $sig = @(0, 0, 0, 0) }
    $isExe = ($sig[0] -eq 0x4D -and $sig[1] -eq 0x5A)
    $isMsi = ($sig[0] -eq 0xD0 -and $sig[1] -eq 0xCF -and $sig[2] -eq 0x11 -and $sig[3] -eq 0xE0)
    if (-not ($isExe -or $isMsi)) {
        Write-Log WARN "Failed - $Name (downloaded file is not an exe/msi installer; get it manually from $Url)"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue; return 'FAILED'
    }
    try {
        if ($isMsi)           { $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$tmp`" $SilentArgs" -Wait -PassThru }
        elseif ($SilentArgs)  { $p = Start-Process -FilePath $tmp -ArgumentList $SilentArgs -Wait -PassThru }
        else                  { $p = Start-Process -FilePath $tmp -Wait -PassThru }
        $code = $p.ExitCode
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Log DEBUG "$Name installer exit code: $code"
        if ($code -in 0, 3010, 1641) { Write-Log OK "Done!"; return 'OK' }
        # Non-standard exit code - but some installers (e.g. FL Studio's NSIS) return an odd code even on a
        # clean install. Trust ARP over the exit code: if the app is now actually present, it worked.
        if ($DetectName -and (Test-AppInstalled -NamePattern $DetectName)) {
            Write-Log DEBUG "$Name exit code $code is non-standard, but it IS installed (ARP match) - treating as success"
            Write-Log OK "Done!"; return 'OK'
        }
        Write-Log WARN "Failed - $Name (installer exit code $code)"; return 'FAILED'
    } catch {
        Write-Log WARN "Failed - $Name : $($_.Exception.Message)"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue; return 'FAILED'
    }
}

function Enable-Feature {
    # Enable a Windows optional feature like "Turn Windows features on/off": DISM /Online /Enable-Feature
    # downloads any missing payload straight from Windows Update (no /Source, no /LimitAccess). NetFx3's
    # download is slow (10-15 min seen), so we start DISM and WAIT, checking periodically if it finished,
    # for up to TimeoutSec (default 30 min). When DISM exits we confirm the feature is Enabled -> OK. If
    # it is still not done after TimeoutSec we STOP WAITING but do NOT kill DISM (that corrupts CBS) - it
    # finishes on its own in the background. Runs LAST of everything so nothing waits on it.
    param([string]$Name, [string]$Display, [int]$TimeoutSec = 1800)
    if (-not $Display) { $Display = $Name }
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would enable feature $Display (DISM /Online /Enable-Feature)"; return 'DRYRUN' }
    if ((Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction SilentlyContinue).State -eq 'Enabled') {
        Write-Log OK "$Display already enabled"; return 'OK'
    }
    $dlog = Join-Path $env:TEMP ("dism_{0}.log" -f ($Name -replace '\W','_'))
    Write-Log INFO "installing $Display..."
    $p = Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" -WindowStyle Hidden -PassThru `
        -ArgumentList '/Online','/Enable-Feature',"/FeatureName:$Name",'/All','/NoRestart','/Quiet',"/LogPath:$dlog"
    $sw = [System.Diagnostics.Stopwatch]::StartNew(); $lastBeat = 0
    while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 5
        if (($sw.Elapsed.TotalSeconds - $lastBeat) -ge 60) {   # heartbeat to the LOG FILE only (DEBUG - hidden on the console)
            $lastBeat = [int]$sw.Elapsed.TotalSeconds
            Write-Log DEBUG ("...still installing $Display ({0} min)" -f [int]($sw.Elapsed.TotalSeconds / 60)) $Display
        }
    }
    if ($p.HasExited) {
        Start-Sleep -Milliseconds 500
        if ((Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction SilentlyContinue).State -eq 'Enabled') {
            Write-Log OK "$Display installed"; return 'OK'
        }
        Write-Log WARN "$Display NOT installed (see $dlog)"; return 'FAILED'
    }
    # Still installing after TimeoutSec. Do NOT kill DISM (that corrupts CBS) - let it finish on its own.
    Write-Log WARN ("$Display NOT installed yet - still downloading in the background after {0} min (it finishes on its own; do not reboot until then)." -f [int]($TimeoutSec / 60))
    return 'BACKGROUND'
}

# --------------------------------------------------------------------------------------
#  The tweaks - 35 total: 25 standard Win11 tweaks (values verbatim) + 10 custom at the
#  end. Toggles apply their ON value only. No restore point (removed per user request).
# --------------------------------------------------------------------------------------
$script:Tweaks = @(

  # Shortcut-arrow overlay - remove it FIRST so every shortcut created later (incl. app icons) has none.
  # NOTE: use a PROPER transparent multi-size blank.ico. A malformed one (e.g. Bitmap.GetHicon().Save,
  # which yields a ~766-byte junk icon) corrupts the shared overlay image list and makes OTHER overlays
  # - notably the UAC admin shield - render oversized. So we build a valid 16/24/32/48 .ico by hand.
  [pscustomobject]@{ Id='CustomShortcutArrow'; Content='Icons - remove shortcut-arrow overlay'; Category='Custom'; Apply={
      $id='CustomShortcutArrow'
      $blank = Join-Path $env:SystemRoot 'blank.ico'
      Invoke-Step -Id $id -Description 'write a proper transparent blank.ico + point Shell Icons\29 at it' -Action {
          # 24x24 ONLY (the canonical overlay size). Including larger sizes (32/48) makes Windows size the
          # shared overlay cell to that size, which renders OTHER overlays (the UAC shield) oversized.
          $sizes = @(24)
          $imgData = @()
          foreach ($w in $sizes) {
              $andRow = [int]([math]::Ceiling($w / 32) * 4)
              $ms = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter($ms)
              $bw.Write([int32]40); $bw.Write([int32]$w); $bw.Write([int32]($w * 2))          # BITMAPINFOHEADER
              $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int32]0)
              $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([int32]0)
              $bw.Write((New-Object 'byte[]' ($w * $w * 4)))                                   # XOR bitmap: all zero = alpha 0
              $andBytes = New-Object 'byte[]' ($andRow * $w); for ($j = 0; $j -lt $andBytes.Length; $j++) { $andBytes[$j] = 0xFF }
              $bw.Write($andBytes)                                                              # AND mask: all 1s = transparent (all-0 would render a BLACK box)
              $bw.Flush(); $imgData += ,($ms.ToArray()); $bw.Dispose(); $ms.Dispose()
          }
          $out = New-Object System.IO.MemoryStream; $ow = New-Object System.IO.BinaryWriter($out)
          $ow.Write([int16]0); $ow.Write([int16]1); $ow.Write([int16]$sizes.Count)             # ICONDIR
          $offset = 6 + 16 * $sizes.Count
          for ($k = 0; $k -lt $sizes.Count; $k++) {
              $w = $sizes[$k]; $len = $imgData[$k].Length
              $ow.Write([byte]$w); $ow.Write([byte]$w); $ow.Write([byte]0); $ow.Write([byte]0)
              $ow.Write([int16]1); $ow.Write([int16]32); $ow.Write([int32]$len); $ow.Write([int32]$offset); $offset += $len
          }
          foreach ($img in $imgData) { $ow.Write($img) }
          $ow.Flush(); [System.IO.File]::WriteAllBytes($blank, $out.ToArray()); $ow.Dispose(); $out.Dispose()
      }
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons' -Name '29' -Type String -Value $blank
      $script:NeedExplorerRestart = $true; $script:NeedIconCacheClear = $true
  }}

  # (Restore Point - REMOVED per user request; re-add from git history if needed)

  # Activity History --------------------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksActivity'; Content='Activity History - Disable'; Category='Essential'; Apply={
      $id='WPFTweaksActivity'; $p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
      Set-Reg -Id $id -Path $p -Name 'EnableActivityFeed'    -Type DWord -Value '0'
      Set-Reg -Id $id -Path $p -Name 'PublishUserActivities' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $p -Name 'UploadUserActivities'  -Type DWord -Value '0'
  }}

  # ConsumerFeatures ---------------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksConsumerFeatures'; Content='ConsumerFeatures - Disable'; Category='Essential'; Apply={
      Set-Reg -Id 'WPFTweaksConsumerFeatures' -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Type DWord -Value '1'
  }}

  # Delivery Optimization ----------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksDeliveryOptimization'; Content='Delivery Optimization - Disable'; Category='Essential'; Apply={
      Set-Reg -Id 'WPFTweaksDeliveryOptimization' -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Name 'DODownloadMode' -Type DWord -Value '0'
  }}

  # (Disk Cleanup - REMOVED per user request; re-add from git history if needed)

  # End Task With Right Click -----------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksEndTaskOnTaskbar'; Content='End Task With Right Click - Enable'; Category='Essential'; Apply={
      Set-Reg -Id 'WPFTweaksEndTaskOnTaskbar' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' -Name 'TaskbarEndTask' -Type DWord -Value '1'
  }}

  # File Explorer Automatic Folder Discovery --------------------------------------
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

  # Location Tracking --------------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksLocation'; Content='Location Tracking - Disable'; Category='Essential'; Apply={
      $id='WPFTweaksLocation'
      Set-Svc -Id $id -Name 'lfsvc' -StartupType 'Disable' -OriginalType 'Manual'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' -Name 'Value' -Type String -Value 'Deny'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' -Name 'SensorPermissionState' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SYSTEM\Maps' -Name 'AutoUpdateEnabled' -Type DWord -Value '0'
  }}

  # Services - Set to Manual -------------------------------------------------------
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

  # Telemetry ---------------------------------------------------------------------
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

  # Temporary Files ---------------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksDeleteTempFiles'; Content='Temporary Files - Remove'; Category='Essential'; Apply={
      Invoke-Step -Id 'WPFTweaksDeleteTempFiles' -Description 'erase TEMP folders' -Action {
          Remove-Item -Path "$Env:Temp\*"            -Recurse -Force -ErrorAction SilentlyContinue
          Remove-Item -Path "$Env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
      }
  }}

  # Unwanted Pre-Installed Apps ---------------------------------------------------
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

  # WPBT --------------------------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksWPBT'; Content='Windows Platform Binary Table (WPBT) - Disable'; Category='Essential'; Apply={
      Set-Reg -Id 'WPFTweaksWPBT' -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'DisableWpbtExecution' -Type DWord -Value '1'
  }}

  # Microsoft Edge - Debloat ------------------------------------------------------
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

  # Microsoft OneDrive - Remove ---------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksRemoveOneDrive'; Content='Microsoft OneDrive - Remove'; Category='Advanced'; Apply={
      $id='WPFTweaksRemoveOneDrive'
      Invoke-Step -Id $id -Description 'uninstall OneDrive + clean up' -Action {
          # Only run the (disruptive) removal if OneDrive is actually still present - so a RE-RUN doesn't
          # redo it. On a re-run OneDrive is already gone and $Env:OneDrive is empty, which made the old
          # `icacls $Env:OneDrive ...` run with NO path -> icacls dumped its whole usage/help to the console.
          $odInstalled = ($Env:OneDrive -and (Test-Path $Env:OneDrive)) -or (Test-Path "$env:LocalAppData\Microsoft\OneDrive\OneDrive.exe")
          if ($odInstalled) {
              if ($Env:OneDrive) { icacls $Env:OneDrive /deny "Administrators:(D,DC)" 2>&1 | Out-Null }   # guard empty path + silence icacls
              $odSetup = @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
              if ($odSetup) { Start-Process $odSetup -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue }
              Stop-Process -Name FileCoAuth, Explorer -Force -ErrorAction SilentlyContinue
              Remove-Item "$Env:LocalAppData\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
              Remove-Item 'C:\ProgramData\Microsoft OneDrive' -Recurse -Force -ErrorAction SilentlyContinue
              if ($Env:OneDrive) {
                  icacls $Env:OneDrive /grant "Administrators:(D,DC)" 2>&1 | Out-Null
                  if (-not (Get-ChildItem -Path $Env:OneDrive -ErrorAction SilentlyContinue)) {
                      Remove-Item -Path $Env:OneDrive -Recurse -ErrorAction SilentlyContinue
                      [Environment]::SetEnvironmentVariable('OneDrive', $null, 'User')
                  }
              }
          }
          Set-Service -Name OneSyncSvc -StartupType Disabled -ErrorAction SilentlyContinue   # always ensure disabled (idempotent)
      }
      $script:NeedExplorerRestart = $true
  }}

  # Right-Click Menu Previous Layout ----------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksRightClickMenu'; Content='Right-Click Menu Previous Layout - Enable'; Category='Advanced'; Apply={
      Invoke-Step -Id 'WPFTweaksRightClickMenu' -Description 'restore classic context menu' -Action {
          New-Item -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Name 'InprocServer32' -Value '' -Force | Out-Null
      }
      $script:NeedExplorerRestart = $true
  }}

  # Windows AI - Disable And Remove -----------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksWindowsAI'; Content='Windows AI - Disable And Remove'; Category='Advanced'; Apply={
      $id='WPFTweaksWindowsAI'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'SettingsPageVisibility' -Type String -Value 'hide:aicomponents'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\WindowsNotepad' -Name 'DisableAIFeatures' -Type DWord -Value '1'
      # Official Recall GP ("Turn off saving snapshots for Windows") - disables Recall instantly via registry
      # (fast + idempotent), independent of the slow DISM feature removal below.
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Name 'DisableAIDataAnalysis' -Type DWord -Value '1'
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
          # Only run the (slow) DISM disable if Recall is actually still Enabled - on a re-run it's already
          # off, and calling Disable-WindowsOptionalFeature again re-does the whole servicing pass for nothing.
          if ((Get-WindowsOptionalFeature -Online -FeatureName Recall -ErrorAction SilentlyContinue).State -eq 'Enabled') {
              Disable-WindowsOptionalFeature -FeatureName Recall -Online -NoRestart -ErrorAction SilentlyContinue | Out-Null
          }
      }
  }}

  # Dark Theme (toggle ON) --------------------------------------------------------
  [pscustomobject]@{ Id='WPFToggleDarkMode'; Content='Dark Theme for Windows'; Category='Toggle'; Apply={
      $id='WPFToggleDarkMode'; $p='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
      Set-Reg -Id $id -Path $p -Name 'AppsUseLightTheme'   -Type DWord -Value '0'
      Set-Reg -Id $id -Path $p -Name 'SystemUsesLightTheme' -Type DWord -Value '0'
      Update-Explorer -Action refresh
  }}

  # File Explorer File Extensions (toggle ON) -------------------------------------
  [pscustomobject]@{ Id='WPFToggleShowExt'; Content='File Explorer File Extensions'; Category='Toggle'; Apply={
      Set-Reg -Id 'WPFToggleShowExt' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -Type DWord -Value '0'
      $script:NeedExplorerRestart = $true
  }}

  # Game Mode (toggle ON) ---------------------------------------------------------
  [pscustomobject]@{ Id='WPFToggleGameMode'; Content='Game Mode'; Category='Toggle'; Apply={
      $id='WPFToggleGameMode'; $p='HKCU:\Software\Microsoft\GameBar'
      Set-Reg -Id $id -Path $p -Name 'AllowAutoGameMode'   -Type DWord -Value '1'
      Set-Reg -Id $id -Path $p -Name 'AutoGameModeEnabled' -Type DWord -Value '1'
  }}

  # Logon Screen Acrylic Blur (toggle ON) ----------------------------------------
  [pscustomobject]@{ Id='WPFToggleLoginBlur'; Content='Logon Screen Acrylic Blur'; Category='Toggle'; Apply={
      Set-Reg -Id 'WPFToggleLoginBlur' -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'DisableAcrylicBackgroundOnLogon' -Type DWord -Value '0'
  }}

  # Num Lock on Startup (toggle ON) -----------------------------------------------
  [pscustomobject]@{ Id='WPFToggleNumLock'; Content='Num Lock on Startup'; Category='Toggle'; Apply={
      $id='WPFToggleNumLock'
      Set-Reg -Id $id -Path 'HKU:\.Default\Control Panel\Keyboard' -Name 'InitialKeyboardIndicators' -Type String -Value '2'
      Set-Reg -Id $id -Path 'HKCU:\Control Panel\Keyboard'         -Name 'InitialKeyboardIndicators' -Type String -Value '2'
  }}

  # S0 Sleep Network Connectivity (toggle ON) ------------------------------------
  [pscustomobject]@{ Id='WPFToggleStandbyFix'; Content='S0 Sleep Network Connectivity'; Category='Toggle'; Apply={
      Set-Reg -Id 'WPFToggleStandbyFix' -Path 'HKCU:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9' -Name 'ACSettingIndex' -Type DWord -Value '1'
  }}

  # Settings Home Page (toggle ON) ------------------------------------------------
  [pscustomobject]@{ Id='WPFToggleHideSettingsHome'; Content='Settings Home Page'; Category='Toggle'; Apply={
      Set-Reg -Id 'WPFToggleHideSettingsHome' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'SettingsPageVisibility' -Type String -Value 'show:home'
  }}

  # Start Menu Recommendations (toggle ON) ---------------------------------------
  [pscustomobject]@{ Id='WPFToggleStartMenuRecommendations'; Content='Start Menu Recommendations'; Category='Toggle'; Apply={
      $id='WPFToggleStartMenuRecommendations'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'     -Name 'HideRecommendedSection'  -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education' -Name 'IsEducationEnvironment'   -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'              -Name 'HideRecommendedSection'  -Type DWord -Value '0'
      $script:NeedExplorerRestart = $true
  }}

  # System Tray Battery Percentage (toggle ON) -----------------------------------
  [pscustomobject]@{ Id='WPFToggleBatteryPercentage'; Content='System Tray Battery Percentage'; Category='Toggle'; Apply={
      Set-Reg -Id 'WPFToggleBatteryPercentage' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'IsBatteryPercentageEnabled' -Type DWord -Value '1'
  }}

  # Taskbar Centered Icons (toggle ON) -------------------------------------------
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

  # Ultimate Performance power plan (NOT for laptops) - max performance, then ACTIVATE it
  [pscustomobject]@{ Id='CustomUltimatePerf'; Content='Ultimate Performance - power plan'; Category='Custom'; Apply={
      Invoke-Step -Id 'CustomUltimatePerf' -Description 'enable + activate Ultimate Performance power plan' -Action {
          # Reuse an existing Ultimate Performance plan if present (no duplicates on re-run); else create one.
          $guid = ([regex]::Match((powercfg -list | Out-String), '(?im)GUID:\s*([0-9a-f-]{36})\s*\(Ultimate Performance\)')).Groups[1].Value
          if (-not $guid) {
              # -duplicatescheme prints the NEW plan's GUID; activate THAT (the template GUID often won't activate).
              $guid = ([regex]::Match((powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1 | Out-String), '[0-9a-f-]{36}')).Value
          }
          if (-not $guid) { $guid = 'e9a42b02-d5df-448d-aa00-03f14749eb61' }
          powercfg -setactive $guid
          Write-Log DEBUG ("active scheme -> {0}" -f ((powercfg -getactivescheme | Out-String).Trim())) 'CustomUltimatePerf'
      }
  }}

  # Memory Integrity (HVCI) / VBS - disable it for gaming. Win11's Core Isolation "Memory Integrity"
  # runs kernel code-integrity checks inside a hypervisor (VBS); every 2026 gaming guide calls turning it
  # off the single biggest FREE performance win (avg +5-10% FPS in CPU-bound games, 1% lows +15-25%). This
  # registry method == the Core Isolation toggle; it takes effect after a REBOOT. Reversible: set both back
  # to 1 (or flip Memory Integrity back On in Windows Security). We deliberately do NOT run
  # 'bcdedit /set hypervisorlaunchtype off' - that fully kills the hypervisor and would break WSL2 /
  # Hyper-V / Windows Sandbox; disabling HVCI alone gives the gaming win and keeps those working.
  [pscustomobject]@{ Id='CustomDisableVBS'; Content='Memory Integrity (VBS/HVCI) - disable for gaming'; Category='Custom'; Apply={
      $id='CustomDisableVBS'
      Set-Reg -Id $id -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -Type DWord -Value '0'
  }}

  # Mouse - disable "Enhance pointer precision" (mouse acceleration); preferred for gaming/consistency
  [pscustomobject]@{ Id='CustomMouseAccel'; Content='Mouse - disable Enhance Pointer Precision'; Category='Custom'; Apply={
      $id='CustomMouseAccel'; $m='HKCU:\Control Panel\Mouse'
      Set-Reg -Id $id -Path $m -Name 'MouseSpeed'      -Type String -Value '0'
      Set-Reg -Id $id -Path $m -Name 'MouseThreshold1' -Type String -Value '0'
      Set-Reg -Id $id -Path $m -Name 'MouseThreshold2' -Type String -Value '0'
      Invoke-Step -Id $id -Description 'apply mouse acceleration OFF (SystemParametersInfo)' -Action {
          if (-not ([System.Management.Automation.PSTypeName]'Native.Mouse').Type) {
              Add-Type -Namespace Native -Name Mouse -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint uAction, uint uParam, int[] lpvParam, uint fuWinIni);'
          }
          # SPI_SETMOUSE=0x0004; lpvParam={threshold1,threshold2,acceleration}; {0,0,0}=off; fuWinIni=UPDATEINIFILE|SENDCHANGE
          [Native.Mouse]::SystemParametersInfo(0x0004, 0, (New-Object 'int[]' 3), 3) | Out-Null
          # also reload per-user params from the registry so it takes effect live (SPI alone can be flaky)
          Start-Process rundll32.exe -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' -WindowStyle Hidden -ErrorAction SilentlyContinue
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

  # Taskbar cleanup - hide Search box, Task view, Widgets, Chat, Resume
  [pscustomobject]@{ Id='CustomTaskbarCleanup'; Content='Taskbar - hide Search/TaskView/Widgets/Chat/Resume'; Category='Custom'; Apply={
      $id='CustomTaskbarCleanup'; $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type DWord -Value '0'  # Search box -> Hidden
      Set-Reg -Id $id -Path $p -Name 'ShowTaskViewButton' -Type DWord -Value '0'   # Task view button off
      Set-Reg -Id $id -Path $p -Name 'TaskbarMn'          -Type DWord -Value '0'   # Chat button off
      Set-Reg -Id $id -Path $p -Name 'IsEnabled'          -Type DWord -Value '0'   # Resume button off (Win11 25H2 / build 26200+)
      # Widgets: HKCU 'TaskbarDa' is locked on 25H2 (Set fails "unauthorized"), so kill it via the
      # HKLM policy instead - verified to set cleanly and it removes the Widgets button.
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Type DWord -Value '0'
      $script:NeedExplorerRestart = $true
  }}

  # Search - disable web/Bing results in Start (local apps/files/settings still resolve, and faster).
  # On Win11 24H2/25H2 (build 26200) the reliable switch is the Explorer policy DisableSearchBoxSuggestions=1
  # (removes web suggestions + the Copilot search button); the Windows Search + Bing keys reinforce it so
  # web results don't come back via the connected-search path.
  [pscustomobject]@{ Id='CustomDisableWebSearch'; Content='Search - disable web/Bing + Store results in Start'; Category='Custom'; Apply={
      $id='CustomDisableWebSearch'
      Set-Reg -Id $id -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'         -Name 'DisableSearchBoxSuggestions' -Type DWord -Value '1'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'   -Name 'DisableWebSearch'            -Type DWord -Value '1'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'   -Name 'ConnectedSearchUseWeb'       -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'     -Name 'BingSearchEnabled'           -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'     -Name 'CortanaConsent'              -Type DWord -Value '0'
      # no Microsoft Store app suggestions in Start search (Settings > Privacy > Search > Show suggested results > Microsoft Store)
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' -Name 'IsStoreSuggestionsEnabled' -Type DWord -Value '0'
      $script:NeedExplorerRestart = $true
  }}

  # Desktop cleanup - remove the Microsoft Edge desktop shortcut (a tweak, so it runs BEFORE the installs)
  [pscustomobject]@{ Id='CustomRemoveEdgeShortcut'; Content='Desktop - remove Microsoft Edge shortcut'; Category='Custom'; Apply={
      Invoke-Step -Id 'CustomRemoveEdgeShortcut' -Description 'remove Microsoft Edge desktop shortcut' -Action {
          foreach ($d in @("$env:Public\Desktop", [Environment]::GetFolderPath('Desktop'))) {
              Remove-Item (Join-Path $d 'Microsoft Edge.lnk') -Force -ErrorAction SilentlyContinue
          }
      }
      $script:NeedExplorerRestart = $true
  }}
)

# --------------------------------------------------------------------------------------
#  Install phase configuration (runs AFTER tweaks). Add more apps here in the future.
# --------------------------------------------------------------------------------------
$script:AppsToInstall = @(
    'Microsoft.DirectX',
    'RevoUninstaller.RevoUninstaller',
    'Nextcloud.NextcloudDesktop',
    'Discord.Discord',
    'Valve.Steam',
    'EpicGames.EpicGamesLauncher',
    'OBSProject.OBSStudio',
    'Blizzard.BattleNet',
    'Ubisoft.Connect',
    'CPUID.HWMonitor',
    'NZXT.CAM',
    'Skillbrains.Lightshot',
    'VideoLAN.VLC',
    'SavardSoftware.TurboTop',           # always-on-top helper (on winget, not the savardsoftware.com exe)
    'RARLab.WinRAR'
)
# Machine-specific apps: installed AUTOMATICALLY based on the "PC or Laptop?" answer - no y/N prompt.
#   HP Support Assistant  -> Laptop only (HP laptop utility; pointless on a desktop).
#   Alienware Command Center -> PC only (msstore; the user's Alienware/Dell G desktop). Laptop -> skipped.
# (AnyDesk removed per user request.) Alienware is Store-only (msstore) and works ONLY on Alienware /
# Dell G hardware; if msstore fails (removed / unsupported box), grab it from Dell's support site.
$script:MachineApps = @(
    @{ Id='HPInc.HPSupportAssistant'; Name='HP Support Assistant';     Machine='Laptop' },
    @{ Id='9PMHP03NJ9QP';             Name='Alienware Command Center'; Machine='PC'; Source='msstore' }
)
# Per-app install location for packages whose winget manifest REQUIRES one (otherwise
# winget prompts "Specify the install root:" and blocks the run). Add IDs here as needed.
$script:AppLocations = @{
    'Blizzard.BattleNet' = 'C:\Program Files (x86)\Battle.net'
}
# Skip-if-already-installed detection by Add/Remove Programs DisplayName (-like pattern),
# for apps often present OUTSIDE winget so 'winget list' alone won't see them. Add IDs here as needed.
$script:AppDetectNames = @{
}
# Non-winget apps: fetch the vendor installer directly and run it silently (see Install-DirectDownload).
$script:DirectApps = @(
    @{  # Google Chrome - winget hash mismatch under admin (0x8A150011): Google rotates the enterprise MSI
        # but the winget manifest hash lags. Direct-download the stable always-latest enterprise MSI (MSI ->
        # msiexec /i /qn handled by Install-DirectDownload).
        Name       = 'Google Chrome'
        Url        = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
        SilentArgs = '/qn /norestart'
        DetectName = 'Google Chrome*'
    }
    @{  # NVIDIA App - not on winget (hardware-gated). Scrape the official page for the current
        # NVIDIA_app_vX.exe and install silently. Only runs when an NVIDIA GPU is present.
        Name       = 'NVIDIA App'
        UrlScript  = {
            $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            $html = (Invoke-WebRequest 'https://www.nvidia.com/en-us/software/nvidia-app/' -UseBasicParsing -UserAgent $ua -ErrorAction Stop).Content
            $m = [regex]::Match($html, 'https://[^\s"''<>]+/NVIDIA_app_v[\d.]+\.exe')
            if ($m.Success) { $m.Value }
        }
        SilentArgs = '-s -noreboot -noeula -nofinish -nosplash'
        DetectName = 'NVIDIA App*'
        Require    = { [bool](Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' }) }
        RequireMsg = 'no NVIDIA GPU detected'
    }
    @{  # Bitwarden - winget install fails as admin (ShellExec 0x8A150006); use the official direct installer.
        Name       = 'Bitwarden'
        Url        = 'https://vault.bitwarden.com/download/?app=desktop&platform=windows'
        SilentArgs = '/allusers /S'
        DetectName = 'Bitwarden*'
    }
    @{  # Parsec - winget installer hash mismatch (0x8A150011, cannot override as admin); official installer.
        Name       = 'Parsec'
        Url        = 'https://builds.parsec.app/package/parsec-windows.exe'
        SilentArgs = '/silent'
        DetectName = 'Parsec*'
    }
    @{  # Google Play Games - winget hash mismatch under admin (0x8A150011): Google ships a rolling "beta"
        # tag bootstrapper (Install-GooglePlayGames.exe) whose hash changes constantly, so winget's fixed
        # manifest hash never matches and can't be overridden as admin. Fetch the SAME URL with the SAME
        # --silent switch the Google.PlayGames manifest uses - directly, so there's no hash check to fail.
        Name       = 'Google Play Games'
        Url        = 'https://dl.google.com/tag/s/appguid={47B07D71-505D-4665-AFD4-4972A30C6530}&appname=GPG&needsadmin=true&ap=beta/play/games/Install-GooglePlayGames.exe'
        SilentArgs = '--silent'
        DetectName = 'Google Play Games*'
    }
    @{  # FL Studio - REMOVED from winget (manifest folder 404 -> winget "No package found"). Image-Line's
        # official "latest Windows installer" redirect always resolves to the current flstudio_win64_*.exe
        # (verified: -> install.image-line.com/flstudio/flstudio_win64_26.1.1.5547.exe). NSIS installer -> /S.
        Name       = 'FL Studio'
        Url        = 'https://support.image-line.com/redirect/flstudio_win_installer'
        SilentArgs = '/S'
        DetectName = 'FL Studio*'
    }
)
# Apps that should get a Desktop icon (most make their own; these do not reliably). Keyed by winget ID
# (or a direct-download Name). Right after each app installs, New-DesktopShortcut copies its Start Menu
# shortcut, or builds one from Exe if the app made no Start Menu entry; skipped if a Desktop icon exists.
$script:DesktopShortcutApps = @{
    'SavardSoftware.TurboTop' = @{ Name = 'TurboTop';  Exe = 'C:\Program Files (x86)\TurboTop\TurboTop.exe' }
    'Blizzard.BattleNet'      = @{ Name = 'Battle.net'; Exe = "${env:ProgramFiles(x86)}\Battle.net\Battle.net Launcher.exe" }
    'Bitwarden'               = @{ Name = 'Bitwarden'; Exe = "$env:ProgramFiles\Bitwarden\Bitwarden.exe" }
    'Parsec'                  = @{ Name = 'Parsec';    Exe = "$env:ProgramFiles\Parsec\parsecd.exe" }
}
# .NET Framework via Windows features (not winget): only 3.5 and 4.
#   NetFx3        = .NET 3.5 (inherently bundles 2.0/3.0); off by default, may need WU/source.
#   NetFx4-AdvSrvs = .NET 4.x; already enabled by default on Win11 (enabling is a no-op).
# .NET features: NetFx3 (.NET 3.5) is started EARLY in the background (Start-DotNet35) so its slow
# Windows-Update download overlaps the install phase; NetFx4-AdvSrvs is already enabled on Win11 (instant).

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

# WinRAR license embedded as base64 (the only source) - the WinRAR step decodes this and writes
# rarreg.key into the WinRAR dir(s), so both download-and-run AND the `irm|iex` one-liner license WinRAR.
$script:RarKeyB64 = 'UkFSIHJlZ2lzdHJhdGlvbiBkYXRhCldpblJBUgpVbmxpbWl0ZWQgQ29tcGFueSBMaWNlbnNlClVJRD00YjkxNGZiNzcyYzgzNzZiZjU3MQo2NDEyMjEyMjUwZjU3MTFhZDA3MmNmMzUxY2ZhMzllMjg1MTE5MmRhZjhhMzYyNjgxYmJiMWQKY2Q0OGRhMWQxNGQ5OTVmMGJiZjk2MGZjZTZjYjVmZmRlNjI4OTAwNzk4NjFiZTU3NjM4NzE3CjcxMzFjZWQ4MzVlZDY1Y2M3NDNkOTc3N2YyZWE3MWE4ZTMyYzdlNTkzY2Y2Njc5NDM0MzU2NQpiNDFiY2Y1NjkyOTQ4NmI4YmNkYWMzM2Q1MGVjZjc3Mzk5NjA1MjU5OGYxZjU1NmRlZmZmYmQKOTgyZmJlNzFlOTNkZjZiNjM0NmMzN2EzODkwZjNjN2VkYzY1ZDdmNTQ1NTQ3MGQxM2QxMTkwCjZlNmZiODI0YmNmMjVmMTU1NTQ3YjVmYzQxOTAxYWQ1OGMwOTkyZjU3MGJlMWNmNTYwOGJhOQphZWY2OWQ0OGM4NjRiY2Q3MmQxNTE2Mzg5Nzc3M2QzMTQxODdmNmE5YWYzNTA4MDg3MTk3OTY='

# Friendly display names for the "Installing X" log line (falls back to the winget ID if not listed).
$script:AppNames = @{
    'Microsoft.VCRedist.2005.x86'  = 'Visual C++ 2005 (x86)';      'Microsoft.VCRedist.2005.x64'  = 'Visual C++ 2005 (x64)'
    'Microsoft.VCRedist.2008.x86'  = 'Visual C++ 2008 (x86)';      'Microsoft.VCRedist.2008.x64'  = 'Visual C++ 2008 (x64)'
    'Microsoft.VCRedist.2010.x86'  = 'Visual C++ 2010 (x86)';      'Microsoft.VCRedist.2010.x64'  = 'Visual C++ 2010 (x64)'
    'Microsoft.VCRedist.2012.x86'  = 'Visual C++ 2012 (x86)';      'Microsoft.VCRedist.2012.x64'  = 'Visual C++ 2012 (x64)'
    'Microsoft.VCRedist.2013.x86'  = 'Visual C++ 2013 (x86)';      'Microsoft.VCRedist.2013.x64'  = 'Visual C++ 2013 (x64)'
    'Microsoft.VCRedist.2015+.x86' = 'Visual C++ 2015-2022 (x86)'; 'Microsoft.VCRedist.2015+.x64' = 'Visual C++ 2015-2022 (x64)'
    'Microsoft.DirectX'                = 'DirectX'
    'RevoUninstaller.RevoUninstaller'  = 'Revo Uninstaller'
    'Nextcloud.NextcloudDesktop'       = 'Nextcloud'
    'Discord.Discord'                  = 'Discord'
    'Valve.Steam'                      = 'Steam'
    'EpicGames.EpicGamesLauncher'      = 'Epic Games Launcher'
    'OBSProject.OBSStudio'             = 'OBS Studio'
    'Blizzard.BattleNet'               = 'Battle.net'
    'Ubisoft.Connect'                  = 'Ubisoft Connect'
    'CPUID.HWMonitor'                  = 'HWMonitor'
    'NZXT.CAM'                         = 'NZXT CAM'
    'Skillbrains.Lightshot'            = 'Lightshot'
    'VideoLAN.VLC'                     = 'VLC media player'
    'SavardSoftware.TurboTop'          = 'TurboTop'
    'RARLab.WinRAR'                    = 'WinRAR'
}

# --------------------------------------------------------------------------------------
#  Runner + install phase + summary
# --------------------------------------------------------------------------------------
function Write-Banner {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    Write-Log INFO  "=========== WIN11-TWEAKS START ==========="
    Write-Log DEBUG ("host={0}  user={1}" -f $env:COMPUTERNAME, $env:USERNAME)
    Write-Log DEBUG ("os={0}  build={1}" -f $os.Caption, $os.BuildNumber)
    Write-Log DEBUG ("psver={0}  mode={1}" -f $PSVersionTable.PSVersion, ($(if ($script:DryRun) {'DRYRUN'} else {'APPLY'})))
    Write-Log DEBUG ("logfile={0}" -f $script:LogFile)
}

function Invoke-Tweaks {
    foreach ($t in $script:Tweaks) {
        Write-Log INFO ("Applying {0}" -f $t.Content) $t.Id
        $status = 'OK'; $detail = ''
        try { & $t.Apply }
        catch { $status = 'FAILED'; $detail = $_.Exception.Message; Write-Log ERROR "tweak failed: $detail" $t.Id }
        Write-Log ($(if ($status -eq 'OK') {'OK'} else {'ERROR'})) ($(if ($status -eq 'OK') {'Done!'} else {'Failed'})) $t.Id
        $script:Results.Add([pscustomobject]@{ Phase='Tweak'; Id=$t.Id; Content=$t.Content; Status=$status; Detail=$detail })
    }
}

function Get-StartMenuShortcuts {
    $roots = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:AppData\Microsoft\Windows\Start Menu\Programs")
    Get-ChildItem $roots -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
}

function New-DesktopShortcut {
    # Create a Desktop icon for ONE app, called right after that app installs. Prefer copying the app's
    # Start Menu shortcut (correct icon+target); else build one from its .exe. Skip if a Desktop icon
    # already exists (matched by name). Used only for the few apps that don't reliably make their own.
    param([string]$Name, [string]$Exe)
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would create a Desktop shortcut for $Name"; return }
    $pub = "$env:Public\Desktop"; $usr = [Environment]::GetFolderPath('Desktop')
    $dest = Join-Path $pub "$Name.lnk"
    $rec = [pscustomobject]@{ Phase='Install'; Id="Desktop.$Name"; Content="Desktop shortcut ($Name)"; Status='FAILED'; Detail='' }
    if ((Test-Path $dest) -or (Test-Path (Join-Path $usr "$Name.lnk"))) {
        Write-Log DEBUG "Desktop shortcut for $Name already present"; $rec.Status='OK'; $rec.Detail='exists'; $script:Results.Add($rec); return
    }
    $srcLnk = Get-StartMenuShortcuts | Where-Object {
        $b = [IO.Path]::GetFileNameWithoutExtension($_); ($b -eq $Name) -or ($b -like "$Name*" -and $b -notmatch '(?i)uninstall|help')
    } | Select-Object -First 1
    try {
        if ($srcLnk) {
            Copy-Item -LiteralPath $srcLnk -Destination $dest -Force -ErrorAction Stop
            Write-Log DEBUG "desktop shortcut: $Name"; $rec.Status='OK'
        } elseif ($Exe -and (Test-Path $Exe)) {
            $wsh = New-Object -ComObject WScript.Shell; $sc = $wsh.CreateShortcut($dest)
            $sc.TargetPath = $Exe; $sc.WorkingDirectory = (Split-Path $Exe); $sc.Description = $Name; $sc.Save()
            Write-Log DEBUG "desktop shortcut: $Name"; $rec.Status='OK'
        } else {
            Write-Log DEBUG "desktop shortcut '$Name': no Start Menu shortcut and no .exe yet - skipping (the app may create its own on first launch)"; $rec.Status='SKIPPED'; $rec.Detail='not found'
        }
    } catch { Write-Log DEBUG "desktop shortcut '$Name' failed: $($_.Exception.Message)"; $rec.Detail=$_.Exception.Message }
    $script:Results.Add($rec)
}

function Set-WinRarLicense {
    # Write rarreg.key (decoded from the embedded base64) into the WinRAR dir(s). Called right after
    # WinRAR installs so the console reads "Installing WinRAR / Done! / Creating WinRAR license / Done!".
    $rkBytes = $null
    if ($script:RarKeyB64) { try { $rkBytes = [System.Convert]::FromBase64String($script:RarKeyB64) } catch { } }
    $rarDirs = @("$env:ProgramFiles\WinRAR", "${env:ProgramFiles(x86)}\WinRAR") | Where-Object { Test-Path $_ }
    if ($script:DryRun) {
        Write-Log DEBUG "[DRYRUN] would create the WinRAR license"
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='WinRAR.License'; Content='WinRAR license (rarreg.key)'; Status='DRYRUN'; Detail='' }); return
    }
    if (-not ($rkBytes -and $rarDirs)) {
        Write-Log DEBUG "WinRAR license: no embedded key or WinRAR dir not found - skipping"
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='WinRAR.License'; Content='WinRAR license (rarreg.key)'; Status='SKIPPED'; Detail='no key/dir' }); return
    }
    Write-Log INFO "Creating WinRAR license"
    foreach ($dir in $rarDirs) {
        try { [System.IO.File]::WriteAllBytes((Join-Path $dir 'rarreg.key'), $rkBytes); Write-Log DEBUG "placed rarreg.key in $dir" }
        catch { Write-Log DEBUG "place failed in ${dir}: $($_.Exception.Message)" }
    }
    Write-Log OK "Done!"
    $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='WinRAR.License'; Content='WinRAR license (rarreg.key)'; Status='OK'; Detail='' })
}

function Stop-BattleNetProcs {
    # Kill the Battle.net tree: app + launcher + CEF helper subprocesses (all named Battle.net*) + the updater
    # Agent (path-filtered). Battle.net's UI is its OWN embedded Chromium (Battle.net.exe subprocesses), NOT
    # Edge WebView2 - so we do NOT blanket-kill msedgewebview2 (on this box those 18 are Windows Widgets!); we
    # only stop a WebView2 whose command line actually points at Battle.net (in case a build uses it), leaving
    # unrelated WebView2 apps alone. No watchdog/scheduled task restarts these once the launcher is installed.
    Get-Process -Name 'Battle.net', 'Battle.net Launcher', 'Battle.net Helper', 'BlizzardError' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'Agent' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*Battle.net*' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*Battle.net*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Install-BattleNet {
    # winget can't cleanly install Battle.net: the Battle.net-Setup bootstrapper hands off to the Battle.net
    # "Agent", which downloads + installs the launcher IN THE BACKGROUND (can take minutes) and auto-launches
    # the login window. winget's -Wait then never returns, and - the bug we hit - verifying right after we kill
    # winget reports a false FAILED while the Agent is still installing, leaving the app lingering on screen.
    # Fix: run winget NON-blocking and DON'T wait on it; poll for the launcher on disk / ARP entry (the real
    # success signal) with a generous timeout so the Agent can finish. Then tear the whole Battle.net tree down
    # (sweeping until it stays dead - no watchdog survives) so nothing is left running.
    $id = 'Blizzard.BattleNet'; $label = 'Battle.net'
    $dir = $script:AppLocations[$id]; $exe = Join-Path $dir 'Battle.net Launcher.exe'
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would install $label (non-blocking, poll for install, then tear down)"; return $true }
    if (Test-AppInstalled -Id $id -NamePattern 'Battle.net*') { Write-Log OK "Already installed - $label"; return $true }
    Write-Log INFO "Installing $label"
    $preEdge = @((Get-Process msedge -ErrorAction SilentlyContinue).Id)   # Edge already running - leave it alone
    $wo = Join-Path $env:TEMP 'winget_bnet.log'
    $wargs = "install $id --accept-package-agreements --accept-source-agreements --source winget --silent --location `"$dir`""
    $wg = Start-Process -FilePath 'winget' -NoNewWindow -PassThru -ArgumentList $wargs -RedirectStandardOutput $wo
    # Poll for the REAL result (background Agent install) - don't trust winget's exit or verify early.
    $sw = [System.Diagnostics.Stopwatch]::StartNew(); $ok = $false
    while ($sw.Elapsed.TotalSeconds -lt 300) {
        Start-Sleep -Seconds 5
        if ((Test-Path $exe) -or (Test-AppInstalled -Id $id -NamePattern 'Battle.net*')) { $ok = $true; break }
    }
    if ($ok) {
        Write-Log DEBUG "Battle.net installed after $([int]$sw.Elapsed.TotalSeconds)s (launcher/ARP present); closing the auto-launched app"
        Start-Sleep -Seconds 5   # let the Agent finish writing files before we stop it
    } else {
        Write-Log DEBUG "Battle.net not detected within $([int]$sw.Elapsed.TotalSeconds)s; tearing down anyway"
    }
    # Tear down winget + the whole Battle.net tree, sweeping until it stays down (the Agent may relaunch once).
    if ($wg -and -not $wg.HasExited) { try { $wg.Kill() } catch { } }
    for ($i = 0; $i -lt 4; $i++) {
        Stop-BattleNetProcs
        # Battle.net's login flow launches Edge (its Agent -> msedge). Close ONLY the Edge that appeared during
        # this install; any Edge already running before it (snapshot above) is left untouched. Once the Agent
        # is dead it can't relaunch Edge, so this sticks.
        Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $preEdge } | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        if (-not (Get-Process -Name 'Battle.net', 'Battle.net Launcher' -ErrorAction SilentlyContinue)) { break }
    }
    Remove-Item $wo -Force -ErrorAction SilentlyContinue
    if ((Test-Path $exe) -or (Test-AppInstalled -Id $id -NamePattern 'Battle.net*')) { Write-Log OK "Done!"; return $true }
    Write-Log WARN "Failed - $label"; return $false
}

function Install-Alienware {
    # Alienware Command Center. Returns a STATUS ('OK'/'SKIPPED'/'FAILED') so a non-Alienware box shows
    # SKIPPED, NOT a scary "Failed". We check the ACTUAL hardware (Win32_ComputerSystem model) instead of
    # relying on the Store's flaky detection: not Alienware/Dell G -> SKIPPED. On Alienware/Dell G -> try
    # the Microsoft Store first (official/latest); if the Store gating misfires, fall back to Dell's
    # DIRECT Full Installer EXE (bypasses the Store). Only a genuine install failure -> FAILED.
    # NOTE: the Dell URL is version-pinned (update when Dell ships newer) + /s is a best-effort silent
    # switch; can't be tested on the non-Alienware VM.
    $id = '9PMHP03NJ9QP'; $label = 'Alienware Command Center'
    $dellUrl = 'https://dl.dell.com/FOLDER12874937M/2/Alienware-Command-Center-6-x-Full-Installer-for_5T498_WIN64_6.7.37.0_A00_01.EXE'
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would install $label on Alienware/Dell G hardware"; return 'DRYRUN' }
    if (Test-AppInstalled -NamePattern 'Alienware Command Center*') { Write-Log OK "Already installed - $label"; return 'OK' }
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $hw = "$($cs.Manufacturer) $($cs.Model)"
    if ($hw -notmatch 'Alienware' -and $hw -notmatch 'Dell\s*G\d') {
        Write-Log INFO "$label - skipped (not Alienware/Dell hardware)"   # NOT a failure
        return 'SKIPPED'
    }
    Write-Log INFO "Installing $label"
    # 1) Microsoft Store (official, always-latest)
    $wo = Join-Path $env:TEMP 'winget_awcc.log'
    try {
        $p = Start-Process -FilePath 'winget' -NoNewWindow -Wait -PassThru -RedirectStandardOutput $wo `
            -ArgumentList "install $id --accept-package-agreements --accept-source-agreements --source msstore --silent"
        if ($p.ExitCode -eq 0) { Remove-Item $wo -Force -EA SilentlyContinue; Write-Log OK "Done!"; return 'OK' }
    } catch { }
    Remove-Item $wo -Force -ErrorAction SilentlyContinue
    # 2) Dell direct Full Installer fallback (bypasses the Store's hardware gating)
    Write-Log DEBUG "Store install failed/gated -> trying Dell's direct AWCC installer"
    $tmp = Join-Path $env:TEMP 'AWCC_dell.exe'
    try {
        $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $dellUrl -OutFile $tmp -UseBasicParsing -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -ErrorAction Stop
        $ProgressPreference = $pp
        $dp = Start-Process -FilePath $tmp -ArgumentList '/s' -Wait -PassThru
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        if (Test-AppInstalled -NamePattern 'Alienware Command Center*') { Write-Log OK "Done!"; return 'OK' }
        Write-Log WARN "Failed - $label (install manually from dell.com/support)"; return 'FAILED'
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Log WARN "Failed - $label (Dell fallback download failed: $($_.Exception.Message))"; return 'FAILED'
    }
}

function Invoke-InstallPhase {
    Write-Log INFO "=========== INSTALLING APPS ==========="

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        foreach ($id in $script:VCRedists) {   # Visual C++ Redistributables first (apps/games need them)
            $ok = Install-App -Id $id
            $script:Results.Add([pscustomobject]@{ Phase='VCRedist'; Id=$id; Content=$id; Status=($(if ($ok) {'OK'} else {'FAILED'})); Detail='' })
        }
        foreach ($id in $script:AppsToInstall) {
            if ($id -eq 'Blizzard.BattleNet') { $ok = Install-BattleNet }   # special: background Agent install + auto-launched app (winget hangs / verifies too early)
            else { $ok = Install-App -Id $id -Location $script:AppLocations[$id] -DetectName $script:AppDetectNames[$id] }
            $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$id; Content=$id; Status=($(if ($ok) {'OK'} else {'FAILED'})); Detail='' })
            if ($ok -and $script:DesktopShortcutApps.ContainsKey($id)) { $sc = $script:DesktopShortcutApps[$id]; New-DesktopShortcut -Name $sc.Name -Exe $sc.Exe }
            if ($id -eq 'RARLab.WinRAR') { Set-WinRarLicense }   # license right after WinRAR installs (clean pairing)
        }
    } else {
        Write-Log ERROR "winget not found; skipping VC++/app installs. Install 'App Installer' (Microsoft.DesktopAppInstaller) and re-run."
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='winget'; Content='winget missing'; Status='SKIPPED'; Detail='no winget' })
    }

    # Non-winget apps (direct vendor download): Bitwarden, Parsec, NVIDIA App (GPU only)
    foreach ($d in $script:DirectApps) {
        $st = Install-DirectDownload @d
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$d.Name; Content=$d.Name; Status=$st; Detail='direct' })
        if ($st -eq 'OK' -and $script:DesktopShortcutApps.ContainsKey($d.Name)) { $sc = $script:DesktopShortcutApps[$d.Name]; New-DesktopShortcut -Name $sc.Name -Exe $sc.Exe }
        if ($d.Name -eq 'Google Chrome') { $script:ChromePinned = Add-ChromeTaskbarPin }   # pin Chrome to the taskbar RIGHT AFTER it installs
    }

    # (WinRAR license is created right after WinRAR installs, in the loop above - see Set-WinRarLicense.)

    # Machine-specific apps LAST - auto-installed based on the "PC or Laptop?" answer (no prompt).
    #   HP Support Assistant -> Laptop only;  Alienware Command Center -> PC only.
    foreach ($a in $script:MachineApps) {
        if ($a.Machine -ne $script:MachineType) {
            Write-Log DEBUG "$($a.Name): skipped ($($a.Machine)-only; this machine is $($script:MachineType))"
            $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$a.Id; Content=$a.Name; Status='SKIPPED'; Detail="$($a.Machine)-only" })
            continue
        }
        # Alienware returns a STATUS (OK/SKIPPED/FAILED) - not-Alienware-hardware is SKIPPED, not FAILED.
        if ($a.Id -eq '9PMHP03NJ9QP') { $st = Install-Alienware }
        else { $st = if (Install-App -Id $a.Id -Name $a.Name -Source $a.Source) { 'OK' } else { 'FAILED' } }
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$a.Id; Content=$a.Name; Status=$st; Detail=$a.Machine })
    }

    # (.NET 3.5 was started in the BACKGROUND before this phase (Start-DotNet35) so it downloads in
    #  parallel; it's finished after this phase (Enable-DotNetFeatures). Desktop icons are per-app above.)
}

function Start-DotNet35 {
    # Kick off the SLOW NetFx3 (.NET 3.5) Windows-Update download in the BACKGROUND, BEFORE the install
    # phase, so it overlaps the ~15 min of app installs instead of adding ~11 min serially at the end.
    # Finished by Enable-DotNetFeatures. (Runs after the tweaks' Recall DISM, so no DISM-vs-DISM clash.)
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would start .NET 3.5 (NetFx3) download in the background"; return }
    if ((Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction SilentlyContinue).State -eq 'Enabled') {
        Write-Log DEBUG ".NET 3.5 already enabled - nothing to start"; return
    }
    $dlog = Join-Path $env:TEMP 'dism_NetFx3.log'
    Write-Log DEBUG "starting .NET 3.5 (NetFx3) download in the background (shown as Installing/Done at the end)"
    try {
        $script:DotNet35Proc = Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" -WindowStyle Hidden -PassThru `
            -ArgumentList '/Online','/Enable-Feature','/FeatureName:NetFx3','/All','/NoRestart','/Quiet',"/LogPath:$dlog"
    } catch { Write-Log DEBUG ".NET 3.5 background start failed: $($_.Exception.Message)" }
}

function Enable-DotNetFeatures {
    # Print a clean "Installing .NET 3.5 / Done!" pair HERE at the end. The download already ran in the
    # background during the install phase (Start-DotNet35), so this is usually instant. Then .NET 4 (quiet).
    if ($script:DryRun) {
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NetFx3'; Content='.NET 3.5'; Status='DRYRUN'; Detail='' })
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NetFx4-AdvSrvs'; Content='.NET 4'; Status='DRYRUN'; Detail='' })
        return
    }
    Write-Log INFO "Installing .NET 3.5"
    $st3 = 'OK'
    if ((Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction SilentlyContinue).State -eq 'Enabled') {
        Write-Log OK "Done!"
    } elseif ($script:DotNet35Proc) {
        # It's been downloading from Windows Update since BEFORE the install phase. Give it a SHORT grace
        # to finish; if it's genuinely slow (WU/disk-bound - can be ~30 min on a slow VM), DON'T block the
        # user for 15+ min. Let it finish in the BACKGROUND: the DISM process + TrustedInstaller keep going
        # after this script exits (and /NoRestart means no surprise reboot).
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $script:DotNet35Proc.HasExited -and $sw.Elapsed.TotalSeconds -lt 90) { Start-Sleep -Seconds 3 }
        Start-Sleep -Milliseconds 500
        if ((Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction SilentlyContinue).State -eq 'Enabled') {
            Write-Log OK "Done!"
        } else {
            Write-Log WARN ".NET 3.5 is still downloading from Windows Update (slow on this machine) - it will FINISH ON ITS OWN in the background. You can keep using the PC / close this window; just don't reboot until it's done."
            $st3 = 'BACKGROUND'
        }
    } else {
        Write-Log WARN "Failed - .NET 3.5 (was not started)"; $st3 = 'FAILED'
    }
    $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NetFx3'; Content='.NET 3.5'; Status=$st3; Detail='' })
    # .NET 4 is already enabled on Win11 -> record quietly (no console clutter); enable only if somehow off.
    if ((Get-WindowsOptionalFeature -Online -FeatureName 'NetFx4-AdvSrvs' -ErrorAction SilentlyContinue).State -eq 'Enabled') {
        Write-Log DEBUG ".NET 4 already enabled"
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NetFx4-AdvSrvs'; Content='.NET 4'; Status='OK'; Detail='already enabled' })
    } else {
        $st4 = Enable-Feature -Name 'NetFx4-AdvSrvs' -Display '.NET 4'
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NetFx4-AdvSrvs'; Content='.NET 4'; Status=$st4; Detail='' })
    }
}

function Write-Summary {
    Write-Log INFO "=========== SUMMARY ==========="
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

function Test-TaskbarPinned {
    # A taskbar-pinned item has a matching <Name>.lnk in the User Pinned\TaskBar Quick Launch folder (Win11).
    param([string]$Name)
    Test-Path (Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\$Name.lnk")
}

function Get-PinHelper {
    # Return a ready-to-use Pin-Taskbar helper path (in TEMP), fetching it ONCE and only when needed. Prefer
    # OUR copy next to the script (download/.bat -> no download); else fetch OUR copy from OUR repo (one-liner).
    # Cached in $script:PinHelper (deleted by Add-ChromeTaskbarPin). Returns $null on failure.
    if ($script:PinHelper -and (Test-Path $script:PinHelper)) { return $script:PinHelper }
    $helper = Join-Path $env:TEMP 'Pin-Taskbar.ps1'
    try {
        $bundled = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Pin-Taskbar.ps1' } else { $null }
        if ($bundled -and (Test-Path $bundled)) {
            Copy-Item -LiteralPath $bundled -Destination $helper -Force
            Write-Log DEBUG "using the bundled Pin-Taskbar helper (next to the script - no download)"
        } else {
            Write-Log INFO "fetching the Pin-Taskbar helper (our copy, from our repo; temporary)"
            $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri 'https://gitlab.msuhost.com/superuser/win11-tweaks/-/raw/main/Pin-Taskbar.ps1' -OutFile $helper -UseBasicParsing -ErrorAction Stop
            $ProgressPreference = $pp
        }
        Unblock-File $helper -ErrorAction SilentlyContinue
        $script:PinHelper = $helper
        return $helper
    } catch { Write-Log WARN "could not get the Pin-Taskbar helper: $($_.Exception.Message)"; return $null }
}

function Invoke-TaskbarPins {
    # Pin "This PC" + unpin Edge/Store on the taskbar via the Pin-Taskbar helper. IDEMPOTENT: skips any item
    # already in the desired state, so a re-run doesn't re-pin. The helper is fetched only if something's needed.
    if ($script:DryRun) {
        Write-Log DEBUG "[DRYRUN] would pin 'This PC' and unpin Edge + Store on the taskbar (only what's not already set)"
        $script:Results.Add([pscustomobject]@{ Phase='Taskbar'; Id='Taskbar.Pins'; Content='Taskbar pins (This PC / -Edge / -Store)'; Status='DRYRUN'; Detail='' }); return
    }
    $needThisPC = -not (Test-TaskbarPinned 'This PC')
    $needEdge   = Test-TaskbarPinned 'Microsoft Edge'
    $needStore  = Test-TaskbarPinned 'Microsoft Store'
    if (-not ($needThisPC -or $needEdge -or $needStore)) {
        Write-Log DEBUG "taskbar already set (This PC pinned, Edge/Store unpinned) - nothing to do"; return
    }
    $helper = Get-PinHelper
    if (-not $helper) { $script:Results.Add([pscustomobject]@{ Phase='Taskbar'; Id='Taskbar.Pins'; Content='Taskbar pins'; Status='FAILED'; Detail='no helper' }); return }
    # (a) PIN "This PC" - only if not already pinned
    if ($needThisPC) {
        $r = [pscustomobject]@{ Phase='Taskbar'; Id='ThisPC.Pin'; Content='This PC pinned to taskbar'; Status='FAILED'; Detail='' }
        try {
            $lnk = Join-Path $env:LOCALAPPDATA 'This PC.lnk'
            $wsh = New-Object -ComObject WScript.Shell; $sc = $wsh.CreateShortcut($lnk)
            $sc.TargetPath = "$env:SystemRoot\explorer.exe"; $sc.Arguments = 'shell:MyComputerFolder'
            $sc.IconLocation = "$env:SystemRoot\System32\imageres.dll,-109"; $sc.Description = 'This PC'; $sc.Save()
            & $helper $lnk -Silent
            Write-Log OK "pinned This PC to the taskbar"; $r.Status = 'OK'
        } catch { Write-Log WARN "This PC pin failed: $($_.Exception.Message)"; $r.Detail = $_.Exception.Message }
        $script:Results.Add($r)
    } else { Write-Log DEBUG "This PC already pinned - skipping" }
    # (b) UNPIN Edge + Store - only if currently pinned
    foreach ($app in 'Microsoft Edge', 'Microsoft Store') {
        if (-not (Test-TaskbarPinned $app)) { Write-Log DEBUG "$app already unpinned - skipping"; continue }
        $u = [pscustomobject]@{ Phase='Taskbar'; Id="Unpin.$app"; Content="Unpinned $app from taskbar"; Status='FAILED'; Detail='' }
        try { & $helper $app -Unpin -Silent; Write-Log OK "unpinned $app from the taskbar"; $u.Status = 'OK' }
        catch { Write-Log WARN "unpin $app failed: $($_.Exception.Message)"; $u.Detail = $_.Exception.Message }
        $script:Results.Add($u)
    }
    # (helper kept for Add-ChromeTaskbarPin, which deletes it)
}

function Add-ChromeTaskbarPin {
    # Pin Google Chrome to the taskbar AFTER it installs (Chrome is a direct-download app in the install
    # phase, so this can't run in Invoke-TaskbarPins, which is before the installs). Reuses the kept
    # Pin-Taskbar helper, then DELETES it. Returns $true if it pinned, so Main knows to refresh the taskbar.
    $pinned = $false
    try {
        if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would pin Google Chrome to the taskbar (if not already)"; return $false }
        $chromeExe = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        if (-not (Test-Path $chromeExe)) { Write-Log DEBUG "Chrome not installed - skipping taskbar pin"; return $false }
        if (Test-TaskbarPinned 'Google Chrome') { Write-Log DEBUG "Google Chrome already pinned - skipping"; return $false }
        $helper = Get-PinHelper
        if (-not $helper) { return $false }
        $lnk = Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Filter 'Google Chrome.lnk' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        $target = if ($lnk) { $lnk.FullName } else { $chromeExe }
        & $helper $target -Silent
        Write-Log OK "pinned Google Chrome to the taskbar"
        $script:Results.Add([pscustomobject]@{ Phase='Taskbar'; Id='Chrome.Pin'; Content='Google Chrome pinned to taskbar'; Status='OK'; Detail='' })
        $pinned = $true
    } catch {
        Write-Log WARN "Chrome taskbar pin failed: $($_.Exception.Message)"
        $script:Results.Add([pscustomobject]@{ Phase='Taskbar'; Id='Chrome.Pin'; Content='Google Chrome pinned to taskbar'; Status='FAILED'; Detail=$_.Exception.Message })
    } finally {
        if ($script:PinHelper) { Remove-Item $script:PinHelper -Force -ErrorAction SilentlyContinue; $script:PinHelper = $null }   # delete the kept helper
    }
    return $pinned
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
            $script:Cancelled = $true   # NOT `exit` - that would close the host window when run via `irm|iex`
            return
        }
    }
    # Machine type - gates HP Support Assistant (Laptop only) and Alienware Command Center (PC only).
    if ($Machine -eq 'PC' -or $Machine -eq 'Laptop') {
        $script:MachineType = if ($Machine -eq 'Laptop') { 'Laptop' } else { 'PC' }
    } elseif ([Environment]::UserInteractive) {
        do { $mt = Read-Host "  Is this a Desktop PC or a Laptop?   [1] PC    [2] Laptop" }
        until ($mt -match '^\s*[12]\s*$')
        $script:MachineType = if ($mt.Trim() -eq '2') { 'Laptop' } else { 'PC' }
    } else {
        $script:MachineType = 'PC'   # non-interactive default (override with -Machine PC|Laptop)
    }
    Write-Log INFO ("Machine type: {0}" -f $script:MachineType)
}

# --------------------------------------------------------------------------------------
#  Main
# --------------------------------------------------------------------------------------
try {
    Show-Intro
    if ($script:Cancelled) { return }   # user answered "n" to Continue
    Write-Banner
    if ($script:DryRun) { Write-Log WARN "DRY RUN - no changes will be made." }
    Invoke-Tweaks
    Invoke-TaskbarPins        # This PC pin + unpin Edge/Store BEFORE installs...
    if ($script:NeedExplorerRestart -and -not $script:DryRun) { Update-Explorer -Action restart }   # ...then restart explorer so the taskbar/desktop is already clean (no Widgets/Search) during the installs
    Start-DotNet35            # fire the slow .NET 3.5 WU download NOW so it overlaps the install phase (parallel)
    Invoke-InstallPhase       # apps + per-app desktop icons (Chrome is pinned right after it installs, inside this)
    if ($script:ChromePinned -and -not $script:DryRun) { Update-Explorer -Action restart }   # refresh the taskbar to show the Chrome pin
    Enable-DotNetFeatures     # finish .NET 3.5 (usually already done) + .NET 4
    Write-Summary
    Write-Log INFO "=========== WIN11-TWEAKS DONE ==========="
    if ($Reboot -and -not $script:DryRun) {
        Write-Log WARN "Rebooting in 15s (-Reboot given). Press Ctrl+C to cancel."
        Start-Sleep -Seconds 15
        Restart-Computer -Force
    }
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}
