#Requires -Version 5.1
<#
.SYNOPSIS
    Applies a fixed set of Windows 11 tweaks, then installs a defined application set via
    winget (plus Visual C++ redists, .NET features and, on a PC, the chipset / Radeon drivers from
    the maker's own site). No GUI. The console shows a compact view of the run (a rail: the tweaks as
    groups, one line per app, the step running now); everything goes to a log file for later.

.DESCRIPTION
    The 53 tweaks (25 standard + 28 custom) and the install list are a fixed, curated set
    (see docs/2026-07-11-win11-tweaks-design.md). Only the ON toggles / checked items are
    applied; nothing else is touched.
    The script makes NO restore point and does NOT reboot unless -Reboot is given.

.PARAMETER DryRun
    Log what WOULD happen and make NO system changes. Recommended for the first run.

.PARAMETER Reboot
    Reboot 15 seconds after finishing (cancellable with Ctrl+C). Off by default.

.PARAMETER Machine
    'PC' or 'Laptop'. Skips the interactive "PC or Laptop?" question at startup. A laptop skips
    the PC-only items: the Ultimate Performance power plan (a laptop gets Ultimate on the charger +
    Balanced on battery instead), hibernation off, the highest monitor refresh rate and NZXT CAM; a PC
    skips the laptop-only items (that power plan, no network while asleep on battery). (Alienware Command Center goes by the actual
    hardware, not by this answer.) If omitted: ask interactively, or default to 'PC' when non-interactive.

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
$script:MachineType          = ''      # 'PC' or 'Laptop' - resolved in Show-Intro; a laptop skips the PC-only tweaks/apps
$script:WarnCount            = 0       # WARN lines logged so far - a tweak that logs one is reported WARN, not OK
$script:RunStarted           = $false  # past the intro -> Main's finally writes the summary (also after Ctrl+C)
$script:RunFinished          = $false  # got to the end without being stopped
$script:DotNet35Proc         = $null   # background DISM process for .NET 3.5 (started early, finished at the end)
$script:PinHelper            = $null   # Pin-Taskbar helper path (kept after Invoke-TaskbarPins for the Chrome pin)
$script:ChromePinned         = $false  # set by Add-ChromeTaskbarPin (right after Chrome installs) - Main refreshes the taskbar if true
$script:NotSelected          = @{}     # apps a "New user" said n to (winget ID / direct-app Name / vendor Id) - the install phase skips them
$script:KeepApps             = @{}     # built-in apps a "New user" keeps (appx name -> label) - the app removal leaves them
$script:SettingsPagesHidden  = @()     # Settings pages hidden so far in this run (SettingsPageVisibility is one merged string)
$script:ConsoleModeSaved     = $null   # console input mode before Set-QuickEdit turned QuickEdit off (put back at the end)
$script:Results              = [System.Collections.Generic.List[object]]::new()
# The console view ("Rail", superuser's pick from the design page, 2026-09-28) - see Write-Ui
$script:Version              = '1.6.0' # on the rail head - bumped with every release
$script:Ui                   = -not $script:Detailed   # the console shows the rail; -Detailed puts the full log there instead
$script:UiLines              = [System.Collections.Generic.List[string]]::new()   # every rail line printed (the tests read it)
$script:UiLive               = ''      # what the live line shows right now
$script:LiveOpen             = $false  # the live line is on the console without its newline yet
$script:Live                 = $null   # the step running now: Name / What / Clock - Update-LiveTick redraws it with the time
$script:UiNotes              = @{}     # tweak Id -> what came of it, for its Finishing line ('7 removed: ...')
$script:UiCount              = @{ Appx = 0; Svc = 0 }   # apps removed / services changed - for the tweak group lines
$script:UiRemoved            = [System.Collections.Generic.List[string]]::new()   # old components removed (their labels)
$script:ItemNote             = ''      # what an installer says about the app it just handled ('already installed', a skip reason)
$script:ItemFail             = ''      # ... or why it failed ('winget exit code 0x8A150011')
$script:RunClock             = $null   # started when the run starts ("Done in 19m 29s")
$script:DotNet35Clock        = $null   # started with the .NET 3.5 download
$script:UserLabel            = 'Gele'  # "Gele" / "New user, 14 of 21 apps" - on the machine line
$script:LastPrompt           = ''      # the question on the console right now, as plain text
# Console glyphs - made at run time, so this file stays pure ASCII. Only characters Cascadia Mono AND Consolas have: the
# old console (conhost) has no fallback font, so anything else (rounded corners, check marks, braille spinners) shows as a box.
$script:G = @{
    Top = [string][char]0x250C; Bar = [string][char]0x2502; Tee = [string][char]0x251C; End = [string][char]0x2514
    Rule = [string][char]0x2500; Ok = [string][char]0x221A; Dot = [string][char]0x00B7; Fail = [string][char]0x00D7
    Run = [string][char]0x25BA; Next = [string][char]0x203A; Full = [string][char]0x2588; Empty = [string][char]0x2591
    More = [string][char]0x2026; Dash = [string][char]0x2013
}
# Rail markup "{b:text}" -> console colour. Only the 16 console colours - they follow the terminal's colour scheme.
# Blue is #3B78FF in Windows Terminal's default scheme - the MSUHost blue.
$script:UiColors = @{ d = 'DarkGray'; w = 'White'; b = 'Blue'; g = 'Green'; y = 'Yellow'; r = 'Red'; c = 'Cyan' }

# --------------------------------------------------------------------------------------
#  Bootstrap: elevation, HKU: drive, log file + transcript
# --------------------------------------------------------------------------------------
# Self-elevate to Administrator (the script edits HKLM + services). Works BOTH when run from a file
# (.bat / -File) AND via the `irm <url> | iex` one-liner - in the one-liner case there is no local
# file to re-run, so the script is saved to a file from its known raw URL and THAT file is relaunched.
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
            $scriptFile = $PSCommandPath
            $fwd = foreach ($k in $PSBoundParameters.Keys) {
                $v = $PSBoundParameters[$k]
                if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { "-$k" } }
                else { "-$k"; ('"{0}"' -f $v) }
            }
        } else {
            # running via `irm | iex` (no file) -> save the script to a file and relaunch THAT. NOT a new
            # PowerShell with the download-and-run command on its command line: that's exactly what malware
            # does, and Microsoft Defender's ML blocks it as a threat (typed at a prompt it's fine - spawned
            # it isn't). Outside TEMP, which the "Temporary Files" tweak empties; the log stays on the Desktop.
            $dir = Join-Path $env:LOCALAPPDATA 'win11-tweaks'
            $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
            $scriptFile = Join-Path $dir 'Invoke-Win11Tweaks.ps1'
            Invoke-WebRequest -Uri $SelfUrl -OutFile $scriptFile -UseBasicParsing -ErrorAction Stop
            $fwd = @('-LogDir', ('"{0}"' -f [Environment]::GetFolderPath('Desktop')))
        }
        $argList = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"{0}"' -f $scriptFile)) + $fwd   # -NoLogo: the rail starts at the top
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $argList
        exit   # elevated instance launched -> close THIS original (non-admin) window
    } catch {
        # the real reason: UAC answered "No", or the antivirus blocked it, or the download failed
        Write-Host ("Could not relaunch elevated: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host "Open PowerShell as Administrator and run it there." -ForegroundColor Red
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
    # EVERY line goes to the LOG FILE (every level, with the [Id] tag). The console shows the rail instead (Write-Ui) -
    # unless -Detailed, which puts the log itself on the console, DEBUG lines included (the tag is left out there).
    param(
        [ValidateSet('DEBUG','INFO','OK','WARN','ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message,
        [string]$Id = ''
    )
    $ts  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $tag = if ($Id) { "[$Id] " } else { '' }
    try { Add-Content -Path $script:LogFile -Value ("{0} [{1,-5}] {2}{3}" -f $ts, $Level, $tag, $Message) -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    if ($Level -eq 'WARN') { $script:WarnCount++ }   # Invoke-Tweaks compares this before/after each tweak
    if (-not $script:Detailed) { return }
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host ("{0} [{1,-5}] {2}" -f $ts, $Level, $Message) -ForegroundColor $color
}

# --------------------------------------------------------------------------------------
#  The console view ("Rail"): a rail down the left from the questions to the result - the tweaks as groups, one line
#  per app with its time, .NET 3.5, Finishing, "Done in". The step running now is ONE live line, redrawn in place.
#  Console only: the log file keeps every detail. Markup: "{b:text}" = text in console colour b ($script:UiColors).
# --------------------------------------------------------------------------------------
function Get-UiWidth {
    # The width a rail line may use: the window minus one (so it never wraps), at most 94. 94 where there's no window.
    $w = 0; try { $w = [int]$Host.UI.RawUI.WindowSize.Width } catch { }
    if ($w -lt 40) { return 94 }
    return [math]::Min($w - 1, 94)
}

function Get-Visible {
    # A rail line as it reads on the screen (the markup taken out)
    param([string]$Markup)
    return ($Markup -replace '\{[a-z]+:([^{}]*)\}', '$1')
}

function Get-Cut {
    # $Text cut to $Max characters - ending in an ellipsis when it had to be cut
    param([string]$Text, [int]$Max)
    if ($Max -le 0) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 1) + $script:G.More
}

function Format-Span {
    # 30ms / 4.3s / 31s / 1m 50s - in the invariant culture: a Bulgarian Windows would write 4,3s
    param([double]$Seconds)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Seconds -lt 1) { return [string]::Format($inv, '{0}ms', [math]::Max(1, [int][math]::Round($Seconds * 1000))) }
    if ($Seconds -lt 10) { return [string]::Format($inv, '{0:0.0}s', $Seconds) }
    $r = [int][math]::Round($Seconds)
    if ($r -lt 60) { return "${r}s" }
    return [string]::Format($inv, '{0}m {1:00}s', [math]::Floor($r / 60), $r % 60)
}

function Write-Markup {
    # Print rail markup: "{b:text}" in console colour b, everything else in the console's own colour
    param([string]$Markup, [switch]$NoNewline)
    $pos = 0
    foreach ($m in [regex]::Matches($Markup, '\{([a-z]+):([^{}]*)\}')) {
        if ($m.Index -gt $pos) { Write-Host $Markup.Substring($pos, $m.Index - $pos) -NoNewline }
        $text = $m.Groups[2].Value; $color = $script:UiColors[$m.Groups[1].Value]
        if ($text -and $color) { Write-Host $text -NoNewline -ForegroundColor $color } elseif ($text) { Write-Host $text -NoNewline }
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $Markup.Length) { Write-Host $Markup.Substring($pos) -NoNewline }
    if (-not $NoNewline) { Write-Host '' }
}

function Test-LiveConsole {
    # Can a line be redrawn in place here? Not when the output goes to a pipe or a file (SSH, a transcript) - every
    # redraw would land there as a line of its own.
    try { return -not [Console]::IsOutputRedirected } catch { return $false }
}

function Clear-Live {
    # Wipe the live line so the next line starts clean
    if (-not $script:LiveOpen) { return }
    Write-Host ("`r" + (' ' * (Get-UiWidth)) + "`r") -NoNewline
    $script:LiveOpen = $false
}

function Write-Ui {
    # One line of the rail. -Always: with -Detailed too (the rail head and the questions).
    param([string]$Markup = '', [switch]$Always)
    if (-not ($script:Ui -or $Always)) { return }
    Clear-Live
    $script:UiLines.Add($Markup)
    Write-Markup $Markup
}

function Show-Live {
    # The live line: the step running now, redrawn in place on ONE console line (padded, so a shorter text leaves
    # nothing of the longer one behind)
    param([string]$Markup)
    if (-not $script:Ui) { return }
    $script:UiLive = $Markup
    if (-not (Test-LiveConsole)) { return }
    $pad = (Get-UiWidth) - (Get-Visible $Markup).Length
    Write-Host "`r" -NoNewline
    Write-Markup $Markup -NoNewline
    if ($pad -gt 0) { Write-Host (' ' * $pad) -NoNewline }
    $script:LiveOpen = $true
}

function Format-Row {
    # "  |  <glyph> <Name padded>  <text, cut to fit>  <right, flush with the right edge>" - $Glyph is markup
    param([string]$Glyph, [string]$Name, [string]$Text = '', [string]$TextColor = 'd', [string]$Right = '',
          [string]$RightColor = 'd', [int]$NameWidth = 18)
    $plain = { param($s) ([string]$s) -replace '\{', '(' -replace '\}', ')' }   # braces would break the markup
    $w = Get-UiWidth
    $n = Get-Cut (& $plain $Name) ($NameWidth - 1)
    $line = "  {d:$($script:G.Bar)}  $Glyph {w:$n}" + (' ' * ($NameWidth - $n.Length))
    $used = 7 + $NameWidth
    $Right = & $plain $Right
    $t = Get-Cut (& $plain $Text) ($w - $used - $(if ($Right) { $Right.Length + 2 } else { 0 }))
    if ($t) { $line += $(if ($TextColor) { "{${TextColor}:$t}" } else { $t }) }
    if ($Right) {
        $gap = [math]::Max(2, $w - $used - $t.Length - $Right.Length)
        $line += (' ' * $gap) + $(if ($RightColor) { "{${RightColor}:$Right}" } else { $Right })
    }
    return $line
}

function Get-Glyph {
    # the status glyph, in its colour
    param([string]$Status, [switch]$Warn)
    switch ($Status) {
        'OK'     { if ($Warn) { return '{y:!}' }; return "{g:$($script:G.Ok)}" }
        'WARN'   { return '{y:!}' }
        'FAILED' { return "{r:$($script:G.Fail)}" }
        default  { return "{d:$($script:G.Dot)}" }   # SKIPPED / DRYRUN / BACKGROUND
    }
}

function Format-Blocks {
    # a bar of $Width blocks, $Done of $Total filled (superuser's services bar, on the rail)
    param([int]$Done, [int]$Total, [int]$Width = 20)
    $f = [int][math]::Floor($Width * $Done / [math]::Max($Total, 1))
    return "{b:$($script:G.Full * $f)}{d:$($script:G.Empty * ($Width - $f))}"
}

function Write-UiPhase {
    # "  |" then "  |- Name" - the start of a phase on the rail
    param([string]$Name, [string]$Rest = '')
    Write-Ui "  {d:$($script:G.Bar)}"
    Write-Ui ("  {d:$($script:G.Tee)$($script:G.Rule)} {w:$Name}" + $Rest)
}

function Show-LiveText {
    # a live line that is just a text: "  |  > restarting Explorer"
    param([string]$Text)
    Show-Live (Format-Row -Glyph "{b:$($script:G.Run)}" -Name $Text -NameWidth 60)
}

function Start-LiveItem {
    # The live line for one step: "  |  > Name   what   mm:ss" - its clock ticks while Update-LiveTick is called
    param([string]$Name, [string]$What = '')
    $script:Live = @{ Name = $Name; What = $What; Clock = [System.Diagnostics.Stopwatch]::StartNew() }
    Update-LiveTick
}

function Set-LiveWhat {
    param([string]$What)
    if ($script:Live) { $script:Live.What = $What; Update-LiveTick }
}

function Update-LiveTick {
    # redraw the live step with its clock (about once a second while an installer runs)
    if (-not $script:Live) { return }
    $s = [int][math]::Floor($script:Live.Clock.Elapsed.TotalSeconds)
    Show-Live (Format-Row -Glyph "{b:$($script:G.Run)}" -Name $script:Live.Name -Text $script:Live.What `
        -Right ('{0:00}:{1:00}' -f [math]::Floor($s / 60), ($s % 60)) -RightColor 'b' -NameWidth 32)
}

function Stop-LiveItem {
    # how long the live step took (seconds; -1 if there was none)
    $s = if ($script:Live) { $script:Live.Clock.Elapsed.TotalSeconds } else { -1 }
    $script:Live = $null
    return $s
}

function Get-ShortName {
    # "Old Windows components - Remove (...)" -> "Old Windows components"
    param([string]$Content)
    return (($Content -split ' - ')[0]).Trim()
}

function Set-UiNote {
    # what came of a tweak, for its line on the rail ('7 removed: ...', '64 Hz, already the highest')
    param([string]$Id, [string]$Text)
    $script:UiNotes[$Id] = $Text
}

function Read-Answer {
    # A question on ONE line: the prompt (markup), then the answer typed right after it. Read-Host gets no prompt of its
    # own, so Windows PowerShell adds no ": ". Returns $null when there's no keyboard (input redirected).
    param([string]$Prompt)
    Clear-Live
    $script:LastPrompt = Get-Visible $Prompt
    $script:UiLines.Add($Prompt)
    Write-Markup $Prompt -NoNewline
    $ans = Read-Host
    if ($null -eq $ans) { Write-Host '' }   # no keyboard: nothing ended the line
    return $ans
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
    # not a failure: the service doesn't exist on this edition (e.g. CscService on Home) - nothing to change
    if (-not $svc) { Write-Log DEBUG "service $Name not present on this system; skipping" $Id; return }
    if ($OriginalType -and ($svc.StartType.ToString() -ne $OriginalType)) {
        Write-Log DEBUG "service $Name already customized (is $($svc.StartType), expected $OriginalType); leaving as-is" $Id
        return
    }
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would set service $Name -> $StartupType" $Id; return }
    try {
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        Write-Log DEBUG "service $Name -> $StartupType" $Id
        $script:UiCount.Svc++
    } catch {
        Write-Log WARN "service $Name failed: $($_.Exception.Message)" $Id
    }
}

function Remove-Appx {
    # Remove a Store app for every user + its provisioned copy (so new accounts don't get it). $Name may hold
    # wildcards. Checked afterwards: a package Windows kept is a WARN, not a silent "removed".
    param([string]$Name, [string]$Id = '')
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would remove appx '$Name' (+ provisioned)" $Id; return }
    try {
        $had = @(Get-AppxPackage $Name -AllUsers -ErrorAction SilentlyContinue)
        if ($had) { $had | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue }
        $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $Name })
        foreach ($p in $prov) { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction SilentlyContinue | Out-Null }
        if (-not ($had -or $prov)) { Write-Log DEBUG "appx '$Name' not installed" $Id; return }
        if (Get-AppxPackage $Name -ErrorAction SilentlyContinue) { Write-Log WARN "appx '$Name' is still installed - Windows did not remove it" $Id }
        else { Write-Log DEBUG "removed appx '$Name'" $Id; $script:UiCount.Appx++ }
    } catch {
        Write-Log WARN "appx '$Name' failed: $($_.Exception.Message)" $Id
    }
}

function Get-RegValue {
    # One registry value, or $null when the key or value isn't there.
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Remove-RegKey {
    # Delete a registry key with everything under it (DryRun-aware; a missing key is fine).
    param([string]$Path, [string]$Id = '')
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would delete $Path" $Id; return }
    if (-not (Test-Path -LiteralPath $Path)) { Write-Log DEBUG "$Path not there - nothing to delete" $Id; return }
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; Write-Log DEBUG "deleted $Path" $Id }
    catch { Write-Log WARN "could not delete ${Path}: $($_.Exception.Message)" $Id }
}

function Add-SettingsPageHidden {
    # Hide one Settings page with the machine policy SettingsPageVisibility. It is ONE string for every page
    # ("hide:aicomponents;home"), so this merges: the pages already listed + the ones hidden earlier in this run
    # (in a DryRun nothing is written in between) + this one. A "showonly:" list is someone else's policy - left alone.
    param([string]$Page, [string]$Id = '')
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    $cur = [string](Get-RegValue -Path $path -Name 'SettingsPageVisibility')
    if ($cur.Trim() -and $cur -notmatch '^\s*hide:') {
        Write-Log WARN ("SettingsPageVisibility is '{0}' (not a hide: list) - left as is, '{1}' not hidden" -f $cur, $Page) $Id; return
    }
    $pages = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @(($cur -replace '^\s*hide:', '') -split ';') + @($script:SettingsPagesHidden) + @($Page)) {
        $p = "$p".Trim()
        if ($p -and -not ($pages -contains $p)) { $pages.Add($p) }
    }
    $script:SettingsPagesHidden = @($pages)
    Set-Reg -Id $Id -Path $path -Name 'SettingsPageVisibility' -Type String -Value ('hide:' + ($pages -join ';'))
}

function Remove-WinCapability {
    # Remove an optional Windows capability ("Name~~~~version") if it is installed. They come back from
    # Settings > System > Optional features. Logged at INFO: each one takes a while and the console must not look stuck.
    param([string]$Name, [string]$Label, [string]$Id = '')
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would remove capability $Name ($Label)" $Id; return }
    try {
        $caps = @(Get-WindowsCapability -Online -Name "$Name~~~~*" -ErrorAction Stop | Where-Object { "$($_.State)" -eq 'Installed' })
        if (-not $caps) { Write-Log DEBUG "$Label not installed - nothing to remove" $Id; return }
        Write-Log INFO "removing $Label" $Id
        Set-LiveWhat $Label
        foreach ($c in $caps) { $null = Remove-WindowsCapability -Online -Name $c.Name -ErrorAction Stop }
        Write-Log DEBUG "removed $Label" $Id
        if (-not $script:UiRemoved.Contains($Label)) { $script:UiRemoved.Add($Label) }
    } catch { Write-Log WARN "$Label could not be removed: $($_.Exception.Message)" $Id }
}

function Disable-WinFeature {
    # Turn a Windows optional feature off (like "Turn Windows features on or off"), if it is on. No reboot.
    param([string]$Name, [string]$Label, [string]$Id = '')
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would disable feature $Name ($Label)" $Id; return }
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction SilentlyContinue
        if (-not $f -or "$($f.State)" -ne 'Enabled') { Write-Log DEBUG "$Label not enabled - nothing to do" $Id; return }
        Write-Log INFO "removing $Label" $Id
        Set-LiveWhat $Label
        $null = Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop
        Write-Log DEBUG "disabled $Label" $Id
        $base = $Label -replace '\s*\(feature\)$', ''   # WMP Legacy is a capability AND a feature - one component
        if (-not $script:UiRemoved.Contains($base)) { $script:UiRemoved.Add($base) }
    } catch { Write-Log WARN "$Label could not be turned off: $($_.Exception.Message)" $Id }
}

function Test-RestartPending {
    # Windows servicing waits for a restart (a removed component, .NET 3.5 held back, a Windows update): those
    # changes complete only at a restart - a sign-out is not enough.
    Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
}

function Get-InstalledPrograms {
    # DisplayName of every desktop program in Add/Remove Programs (machine 64/32-bit + this user).
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($k in $keys) { Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object { [string]$_.DisplayName } }
}

function Get-DefaultProfilePath {
    # The profile new accounts are copied from (normally C:\Users\Default).
    $p = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name 'Default'
    if ($p) { return [Environment]::ExpandEnvironmentVariables([string]$p) }
    return (Join-Path $env:SystemDrive 'Users\Default')
}

function Clear-StartPins {
    # A fresh Windows pins ads to Start (Spotify, LinkedIn, games...) that install on click. Replace the Start layout
    # (start2.bin) with an empty one - for this user and for accounts created later (Default profile) - then restart
    # Start so it reads the file. ONCE per profile: the old file is saved as start2.bin.win11-tweaks.bak (an empty
    # .bak if there was none), and a profile that has that file already is left alone - a re-run must not wipe
    # the pins the user made since.
    param([string]$Id = '')
    $local = 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState'
    $dirs = @((Join-Path $env:LOCALAPPDATA $local), (Join-Path (Get-DefaultProfilePath) "AppData\Local\$local"))
    $blank = [Convert]::FromBase64String($script:StartBlankB64)
    $changed = 0
    foreach ($d in $dirs) {
        $bin = Join-Path $d 'start2.bin'; $bak = Join-Path $d 'start2.bin.win11-tweaks.bak'
        if (Test-Path -LiteralPath $bak) { Write-Log DEBUG "Start pins in $d were cleared on an earlier run - leaving them alone" $Id; continue }
        $null = New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $bin) { Copy-Item -LiteralPath $bin -Destination $bak -Force -ErrorAction Stop }
        else { [IO.File]::WriteAllBytes($bak, [byte[]]@()) }
        [IO.File]::WriteAllBytes($bin, $blank)
        Write-Log DEBUG "empty Start layout written to $bin (the old one: $bak)" $Id
        $changed++
    }
    # killed, not closed: a clean exit could save the old layout from memory over the new file. Windows restarts it.
    if ($changed) { Get-Process StartMenuExperienceHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
}

function Initialize-NativeW11T {
    # Screen modes (user32) and power-plan values (powrprof) for the refresh-rate and laptop-power tweaks. Compiled once
    # per PowerShell session and KEPT there: when this C# changes, bump the namespace (W11T2 -> W11T3), or a second run in
    # the same window would quietly use the old copy.
    if ('W11T2.Power' -as [type]) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace W11T2 {
    public static class Display {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DEVMODE {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
            public int dmFields; public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
            public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
            public int dmDisplayFlags; public int dmDisplayFrequency; public int dmICMMethod; public int dmICMIntent;
            public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2;
            public int dmPanningWidth; public int dmPanningHeight;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DISPLAY_DEVICE {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, int index, ref DISPLAY_DEVICE dd, int flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string device, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr param);

        // "device|monitor|current Hz|highest Hz|monitor interface path" per screen on the desktop. Highest = among the modes
        // Windows lists for that monitor (only modes it reports) at the CURRENT resolution and colour depth, not interlaced.
        public static string[] List() {
            List<string> res = new List<string>();
            for (int i = 0; ; i++) {
                DISPLAY_DEVICE dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
                if ((dd.StateFlags & 1) == 0) continue;                                   // not on the desktop
                DEVMODE cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
                if (!EnumDisplaySettings(dd.DeviceName, -1, ref cur)) continue;          // ENUM_CURRENT_SETTINGS
                int best = cur.dmDisplayFrequency;
                DEVMODE m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
                for (int n = 0; EnumDisplaySettings(dd.DeviceName, n, ref m); n++) {
                    if (m.dmPelsWidth == cur.dmPelsWidth && m.dmPelsHeight == cur.dmPelsHeight && m.dmBitsPerPel == cur.dmBitsPerPel
                        && (m.dmDisplayFlags & 2) == 0 && m.dmDisplayFrequency > best) best = m.dmDisplayFrequency;
                }
                DISPLAY_DEVICE mon = new DISPLAY_DEVICE(); mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                bool hasMon = EnumDisplayDevices(dd.DeviceName, 0, ref mon, 1);            // EDD_GET_DEVICE_INTERFACE_NAME
                res.Add(dd.DeviceName + "|" + (hasMon ? mon.DeviceString : dd.DeviceString) + "|" + cur.dmDisplayFrequency + "|" + best + "|" + (hasMon ? mon.DeviceID : ""));
            }
            return res.ToArray();
        }
        // One screen to hz at its current resolution: tested first, then applied and saved. 0 = done, 1 = after a restart.
        public static int SetRate(string device, int hz) {
            DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(device, -1, ref dm)) return -5;
            dm.dmDisplayFrequency = hz; dm.dmFields = 0x400000;                           // DM_DISPLAYFREQUENCY
            int rc = ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero, 2, IntPtr.Zero);  // CDS_TEST
            if (rc != 0 && rc != 1) return rc;                                            // 1 = fine, after a restart
            return ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero, 1, IntPtr.Zero);   // CDS_UPDATEREGISTRY - saved
        }
    }
    public static class Power {
        [DllImport("powrprof.dll")] static extern uint PowerEnumerate(IntPtr root, ref Guid scheme, IntPtr sub, int flags, uint index, byte[] buffer, ref uint size);
        [DllImport("powrprof.dll", EntryPoint = "PowerEnumerate")] static extern uint PowerEnumerateIn(IntPtr root, ref Guid scheme, ref Guid sub, int flags, uint index, byte[] buffer, ref uint size);
        [DllImport("powrprof.dll")] static extern uint PowerReadDCValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid setting, out uint value);
        [DllImport("powrprof.dll")] static extern uint PowerWriteDCValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid setting, uint value);
        // Every battery (DC) value of plan "from" written into plan "to"; returns how many.
        public static int CopyDc(Guid from, Guid to) {
            int copied = 0; byte[] buf = new byte[16];
            for (uint i = 0; ; i++) {
                uint size = 16;
                if (PowerEnumerate(IntPtr.Zero, ref from, IntPtr.Zero, 17, i, buf, ref size) != 0) break;        // ACCESS_SUBGROUP
                Guid sub = new Guid(buf);
                for (uint j = 0; ; j++) {
                    uint s2 = 16;
                    if (PowerEnumerateIn(IntPtr.Zero, ref from, ref sub, 18, j, buf, ref s2) != 0) break;       // ACCESS_INDIVIDUAL_SETTING
                    Guid setting = new Guid(buf);
                    uint v;
                    if (PowerReadDCValueIndex(IntPtr.Zero, ref from, ref sub, ref setting, out v) == 0 &&
                        PowerWriteDCValueIndex(IntPtr.Zero, ref to, ref sub, ref setting, v) == 0) copied++;
                }
            }
            return copied;
        }
    }
}
'@
}

function Get-MonitorLinks {
    # How each monitor is connected, from WMI: monitor instance ("DISPLAY\MSI3CB1\5&2E2A4B5&0&UID4353") -> 'DisplayPort',
    # 'HDMI', 'DVI', 'VGA', 'internal' or 'other'. (USB-C DisplayPort alt mode counts as DisplayPort; a screen tunnelled
    # through USB4 / Thunderbolt reports another type and is only logged.)
    $map = @{}
    foreach ($c in @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'WmiMonitorConnectionParams' -ErrorAction SilentlyContinue)) {
        $link = switch ([int64]$c.VideoOutputTechnology) { 10 { 'DisplayPort' } 11 { 'DisplayPort' } 5 { 'HDMI' } 4 { 'DVI' } 0 { 'VGA' } 2147483648 { 'internal' } default { 'other' } }
        $map[([string]$c.InstanceName -replace '_\d+$', '').ToUpperInvariant()] = $link
    }
    return $map
}

function Get-DisplayRates {
    # Every screen on the desktop: device, monitor name, current Hz, highest Hz Windows offers at the current resolution,
    # and how it is connected (Link).
    Initialize-NativeW11T
    $links = Get-MonitorLinks
    foreach ($l in [W11T2.Display]::List()) {
        $p = $l -split '\|'
        # interface path "\\?\DISPLAY#MSI3CB1#5&2e2a4b5&0&UID4353#{e6f07b5f-...}" -> WMI instance "DISPLAY\MSI3CB1\5&2E2A4B5&0&UID4353"
        $key = (($p[4] -replace '^\\\\\?\\', '') -replace '#\{[^}]*\}$', '' -replace '#', '\').ToUpperInvariant()
        $link = if ($key -and $links.ContainsKey($key)) { $links[$key] } else { 'unknown' }
        [pscustomobject]@{ Device = $p[0]; Name = $p[1]; Hz = [int]$p[2]; MaxHz = [int]$p[3]; Link = $link }
    }
}

function Set-DisplayRate {
    # One screen to $Hz (tested, then saved); returns Windows' DISP_CHANGE code (0 = done, 1 = after a restart).
    param([string]$Device, [int]$Hz)
    Initialize-NativeW11T
    return [W11T2.Display]::SetRate($Device, $Hz)
}

function Test-ScreenLocked {
    # The lock screen is up (Win+L) in this session - Windows then refuses display changes from the desktop.
    $me = (Get-Process -Id $PID).SessionId
    return [bool](Get-Process LogonUI -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $me })
}

function Set-MaxRefreshRate {
    # A 144 / 165 Hz monitor often comes set to 60 Hz: every screen to the highest refresh rate Windows offers for it at
    # its current resolution (only modes the monitor reports; each switch is tested before it is saved). DisplayPort
    # only: over HDMI an older cable, a KVM or an adapter can fail at a rate Windows lists - the screen goes black and
    # nobody is there to put it back - so an HDMI screen is only logged with what it could do.
    param([string]$Id = '')
    if (Test-ScreenLocked) {
        Write-Log WARN 'Refresh rate not changed: the screen was locked - run the script again at an unlocked screen, or set it in Settings > Display > Advanced display' $Id
        return
    }
    $notes = [System.Collections.Generic.List[string]]::new()   # one per screen, for the Finishing line
    foreach ($d in @(Get-DisplayRates)) {
        $label = if ($d.Name) { $d.Name } else { $d.Device }
        if ($d.MaxHz -le $d.Hz) {
            Write-Log DEBUG ("{0}: already at its highest refresh rate ({1} Hz)" -f $label, $d.Hz) $Id
            $notes.Add(('{0} Hz, already the highest' -f $d.Hz)); continue
        }
        if ($d.Link -ne 'DisplayPort') {
            Write-Log INFO ("{0} ({1}): up to {2} Hz is available - left at {3} Hz; set it in Settings > System > Display > Advanced display if the cable is up to it" -f $label, $d.Link, $d.MaxHz, $d.Hz) $Id
            $notes.Add(('{0}: left at {1} Hz, can do {2}' -f $d.Link, $d.Hz, $d.MaxHz)); continue
        }
        $rc = Set-DisplayRate -Device $d.Device -Hz $d.MaxHz
        if ($rc -eq 0 -or $rc -eq 1) {
            Write-Log INFO ("{0}: {1} Hz -> {2} Hz{3}" -f $label, $d.Hz, $d.MaxHz, $(if ($rc -eq 1) { ' (after a restart)' })) $Id
            $notes.Add(('{0} Hz to {1} Hz{2}' -f $d.Hz, $d.MaxHz, $(if ($rc -eq 1) { ' after a restart' })))
        }
        else { Write-Log WARN ("{0}: could not switch to {1} Hz (Windows answered {2}) - it stays at {3} Hz" -f $label, $d.MaxHz, $rc, $d.Hz) $Id }
    }
    if ($notes.Count) { Set-UiNote $Id ($notes -join '; ') }
}

function Copy-PowerDcValues {
    # Every battery (DC) value of plan $From into plan $To (GUIDs); returns how many were copied.
    param([string]$From, [string]$To)
    Initialize-NativeW11T
    return [W11T2.Power]::CopyDc([guid]$From, [guid]$To)
}

function Find-PowerPlan {
    # A plan this script made on an earlier run: the GUID remembered under $script:StateKey (works in every Windows
    # language, and for a plan powercfg -list doesn't show), else a plan listed with exactly this name.
    param([string]$StateName, [string]$Name)
    $g = [string](Get-RegValue -Path $script:StateKey -Name $StateName)
    if ($g) { $null = powercfg -query $g 2>&1; if ($LASTEXITCODE -eq 0) { return $g } }
    if ($Name) {
        $m = [regex]::Match((powercfg -list | Out-String), ('(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*\(' + [regex]::Escape($Name) + '\)'))
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

function New-PowerPlanCopy {
    # powercfg -duplicatescheme: the NEW plan's GUID, or $null when Windows refuses (Ultimate on a Modern Standby laptop).
    param([string]$From)
    $out = (powercfg -duplicatescheme $From 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { return $null }
    $m = [regex]::Match($out, '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    if ($m.Success) { return $m.Value }
    return $null
}

function Set-UltimateAcValues {
    # Ultimate Performance's plugged-in (AC) values, for a plan made from Balanced: the CPU never below 100%, no core
    # parking, aggressive boost, performance first; no sleep, hibernate, disk, USB or PCIe power saving on the charger.
    param([string]$Plan)
    $v = @(
        @('54533251-82be-4824-96c1-47b60b740d00', '893dee8e-2bef-41e0-89c6-b55d0929964c', 100),   # processor minimum state
        @('54533251-82be-4824-96c1-47b60b740d00', '0cc5b647-c1df-4637-891a-dec35c318583', 100),   # core parking: minimum cores
        @('54533251-82be-4824-96c1-47b60b740d00', 'be337238-0d82-4146-a960-4f3749d470c7', 2),     # boost mode: aggressive
        @('54533251-82be-4824-96c1-47b60b740d00', '36687f9e-e3a5-4dbf-b1dc-15eb381c6863', 0),     # energy performance preference
        @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '29f6c1db-86da-48c5-9fdb-f2b67b1f44da', 0),     # sleep after: never
        @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '9d7815a6-7ee4-497e-8888-515a05f02364', 0),     # hibernate after: never
        @('0012ee47-9041-4b5d-9b77-535fba8b1442', '6738e2c4-e8a5-4a42-b16a-e040e769756e', 0),     # turn off the disk: never
        @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', 0),     # USB selective suspend: off
        @('501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5', 0)      # PCI Express link power saving: off
    )
    foreach ($x in $v) { $null = powercfg -setacvalueindex $Plan $x[0] $x[1] $x[2] }
}

function Set-BalancedForX3D {
    # A dual-CCD Ryzen X3D keeps (or gets back) the Balanced plan - see Test-DualCcdX3D.
    param([string]$Id = '')
    $null = powercfg -setactive '381b4222-f694-41f0-9685-ff5bb260df2e'
    Write-Log INFO "Ryzen X3D with two CCDs: the Balanced plan stays - AMD's V-Cache driver needs its core parking to keep games on the V-Cache CCD (Ultimate would switch that off)" $Id
}

function Set-PcPowerPlan {
    # PC: the Ultimate Performance plan, active. The copy made on an earlier run is reused - remembered by GUID, so it is
    # found in any Windows language (the English name is the fallback for copies made by older versions).
    param([string]$Id = '')
    if (Test-DualCcdX3D) { Set-BalancedForX3D -Id $Id; return }
    $ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $guid = Find-PowerPlan -StateName 'PcPowerPlan' -Name 'Ultimate Performance'
    if (-not $guid) { $guid = New-PowerPlanCopy -From $ultimate }
    if ($guid) { Set-Reg -Id $Id -Path $script:StateKey -Name 'PcPowerPlan' -Type String -Value $guid }
    else { $guid = $ultimate }   # last resort: the template itself (it often won't activate)
    $null = powercfg -setactive $guid
    Write-Log DEBUG ("active scheme -> {0}" -f ((powercfg -getactivescheme | Out-String).Trim())) $Id
}

function Set-LaptopPowerPlan {
    # Laptop: ONE plan that is Ultimate Performance on the charger and Balanced on battery - a copy of Ultimate
    # Performance whose battery (DC) values are Balanced's, so Windows switches by itself when the cable comes out. A
    # Modern Standby laptop refuses to copy Ultimate: then a copy of Balanced with Ultimate's plugged-in values. The plan
    # is remembered (re-runs reuse it and refresh the battery values); it is never switched on without Balanced's
    # battery values - that would be Ultimate on battery.
    param([string]$Id = '')
    if (Test-DualCcdX3D) { Set-BalancedForX3D -Id $Id; return }
    $name = 'Ultimate + Balanced on battery'
    $balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $guid = Find-PowerPlan -StateName 'LaptopPowerPlan' -Name $name
    if (-not $guid) {
        $guid = New-PowerPlanCopy -From 'e9a42b02-d5df-448d-aa00-03f14749eb61'
        if (-not $guid) {
            $guid = New-PowerPlanCopy -From $balanced
            if (-not $guid) { throw 'Windows would not create a new power plan' }
            Set-UltimateAcValues -Plan $guid
            Write-Log INFO "No Ultimate Performance plan on this laptop (Modern Standby) - a copy of Balanced with Ultimate's plugged-in values instead" $Id
        }
        $null = powercfg -changename $guid $name 'win11-tweaks: Ultimate Performance when plugged in, Balanced on battery'
    }
    Set-Reg -Id $Id -Path $script:StateKey -Name 'LaptopPowerPlan' -Type String -Value $guid
    $n = Copy-PowerDcValues -From $balanced -To $guid
    if ($n -lt 1) { throw ("no battery setting could be taken from Balanced - '{0}' was not switched on (it would run Ultimate on battery)" -f $name) }
    $null = powercfg -setactive $guid
    if ($LASTEXITCODE -ne 0) { throw ("powercfg -setactive {0} failed (exit code {1})" -f $guid, $LASTEXITCODE) }
    Write-Log DEBUG ("power plan '{0}' ({1}) active - {2} battery settings taken from Balanced" -f $name, $guid, $n) $Id
}

function Test-KeepLegacyPlayer {
    # Windows Media Player Legacy is the last video player on the PC when a New user said n to VLC AND to keeping
    # Media Player - then it stays. (Gele always gets VLC.)
    return ($script:NotSelected.ContainsKey('VideoLAN.VLC') -and -not $script:KeepApps.ContainsKey('Microsoft.ZuneMusic'))
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
        if (-not $script:Live) { Show-LiveText 'restarting Explorer' }
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
    param([string]$Id, [string[]]$NamePattern)   # one or more Add/Remove Programs DisplayName -like patterns
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
            if (Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $dn = $_.DisplayName; @($NamePattern | Where-Object { $dn -like $_ }).Count }) { return $true }
        }
    }
    return $false
}

function Invoke-Winget {
    # Run winget (output redirected to $OutFile) and return its exit code. Waits for winget ONLY - NOT
    # Start-Process -Wait, which waits for the whole process TREE (it puts the child in a job object): an app
    # the installer launches when it's done (Battle.net + its browser helpers) would then hold the run until
    # someone closed it. winget itself waits for its installer, so this behaves like `winget install` by hand.
    param([string]$ArgumentList, [string]$OutFile)
    $p = Start-Process -FilePath 'winget' -NoNewWindow -PassThru -ArgumentList $ArgumentList -RedirectStandardOutput $OutFile
    $null = $p.Handle   # open the handle NOW - Windows PowerShell returns the process by PID, and without a handle ExitCode can be empty after exit
    # a second at a time, so the live line's clock ticks while winget works
    do { Wait-Process -InputObject $p -Timeout 1 -ErrorAction Ignore; Update-LiveTick } until ($p.HasExited)
    return $p.ExitCode
}

function Install-App {
    # Clean console output: just "Installing <name>" then "Done!" (or "Failed"). winget's own chatter
    # (Found / Downloading / Successfully installed) is redirected to a temp file - shown only in the
    # log file on failure, never on the console. Returns a STATUS: OK / FAILED / DRYRUN.
    param([string]$Id, [string]$Name, [string]$Location, [string]$DetectName, [string]$Source,
          [int]$AbandonWaitSeconds = 300)   # how long to wait for an installer winget abandoned (see below)
    $label = if ($Name) { $Name } elseif ($script:AppNames.ContainsKey($Id)) { $script:AppNames[$Id] } else { $Id }
    $src = if ($Source) { $Source } else { 'winget' }   # 'msstore' for Store-only apps (e.g. Alienware Command Center)
    $wingetArgs = "install $Id --accept-package-agreements --accept-source-agreements --source $src --silent"
    if ($Location) { $wingetArgs += " --location `"$Location`"" }   # e.g. Battle.net requires an install location
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would install $label"; return 'DRYRUN' }
    if (Test-AppInstalled -Id $Id -NamePattern $DetectName) { Write-Log OK "Already installed - $label"; $script:ItemNote = 'already installed'; return 'OK' }
    Write-Log INFO "Installing $label"
    $wo = Join-Path $env:TEMP 'winget_out.log'
    try {
        $code = Invoke-Winget -ArgumentList $wingetArgs -OutFile $wo
        if ($code -eq 0) { Remove-Item $wo -Force -ErrorAction SilentlyContinue; Write-Log OK "Done!"; return 'OK' }
        # A non-zero exit code is not the last word - trust the system over it (like Install-DirectDownload does):
        # an installer can return an odd code and still install. E_ABORT (0x80004004) means winget stopped
        # watching the installer ("Installation abandoned") without killing it - Battle.net's setup does this
        # and finishes on its own (its ~750 MB download can take minutes) - so give the install time to land
        # before calling it a failure. A clock, not a count: each check runs 'winget list' (seconds).
        $hex = '0x{0:X8}' -f $code
        $installed = Test-AppInstalled -Id $Id -NamePattern $DetectName
        if (-not $installed -and $code -eq -2147467260) {
            Write-Log INFO ("winget stopped waiting for the {0} installer - checking whether it finishes on its own (up to {1:N0} min)" -f $label, ($AbandonWaitSeconds / 60))
            Set-LiveWhat 'finishing on its own'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $installed -and $sw.Elapsed.TotalSeconds -lt $AbandonWaitSeconds) {
                foreach ($i in 1..5) { Start-Sleep -Seconds 1; Update-LiveTick }
                $installed = Test-AppInstalled -Id $Id -NamePattern $DetectName
            }
        }
        if ($installed) { Write-Log DEBUG "${label}: winget exit code $hex, but it IS installed - treating as success" }
        else            { Write-Log WARN "Failed - $label (winget exit code $hex)"; $script:ItemFail = "winget exit code $hex" }
        if (Test-Path $wo) { Get-Content $wo -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -Last 8 | ForEach-Object { Write-Log DEBUG "  winget> $($_.Trim())" }; Remove-Item $wo -Force -ErrorAction SilentlyContinue }
        if ($installed) { Write-Log OK "Done!"; return 'OK' }
        return 'FAILED'
    } catch {
        Write-Log WARN "Failed - $label : $($_.Exception.Message)"; $script:ItemFail = $_.Exception.Message; return 'FAILED'
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
        [string[]]$DetectName,        # ARP DisplayName -like pattern(s) -> skip if already installed
        [scriptblock]$Require,        # optional gate; if it returns falsey, skip (e.g. NVIDIA GPU present)
        [string]$RequireMsg = 'requirement not met',
        [hashtable]$Headers,          # extra request headers for the download (AMD serves its files only with an amd.com Referer)
        [string]$Signer,              # the download must carry a valid signature from this publisher, or it is not run
        [string]$Machine,             # 'PC' / 'Laptop' only - checked by the install phase (listed so @splatting works)
        [switch]$WaitMainOnly         # wait for the installer process only, not for an app it leaves running (see below)
    )
    if ($Require) {
        $met = $false; try { $met = [bool](& $Require) } catch { }
        if (-not $met) { Write-Log INFO "${Name}: skipped ($RequireMsg)"; $script:ItemNote = $RequireMsg; return 'SKIPPED' }
    }
    if ($DetectName -and -not $script:DryRun -and (Test-AppInstalled -NamePattern $DetectName)) {
        Write-Log OK "Already installed - $Name"; $script:ItemNote = 'already installed'; return 'OK'
    }
    if ($UrlScript) {
        try { $Url = & $UrlScript } catch { Write-Log WARN "Failed - $Name (could not resolve download URL: $($_.Exception.Message))"; $script:ItemFail = 'could not find the download'; return 'FAILED' }
    }
    if (-not $Url) { Write-Log WARN "Failed - $Name (no download URL found)"; $script:ItemFail = 'no download link found'; return 'FAILED' }
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would install $Name (direct download from $Url)"; return 'DRYRUN' }
    Write-Log INFO "Installing $Name"
    $ext = if ($Url -match '\.msi(\?|#|$)') { 'msi' } else { 'exe' }   # MSI installers (e.g. Chrome) need msiexec
    $tmp = Join-Path $env:TEMP ("{0}_{1}.{2}" -f ($Name -replace '\W','_'), (Get-Date -Format 'yyyyMMddHHmmss'), $ext)
    Write-Log DEBUG "downloading $Name from $Url"
    try {
        $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        $iwr = @{ Uri = $Url; OutFile = $tmp; UseBasicParsing = $true; UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'; ErrorAction = 'Stop' }
        if ($Headers) { $iwr.Headers = $Headers }
        Invoke-WebRequest @iwr
        $ProgressPreference = $pp
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue   # no half file left in TEMP (Adrenalin alone is 1.6 GB)
        Write-Log WARN "Failed - $Name (download failed: $($_.Exception.Message))"; $script:ItemFail = 'download failed'; return 'FAILED'
    }
    # sanity: make sure we got a real installer (MZ='MZ' = exe, or OLE 'D0 CF 11 E0' = msi), not an HTML page
    try {
        $fs = [System.IO.File]::OpenRead($tmp); $sig = New-Object byte[] 4; [void]$fs.Read($sig, 0, 4); $fs.Close()
    } catch { $sig = @(0, 0, 0, 0) }
    $isExe = ($sig[0] -eq 0x4D -and $sig[1] -eq 0x5A)
    $isMsi = ($sig[0] -eq 0xD0 -and $sig[1] -eq 0xCF -and $sig[2] -eq 0x11 -and $sig[3] -eq 0xE0)
    if (-not ($isExe -or $isMsi)) {
        Write-Log WARN "Failed - $Name (downloaded file is not an exe/msi installer; get it manually from $Url)"
        $script:ItemFail = 'the download is not an installer'
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue; return 'FAILED'
    }
    if ($Signer) {   # a scraped link must lead to the vendor's own signed file - anything else is never run
        $sig = Get-AuthenticodeSignature -FilePath $tmp -ErrorAction SilentlyContinue
        $subject = if ($sig -and $sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
        if (-not $sig -or "$($sig.Status)" -ne 'Valid' -or $subject -notmatch [regex]::Escape($Signer)) {
            Write-Log WARN ("Failed - {0} (the download is not signed by {1}: {2} {3}) - not run" -f $Name, $Signer, $(if ($sig) { $sig.Status } else { 'no signature' }), $subject)
            $script:ItemFail = "not signed by $Signer - not run"
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue; return 'FAILED'
        }
    }
    Set-LiveWhat 'installing'
    try {
        $sp = if ($isMsi) { @{ FilePath = 'msiexec.exe'; ArgumentList = "/i `"$tmp`" $SilentArgs" } }
              elseif ($SilentArgs) { @{ FilePath = $tmp; ArgumentList = $SilentArgs } }
              else { @{ FilePath = $tmp } }
        if ($WaitMainOnly) {
            # the installer alone: Start-Process -Wait also waits for every process it started, so an app the setup
            # leaves running (the Radeon app) would hold the run - the same trap as in Invoke-Winget
            $p = Start-Process @sp -PassThru
            $null = $p.Handle   # open it now, or ExitCode can be empty afterwards
            do { Wait-Process -InputObject $p -Timeout 1 -ErrorAction Ignore; Update-LiveTick } until ($p.HasExited)   # the clock ticks
        } else { $p = Start-Process @sp -Wait -PassThru }
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
        Write-Log WARN "Failed - $Name (installer exit code $code)"; $script:ItemFail = "installer exit code $code"; return 'FAILED'
    } catch {
        Write-Log WARN "Failed - $Name : $($_.Exception.Message)"; $script:ItemFail = $_.Exception.Message
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
#  The tweaks - 53 total: 25 standard Win11 tweaks (values verbatim, except where a comment
#  says why) + 28 custom at the end. Toggles apply their ON value only. No restore point
#  (removed per user request). A tweak with Late=$true runs after the installs (Main).
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
              # XOR bitmap: black pixels with alpha 1 (of 255) - invisible, but NOT all-zero: Windows treats a
              # 32bpp image whose alpha is ALL 0 as old-style "0RGB" (no alpha), and Explorer then draws it
              # OPAQUE at bigger icon sizes / high DPI -> a black square on every shortcut.
              $xor = New-Object 'byte[]' ($w * $w * 4); for ($j = 3; $j -lt $xor.Length; $j += 4) { $xor[$j] = 1 }
              $bw.Write($xor)
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
      # EnableActivityFeed stays 1: 0 can break the clipboard history (Win+V) - WinUtil moved to 1 as well (PR #5035).
      # Publish/Upload = 0 already keep the activity history from being saved or sent.
      Set-Reg -Id $id -Path $p -Name 'EnableActivityFeed'    -Type DWord -Value '1'
      Set-Reg -Id $id -Path $p -Name 'PublishUserActivities' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $p -Name 'UploadUserActivities'  -Type DWord -Value '0'
  }}

  # ConsumerFeatures ---------------------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksConsumerFeatures'; Content='ConsumerFeatures - Disable'; Category='Essential'; Apply={
      $id='WPFTweaksConsumerFeatures'; $cdm='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
      # The policy only works on Enterprise / Education. On Pro and Home the "suggested" apps and games that Windows
      # installs by itself are stopped by these three (all 1 on a fresh 25H2).
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Type DWord -Value '1'
      Set-Reg -Id $id -Path $cdm -Name 'SilentInstalledAppsEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $cdm -Name 'PreInstalledAppsEnabled'    -Type DWord -Value '0'
      Set-Reg -Id $id -Path $cdm -Name 'OemPreInstalledAppsEnabled' -Type DWord -Value '0'
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
          # (no "wermgr" line: that is not a service, it did nothing - Windows Error Reporting has its own tweak)
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
      # (Microsoft.GetHelp is NOT removed: the troubleshooters in Settings > System > Troubleshoot open through it.)
      $apps = @(
          'Microsoft.WindowsFeedbackHub','Microsoft.BingNews','Microsoft.BingSearch',
          'Microsoft.BingWeather','Clipchamp.Clipchamp','Microsoft.Todos','Microsoft.PowerAutomateDesktop',
          'Microsoft.MicrosoftSolitaireCollection','Microsoft.WindowsSoundRecorder','Microsoft.MicrosoftStickyNotes',
          'Microsoft.Windows.DevHome','Microsoft.Paint','Microsoft.OutlookForWindows','Microsoft.WindowsAlarms',
          'Microsoft.StartExperiencesApp','Microsoft.ZuneMusic',
          'MicrosoftCorporationII.QuickAssist','MSTeams'
      )
      foreach ($a in $apps) {
          if ($script:KeepApps.ContainsKey($a)) { Write-Log INFO ("Keeping {0} (the New user wants it)" -f $script:KeepApps[$a]) $id; continue }
          Remove-Appx -Id $id -Name $a
      }
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
      # v1.6.0 (Win11Debloat / privacy.sexy): Edge does not preload at sign-in or keep running after it's closed,
      # downloads no local AI model, and shows no news, promo tabs, "make me default" / sign-in nags, Acrobat
      # button, Follow, sidebar (not for Microsoft-account profiles), Copilot page access or experiments.
      Set-Reg -Id $id -Path $e -Name 'StartupBoostEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'BackgroundModeEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'GenAILocalFoundationalModelSettings' -Type DWord -Value '1'
      Set-Reg -Id $id -Path $e -Name 'NewTabPageContentEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'NewTabPageHideDefaultTopSites' -Type DWord -Value '1'
      Set-Reg -Id $id -Path $e -Name 'PromotionalTabsEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'DefaultBrowserSettingEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'SpotlightExperiencesAndRecommendationsEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'ShowAcrobatSubscriptionButton' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'EdgeFollowEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'SignInCtaOnNtpEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'TabServicesEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'HubsSidebarEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'CopilotPageContext' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $e -Name 'ExperimentationAndConfigurationServiceControl' -Type DWord -Value '0'
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
      Add-SettingsPageHidden -Id $id -Page 'aicomponents'   # merged with the Settings Home toggle's "home" - one string
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
  [pscustomobject]@{ Id='WPFToggleHideSettingsHome'; Content='Settings Home Page - Hide'; Category='Toggle'; Apply={
      $id='WPFToggleHideSettingsHome'
      # Home is the page with the Game Pass / Microsoft 365 / OneDrive cards; Settings then opens on System. This used
      # to write "show:home" to HKCU - not a valid prefix, it did nothing - so that value is cleaned up.
      Add-SettingsPageHidden -Id $id -Page 'home'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'SettingsPageVisibility' -Type String -Value '<RemoveEntry>'
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

  # Ultimate Performance power plan - max performance, then ACTIVATE it. PC only (Machine='PC'): a laptop gets
  # CustomLaptopPower instead (Ultimate on the charger only - on battery it would keep the CPU from idling).
  [pscustomobject]@{ Id='CustomUltimatePerf'; Content='Ultimate Performance - power plan'; Category='Custom'; Machine='PC'; Apply={
      Invoke-Step -Id 'CustomUltimatePerf' -Description 'enable + activate Ultimate Performance power plan' -Action { Set-PcPowerPlan -Id 'CustomUltimatePerf' }
  }}

  # Laptop power (superuser, 2026-09-27): Ultimate Performance on the charger, Balanced on battery - ONE plan, so
  # Windows switches by itself when the cable comes out (see Set-LaptopPowerPlan). A PC keeps plain Ultimate.
  [pscustomobject]@{ Id='CustomLaptopPower'; Content='Power plan - Ultimate on the charger, Balanced on battery'; Category='Custom'; Machine='Laptop'; Apply={
      Invoke-Step -Id 'CustomLaptopPower' -Description 'power plan: Ultimate Performance on the charger, Balanced on battery' -Action { Set-LaptopPowerPlan -Id 'CustomLaptopPower' }
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
      # Resume ("continue on this PC" from your phone - Settings > Apps > Resume) off; applies at the next sign-in
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration' -Name 'IsResumeAllowed' -Type DWord -Value '0'
      # Widgets: HKCU 'TaskbarDa' is locked on 25H2 (Set fails "unauthorized"), so kill it via the
      # HKLM policy instead - verified to set cleanly and it removes the Widgets button.
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Type DWord -Value '0'
      $script:NeedExplorerRestart = $true
  }}

  # Search - disable web/Bing results in Start (local apps/files/settings still resolve, and faster).
  # On Win11 24H2/25H2 (build 26200) the reliable switch is the Explorer policy DisableSearchBoxSuggestions=1
  # (removes web suggestions + the Copilot search button); the Windows Search + Bing keys reinforce it so
  # web results don't come back via the connected-search path.
  [pscustomobject]@{ Id='CustomDisableWebSearch'; Content='Search - no web/Bing, Store, highlights or cloud results'; Category='Custom'; Apply={
      $id='CustomDisableWebSearch'
      Set-Reg -Id $id -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'         -Name 'DisableSearchBoxSuggestions' -Type DWord -Value '1'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'   -Name 'DisableWebSearch'            -Type DWord -Value '1'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'   -Name 'ConnectedSearchUseWeb'       -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'     -Name 'BingSearchEnabled'           -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'     -Name 'CortanaConsent'              -Type DWord -Value '0'
      # no Microsoft Store app suggestions in Start search (Settings > Privacy > Search > Show suggested results > Microsoft Store)
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' -Name 'IsStoreSuggestionsEnabled' -Type DWord -Value '0'
      # no "search highlights" (Bing doodles, trending topics) and no results from the Microsoft account's
      # OneDrive / Outlook - the documented machine policies, not the per-user keys the UCPD driver guards
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'   -Name 'EnableDynamicContentInWSB'   -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'   -Name 'AllowCloudSearch'            -Type DWord -Value '0'
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

  # ---- v1.6.0: the picks from the 2026-09-27 bloat research (numbers = the pick page) ----------------------
  # Start: no tips / promoted apps in Recommended (8), no account nags on the profile icon + in Settings (9),
  # no phone panel next to Start (10). Recommended itself stays - the Start Menu Recommendations toggle shows it.
  [pscustomobject]@{ Id='CustomStartCleanup'; Content='Start - no tips, ads, account nags or phone panel'; Category='Custom'; Apply={
      $id='CustomStartCleanup'; $adv='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
      $cdm='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
      Set-Reg -Id $id -Path $adv -Name 'Start_IrisRecommendations' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $cdm -Name 'SystemPaneSuggestionsEnabled' -Type DWord -Value '0'      # the older values for
      Set-Reg -Id $id -Path $cdm -Name 'SubscribedContent-338388Enabled' -Type DWord -Value '0'   # the same suggestions
      Set-Reg -Id $id -Path $adv -Name 'Start_AccountNotifications' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications' -Name 'EnableAccountNotifications' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe' -Name 'IsEnabled' -Type DWord -Value '0'
      $script:NeedExplorerRestart = $true
  }}

  # Start: the ads pinned to a fresh Start (12) - an empty Start layout, once per profile (see Clear-StartPins)
  [pscustomobject]@{ Id='CustomStartPins'; Content='Start - clear the pinned ads (first run only)'; Category='Custom'; Apply={
      $id='CustomStartPins'
      Invoke-Step -Id $id -Description 'empty Start layout (start2.bin) for this user and for new accounts' -Action { Clear-StartPins -Id $id }
      $script:NeedExplorerRestart = $true
  }}

  # Tips, suggestions and ads all over Windows (14-19, 21, 25) - nothing stops working without them
  [pscustomobject]@{ Id='CustomNagsOff'; Content='Windows tips, suggestions and ads - Disable'; Category='Custom'; Apply={
      $id='CustomNagsOff'; $cdm='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' -Name 'ScoobeSystemSettingEnabled' -Type DWord -Value '0'   # "Let's finish setting up your device"
      Set-Reg -Id $id -Path $cdm -Name 'SubscribedContent-310093Enabled' -Type DWord -Value '0'   # welcome experience after updates
      Set-Reg -Id $id -Path $cdm -Name 'SubscribedContent-338389Enabled' -Type DWord -Value '0'   # tips and suggestions
      Set-Reg -Id $id -Path $cdm -Name 'SoftLandingEnabled' -Type DWord -Value '0'
      foreach ($n in '338393', '353694', '353696', '353698') {                                      # suggested content in Settings
          Set-Reg -Id $id -Path $cdm -Name "SubscribedContent-${n}Enabled" -Type DWord -Value '0'
      }
      foreach ($t in 'Windows.SystemToast.Suggested', 'Windows.SystemToast.BackupReminder', 'Windows.ActionCenter.SmartOptOut') {   # ad / backup-nag toasts
          Set-Reg -Id $id -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\$t" -Name 'Enabled' -Type DWord -Value '0'
      }
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowSyncProviderNotifications' -Type DWord -Value '0'   # OneDrive banners in Explorer
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'DoNotShowFeedbackNotifications' -Type DWord -Value '1'   # feedback surveys, every account
      # Microsoft 365 cards in Settings - officially an Enterprise/Education policy, may do nothing on Pro
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableConsumerAccountStateContent' -Type DWord -Value '1'
  }}

  # Lock screen (26-28): no Bing pictures (the desktop Spotlight is off already), no fun facts / tips, no weather-
  # and-stocks widgets (the policy works on Pro in the EEA; the Widgets app is removed below as well)
  [pscustomobject]@{ Id='CustomLockScreen'; Content='Lock screen - no Spotlight, tips or widgets'; Category='Custom'; Apply={
      $id='CustomLockScreen'; $cdm='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
      $ls='HKCU:\Software\Microsoft\Windows\CurrentVersion\Lock Screen'
      Set-Reg -Id $id -Path $cdm -Name 'RotatingLockScreenEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $ls  -Name 'SlideshowEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $cdm -Name 'RotatingLockScreenOverlayEnabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path $cdm -Name 'SubscribedContent-338387Enabled' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'DisableWidgetsOnLockScreen' -Type DWord -Value '1'
      Set-Reg -Id $id -Path $ls  -Name 'LockScreenWidgetsEnabled' -Type DWord -Value '0'
  }}

  # Copilot leftovers (23-24): the "share with Copilot" button on taskbar window previews; Click to Do (Copilot+
  # PCs only - the policy does nothing elsewhere)
  [pscustomobject]@{ Id='CustomCopilotBits'; Content='Copilot - no taskbar sharing, no Click to Do'; Category='Custom'; Apply={
      $id='CustomCopilotBits'
      Set-Reg -Id $id -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarSn' -Type DWord -Value '0'
      Set-Reg -Id $id -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' -Name 'DisableClickToDo' -Type DWord -Value '1'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Name 'DisableClickToDo' -Type DWord -Value '1'
      $script:NeedExplorerRestart = $true
  }}

  # Windows Error Reporting (53) - crash reports to Microsoft off: policy + service + its queue task. Local crash
  # dumps keep working. (Replaces the old "wermgr" line, which did nothing.)
  [pscustomobject]@{ Id='CustomWerOff'; Content='Windows Error Reporting - Disable'; Category='Custom'; Apply={
      $id='CustomWerOff'
      Set-Reg -Id $id -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' -Name 'Disabled' -Type DWord -Value '1'
      Set-Svc -Id $id -Name 'WerSvc' -StartupType 'Disabled' -OriginalType 'Manual'
      Invoke-Step -Id $id -Description 'disable the Windows Error Reporting task QueueReporting' -Action {
          $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Error Reporting\' -TaskName 'QueueReporting' -ErrorAction SilentlyContinue
          if ($t -and "$($t.State)" -ne 'Disabled') { $null = $t | Disable-ScheduledTask -ErrorAction Stop }
      }
  }}

  # Rarely used services (superuser's list, 2026-09-27): Manual - they still start when something needs them -
  # and two Disabled. Most are Manual on a fresh 25H2 already (then nothing changes); a service that is Disabled
  # (Geolocation, by the Location tweak; Routing and Remote Access, by default) is never raised back to Manual.
  [pscustomobject]@{ Id='CustomServicesManual'; Content='Services - rarely used ones to Manual'; Category='Custom'; Apply={
      $id='CustomServicesManual'
      $svcs = [ordered]@{
          'Fax'='Manual'; 'MapsBroker'='Manual'; 'RetailDemo'='Manual'; 'PhoneSvc'='Manual'; 'icssvc'='Manual'   # Downloaded Maps Manager, Phone Service, Mobile Hotspot
          'lfsvc'='Manual'; 'WpcMonSvc'='Manual'; 'AssignedAccessManagerSvc'='Manual'; 'wisvc'='Manual'          # Geolocation, Parental Controls, Windows Insider Service
          'SEMgrSvc'='Manual'; 'WalletService'='Manual'; 'DiagTrack'='Disabled'                                 # Payments and NFC, Connected User Experiences and Telemetry
          'dmwappushservice'='Manual'; 'SCardSvr'='Manual'; 'TermService'='Manual'; 'SessionEnv'='Manual'        # WAP Push Message Routing, Smart Card, Remote Desktop (+ Configuration)
          'UmRdpService'='Manual'; 'RemoteAccess'='Disabled'; 'TapiSrv'='Manual'; 'lmhosts'='Manual'             # RDP UserMode Port Redirector, Routing and Remote Access, Telephony, TCP/IP NetBIOS Helper
      }
      # a loading bar on the rail's live line (superuser's design); -Detailed prints every step instead
      $i = 0
      foreach ($name in $svcs.Keys) {
          $want = $svcs[$name]
          $s = Get-Service -Name $name -ErrorAction SilentlyContinue
          if (-not $s) { Write-Log DEBUG "service $name not present on this system; skipping" $id }
          elseif ("$($s.StartType)" -eq $want) { Write-Log DEBUG "service $name already $want" $id }
          elseif ($want -eq 'Manual' -and "$($s.StartType)" -eq 'Disabled') { Write-Log DEBUG "service $name is Disabled - left off" $id }
          else { Set-Svc -Id $id -Name $name -StartupType $want }
          $i++
          if ($script:Ui) {
              Show-Live ("  {d:$($script:G.Bar)}  {b:$($script:G.Run)} {w:Services to Manual}  " + (Format-Blocks $i $svcs.Count 20) + "  {w:$i/$($svcs.Count)}")
              if (Test-LiveConsole) { Start-Sleep -Milliseconds 60 }   # ~1 s in all, so the bar is seen moving
          }
      }
  }}

  # Sticky / Filter / Toggle Keys (65): 5x Shift (or holding right Shift, or Num Lock for 5 s) in a game pops a
  # dialog that throws you to the desktop. Clear only the "shortcut active" bit (4) - every other accessibility
  # setting stays; the features themselves stay in Settings > Accessibility. Applies at the next sign-in.
  [pscustomobject]@{ Id='CustomStickyKeysOff'; Content='Sticky / Filter / Toggle Keys shortcuts - Disable'; Category='Custom'; Apply={
      $id='CustomStickyKeysOff'
      foreach ($k in @(@('StickyKeys', 510), @('Keyboard Response', 126), @('ToggleKeys', 62))) {   # Windows' defaults
          $p = "HKCU:\Control Panel\Accessibility\$($k[0])"
          $cur = 0; if (-not [int]::TryParse([string](Get-RegValue -Path $p -Name 'Flags'), [ref]$cur)) { $cur = $k[1] }
          $new = $cur -band (-bnot 4)
          if ($new -eq $cur) { Write-Log DEBUG "$($k[0]) shortcut already off" $id; continue }
          Set-Reg -Id $id -Path $p -Name 'Flags' -Type String -Value ([string]$new)
      }
  }}

  # Windows Update restarts (73): never on its own while someone is signed in - it asks instead
  [pscustomobject]@{ Id='CustomNoAutoReboot'; Content='Windows Update - no auto-restart while signed in'; Category='Custom'; Apply={
      Set-Reg -Id 'CustomNoAutoReboot' -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoRebootWithLoggedOnUsers' -Type DWord -Value '1'
  }}

  # Laptop asleep on battery (75): no network in Modern Standby - no heat or drain in the bag; mail and
  # notifications arrive after it wakes. The machine policy (HKLM); plugged in (AC) is left as it is.
  [pscustomobject]@{ Id='CustomStandbyNoNetBattery'; Content='Sleep on battery - no network'; Category='Custom'; Machine='Laptop'; Apply={
      Set-Reg -Id 'CustomStandbyNoNetBattery' -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9' -Name 'DCSettingIndex' -Type DWord -Value '0'
  }}

  # Hibernation (70) - PC only: frees hiberfil.sys (~40% of RAM) and turns Fast Startup off with it. A laptop
  # keeps it: Modern Standby hibernates on low battery instead of dying.
  [pscustomobject]@{ Id='CustomHibernateOff'; Content='Hibernation - Disable (frees hiberfil.sys)'; Category='Custom'; Machine='PC'; Apply={
      Invoke-Step -Id 'CustomHibernateOff' -Description 'powercfg /hibernate off' -Action {
          $out = & powercfg.exe /hibernate off 2>&1
          if ($LASTEXITCODE -ne 0) { throw ("powercfg exit code {0}: {1}" -f $LASTEXITCODE, (@($out) -join ' ').Trim()) }
      }
  }}

  # More pre-installed apps (35-37, 41). Every run: Widgets (the Web Experience Pack + its runtime - the button was
  # only hidden before), Phone Link + Cross Device, and dead Microsoft apps that OEM / older images still carry.
  # The Xbox app, Game Bar and the Xbox sign-in parts stay (Game Pass, Minecraft, AMD X3D scheduling).
  # FIRST run only: promo apps a user may install on purpose later (Spotify, TikTok...) - a re-run leaves them.
  [pscustomobject]@{ Id='CustomRemoveMoreApps'; Content='More pre-installed apps - Remove (Widgets, Phone Link, promos)'; Category='Custom'; Apply={
      $id='CustomRemoveMoreApps'
      $always = @(
          'MicrosoftWindows.Client.WebExperience','Microsoft.WidgetsPlatformRuntime','Microsoft.YourPhone','MicrosoftWindows.CrossDevice',
          'Microsoft.549981C3F5F10','Microsoft.WindowsMaps','microsoft.windowscommunicationsapps','Microsoft.SkypeApp',
          'Microsoft.Microsoft3DViewer','Microsoft.MixedReality.Portal','Microsoft.XboxApp'   # Cortana, Maps, Mail and Calendar, Skype, 3D Viewer, MR Portal, old Xbox Console Companion
      )
      foreach ($a in $always) { Remove-Appx -Id $id -Name $a }
      $promo = @(
          'SpotifyAB.SpotifyMusic','Disney.37853FC22B2CE','BytedancePte.Ltd.TikTok','Facebook.Instagram','FACEBOOK.FACEBOOK','*LinkedInforWindows*',
          'king.com.CandyCrushSaga','king.com.CandyCrushSodaSaga','king.com.BubbleWitch3Saga','AmazonVideo.PrimeVideo',
          'MicrosoftCorporationII.MicrosoftFamily','Microsoft.ZuneVideo'   # Family Safety, Movies & TV
      )
      $done = Get-RegValue -Path $script:StateKey -Name 'PromoAppsRemoved'
      if ($done) { Write-Log INFO ("Promo apps were removed on {0} - leaving Store apps installed since then alone" -f $done) $id }
      else {
          foreach ($a in $promo) { Remove-Appx -Id $id -Name $a }
          Set-Reg -Id $id -Path $script:StateKey -Name 'PromoAppsRemoved' -Type String -Value (Get-Date -Format 'yyyy-MM-dd')
      }
  }}

  # OEM trialware (76), any machine: the Store-app promos makers preinstall - exact names only. Hardware tools stay
  # (MyASUS, Armoury Crate, Lenovo Vantage, HP System Information / Power Manager, Dell SupportAssist / Power
  # Manager, Alienware Command Center). Desktop trialware (McAfee, Norton, ExpressVPN) has no silent uninstall -
  # it's listed WARN in the summary with the vendor's own removal tool, instead of hanging on its dialog.
  [pscustomobject]@{ Id='CustomOemTrialware'; Content='OEM trialware - Remove'; Category='Custom'; Apply={
      $id='CustomOemTrialware'
      $apps = @(
          '5A894077.McAfeeSecurity','C27EB4BA.DropboxOEM','PricelinePartnerNetwork.Booking.com*','Amazon.com.Amazon',
          'AD2F1837.HPJumpStarts','AD2F1837.HPWelcome','AD2F1837.HPRegistration','AD2F1837.HPConnectedMusic','AD2F1837.HPConnectedPhotopoweredbySnapfish',
          'DellInc.PartnerPromo','DellInc.DellCustomerConnect','DellInc.DellMobileConnect','B9ECED6F.ASUSGIFTBOX'
      )
      foreach ($a in $apps) { Remove-Appx -Id $id -Name $a }
      $tools = [ordered]@{
          'McAfee*'     = "McAfee's MCPR tool (mcafee.com/support/s/article/000002766)"
          'Norton*'     = 'the Norton Remove and Reinstall tool, "Remove only" (support.norton.com/sp/en/us/home/current/solutions/v60392881)'
          'ExpressVPN*' = 'Settings > Apps > Installed apps'
      }
      $installed = @(Get-InstalledPrograms)
      foreach ($pat in $tools.Keys) {
          foreach ($n in @($installed | Where-Object { $_ -like $pat } | Sort-Object -Unique)) {
              Write-Log INFO ("found {0} - not removed automatically, use {1}" -f $n, $tools[$pat]) $id
              $script:Results.Add([pscustomobject]@{ Phase='Tweak'; Id="Trialware.$n"; Content=("{0} - remove with {1}" -f $n, $tools[$pat]); Status='WARN'; Detail='' })
          }
      }
  }}

  # Removed apps coming back (62): Windows Update's OOBE scheduler reinstalls the new Outlook and Dev Home - delete
  # those entries. Cross Device's too, but only once Cross Device is really gone.
  [pscustomobject]@{ Id='CustomNoReinstall'; Content='Removed apps - stop Windows reinstalling them'; Category='Custom'; Apply={
      $id='CustomNoReinstall'; $base='HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe'
      $keys = @('OutlookUpdate', 'DevHomeUpdate')
      if (-not $script:DryRun -and -not (Get-AppxPackage 'MicrosoftWindows.CrossDevice' -AllUsers -ErrorAction SilentlyContinue)) { $keys += 'CrossDeviceUpdate' }
      foreach ($k in $keys) { Remove-RegKey -Id $id -Path "$base\$k" }
  }}

  # Old Windows components nobody uses at home (42-47, 50) - they come back from Settings > System > Optional
  # features. Windows Media Player Legacy stays when it's the last video player (see Test-KeepLegacyPlayer).
  # LATE, after .NET 3.5: removing IE mode / Work Folders leaves Windows waiting for a restart, and while it waits
  # it holds every new feature back until the restart too - .NET 3.5 included (superuser's VM run, 2026-09-27).
  [pscustomobject]@{ Id='CustomRemoveComponents'; Content='Old Windows components - Remove (Steps Recorder, IE mode...)'; Category='Custom'; Late=$true; Apply={
      $id='CustomRemoveComponents'
      Remove-WinCapability -Id $id -Name 'App.StepsRecorder' -Label 'Steps Recorder'
      Remove-WinCapability -Id $id -Name 'MathRecognizer' -Label 'Math Recognizer'
      Remove-WinCapability -Id $id -Name 'Browser.InternetExplorer' -Label 'Internet Explorer mode'
      Remove-WinCapability -Id $id -Name 'Microsoft.Windows.PowerShell.ISE' -Label 'PowerShell ISE'
      Remove-WinCapability -Id $id -Name 'Print.Management.Console' -Label 'Print Management'
      Disable-WinFeature   -Id $id -Name 'WorkFolders-Client' -Label 'Work Folders'
      $kept = Test-KeepLegacyPlayer
      if ($kept) {
          Write-Log INFO 'Keeping Windows Media Player Legacy - no VLC and no Media Player, it is the only video player left' $id
      } else {
          Remove-WinCapability -Id $id -Name 'Media.WindowsMediaPlayer' -Label 'Windows Media Player Legacy'
          Disable-WinFeature   -Id $id -Name 'WindowsMediaPlayer' -Label 'Windows Media Player Legacy (feature)'
      }
      $n = $script:UiRemoved.Count
      $note = if ($n) { '{0} removed: {1}' -f $n, ($script:UiRemoved -join ', ') } else { 'nothing left to remove' }
      if ($kept) { $note = 'Media Player Legacy kept (the last video player); ' + $note }
      if (-not $script:DryRun) { Set-UiNote $id $note }
  }}

  # Monitors (superuser, 2026-09-27): a 144 / 165 Hz monitor often comes set to 60 Hz - every screen to its highest
  # refresh rate (see Set-MaxRefreshRate). PC only: a laptop's own panel stays as its maker set it (more Hz = less
  # battery). LATE: without the real GPU driver Windows offers 60 Hz only, and that driver often arrives from Windows
  # Update while the apps install. (Re-run the script after the driver if a screen stayed at 60 Hz.)
  [pscustomobject]@{ Id='CustomMaxRefreshRate'; Content='Monitors - highest refresh rate (e.g. 144 / 165 Hz)'; Category='Custom'; Machine='PC'; Late=$true; Apply={
      Invoke-Step -Id 'CustomMaxRefreshRate' -Description 'every screen to its highest refresh rate at the current resolution' -Action { Set-MaxRefreshRate -Id 'CustomMaxRefreshRate' }
  }}

  # VBScript (51) - deprecated, Microsoft is phasing it out. LATE: removed after the app installs, in case an
  # installer still runs a .vbs step. Command-line activation (slmgr.vbs, Office's ospp.vbs) needs it - activate
  # in Settings, or add it back in Settings > System > Optional features.
  # Kept on an AMD machine: AMD's chipset installer checks the platform with a VBScript - now and for every later update.
  [pscustomobject]@{ Id='CustomRemoveVBScript'; Content='VBScript - Remove (after the installs)'; Category='Custom'; Late=$true; Apply={
      if ((Get-CpuVendor) -eq 'AuthenticAMD') {
          Write-Log INFO 'Keeping VBScript - the AMD chipset installer needs it (also for its later updates)' 'CustomRemoveVBScript'
          Set-UiNote 'CustomRemoveVBScript' 'kept: the AMD chipset installer needs it'; return
      }
      Remove-WinCapability -Id 'CustomRemoveVBScript' -Name 'VBSCRIPT' -Label 'VBScript'
      if (-not $script:DryRun) { Set-UiNote 'CustomRemoveVBScript' $(if ($script:UiRemoved.Contains('VBScript')) { 'removed' } else { 'not installed' }) }
  }}
)

# The tweak phase on the console: ONE rail line per group, in this order, once the phase is over (Write-TweakGroups).
# Text = what the group does: a string, one per machine type, or a scriptblock (the counts). A tweak in no group
# would land in "Other" - the tests make sure none does. The Late tweaks have their own lines (Finishing).
$script:TweakGroups = @(
    [pscustomobject]@{ Name = 'Privacy'; Text = 'telemetry, activity history, location, error reports'
        Ids = @('WPFTweaksActivity', 'WPFTweaksConsumerFeatures', 'WPFTweaksDeliveryOptimization', 'WPFTweaksLocation', 'WPFTweaksTelemetry', 'WPFTweaksWPBT', 'CustomWerOff') }
    [pscustomobject]@{ Name = 'Apps removed'; Text = { if ($script:UiCount.Appx) { '{0} pre-installed apps removed' -f $script:UiCount.Appx } else { 'pre-installed apps, OneDrive, Widgets, Phone Link' } }
        Ids = @('WPFTweaksDeBloat', 'WPFTweaksRemoveOneDrive', 'CustomRemoveMoreApps', 'CustomOemTrialware', 'CustomNoReinstall') }
    [pscustomobject]@{ Name = 'Windows AI'; Text = 'Copilot, Recall and Click to Do off'; Ids = @('WPFTweaksWindowsAI', 'CustomCopilotBits') }
    [pscustomobject]@{ Name = 'Start & search'; Text = 'no tips, nags, ads or web results'
        Ids = @('CustomStartCleanup', 'CustomStartPins', 'CustomNagsOff', 'CustomLockScreen', 'CustomSpotlightOff', 'WPFToggleStartMenuRecommendations', 'WPFToggleHideSettingsHome', 'CustomDisableWebSearch') }
    [pscustomobject]@{ Name = 'Taskbar'; Text = 'This PC pinned, Edge unpinned, no Search or Widgets'; Pins = $true
        Ids = @('CustomTaskbarCleanup', 'WPFTweaksEndTaskOnTaskbar', 'WPFToggleTaskbarAlignment', 'WPFToggleBatteryPercentage') }
    [pscustomobject]@{ Name = 'Explorer'; Text = 'opens This PC, file extensions, classic menu'
        Ids = @('CustomExplorerThisPC', 'WPFTweaksDisableExplorerAutoDiscovery', 'WPFToggleShowExt', 'WPFTweaksRightClickMenu', 'CustomShortcutArrow', 'CustomRemoveEdgeShortcut') }
    [pscustomobject]@{ Name = 'Edge'; Text = 'no startup boost, promos or sidebar'; Ids = @('WPFTweaksEdgeDebloat') }
    [pscustomobject]@{ Name = 'Performance'; Text = @{ PC = 'Ultimate Performance, Memory Integrity off, no hibernation'; Laptop = 'Ultimate on the charger, Balanced on battery' }
        Ids = @('CustomUltimatePerf', 'CustomLaptopPower', 'CustomDisableVBS', 'WPFToggleGameMode', 'CustomHibernateOff', 'WPFToggleStandbyFix', 'CustomStandbyNoNetBattery') }
    [pscustomobject]@{ Name = 'Input & look'; Text = 'dark theme, Num Lock, no mouse acceleration'
        Ids = @('WPFToggleDarkMode', 'WPFToggleLoginBlur', 'WPFToggleNumLock', 'CustomMouseAccel', 'CustomStickyKeysOff') }
    [pscustomobject]@{ Name = 'Services'; Text = { if ($script:UiCount.Svc) { 'rarely used ones to Manual, {0} changed' -f $script:UiCount.Svc } else { 'rarely used ones to Manual' } }
        Ids = @('WPFTweaksServices', 'CustomServicesManual') }
    [pscustomobject]@{ Name = 'System'; Text = 'Cloudflare DNS, no auto-restart, temp files cleaned'; Ids = @('CustomDnsCloudflare', 'CustomNoAutoReboot', 'WPFTweaksDeleteTempFiles') }
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
# Vendor apps: installed automatically (a New user is asked, as for every app) but ONLY on that vendor's
# hardware, desktop or laptop alike (Hardware is a regex against Win32_ComputerSystem "<Manufacturer> <Model>"):
#   Alienware Command Center -> Alienware / Dell G-series (msstore - the Store only offers it there; if the
#                               Store install fails, Install-Alienware falls back to Dell's direct installer).
#                               Older G models have no "Dell " in the model ("Dell Inc. G5 5500"), newer ones
#                               do ("Dell Inc. Dell G15 5511") - hence "Dell ... G<n> <4 digits>".
# (AnyDesk and HP Support Assistant removed per user request.)
$script:VendorApps = @(
    @{ Id='9PMHP03NJ9QP'; Name='Alienware Command Center'; Vendor='Alienware/Dell G'; Hardware='Alienware|^Dell\b.*\bG\d{1,2}\s+\d{4}\b'; Source='msstore' }
)
# Apps for ONE machine type only (the "PC or Laptop?" answer) - skipped on the other, like the Machine='PC'
# tweaks. Keyed by winget ID.
$script:AppMachine = @{
    'NZXT.CAM' = 'PC'   # NZXT coolers / fans / cases - a desktop thing
}
# Runtimes in $script:AppsToInstall: installed for EVERY user - never offered in the "New user" app questions
# (games and apps need them; the Visual C++ redists and .NET 3.5 aren't in the app lists at all).
$script:RuntimeApps = @('Microsoft.DirectX')
# Built-in apps the "Unwanted Pre-Installed Apps" tweak removes that a New user may keep instead - asked after the
# install questions (Enter = keep). Gele isn't asked: they go, as always. Keyed by appx name -> label.
$script:NewUserKeepApps = [ordered]@{ 'Microsoft.Paint' = 'Paint'; 'Microsoft.ZuneMusic' = 'Media Player' }
# What the script remembers between runs on this PC: the date the promo apps were removed (CustomRemoveMoreApps) and the
# GUIDs of the power plans it made (PcPowerPlan / LaptopPowerPlan).
$script:StateKey = 'HKLM:\SOFTWARE\win11-tweaks'
# The empty Start layout Clear-StartPins writes (start2.bin, 972 bytes, sha256 2378a237...81ee65). From Win11Debloat
# (Assets/Start/start2.bin, MIT License, Copyright (c) 2020 Raphire).
$script:StartBlankB64 = '4nrhSwH8TRucAIEL3m5RhU5aX0cAW7FJilySr5CE+V6aoBj7A+HZAaADAABc9u55LN8F4borYyXEGl8Q5+RZ+qERszeqUhhZXDvcjTF6rgdprauITLqPgMVMbSZbRsLN/O5uMjSLEr6nWYIwsMJkZMnZyZrhR3PugUhUKOYDqwySCY6/CPkL/Ooz/5j2R2hwWRGqc7ZsJxDFM1DWofjUiGjDUny+Y8UjowknQVaPYao0PC4bygKEbeZqCqRvSgPalSc53OFqCh2FHydzl09fChaos385QvF40EDEgSO8U9/dntAeNULwuuZBi7BkWSIOmWN1l4e+TZbtSJXwn+EINAJhRHyCSNeku21dsw+cMoLorMKnRmhJMLvE+CCdgNKIaPo/Krizva1+bMsI8bSkV/CxaCTLXodb/NuBYCsIHY1sTvbwSBRNMPvccw43RJCUKZRkBLkCVfW24ANbLfHXofHDMLxxFNUpBPSgzGHnueHknECcf6J4HCFBqzvSH1TjQ3S6J8tq2yaQ+jFNkxGRMushdXNNiTNjDFYMJNvgRL2lu63NPE+Cxy+IKC1NdKLweFdOGZr2mvKAw7t/fxmCTieUgLkegDomZbHL6anjy4SkjSCnfTBUNtxc0X3VJiha4wq/ArRrTtVnzcUcX+CI4BNTicx+X2eXugI+EHKjgaQS7fXHqQGEUMUeHMCXlgWUZ5kE3LFTjVifyVIGqYNDuqt7T9l7DWByiuRariySa7tiN1gA2ALKYlRsjsQL7xpxHnT1hi/9b+UuyC46cYQaDUcKDc4BGReJP2gDIyZfudLpgUPc7YfH9doiMcWimSylbKFtsI3Mfo0HONxet5XjzjDoziduYk2dFoFfz19uaRcOHtASKzaGdtk6RC+Tm4BbU/7PlbvHEKJZ720AxOQkzU9U8RWAHHsPUVfWzYoQc2dN8OQ/JlUAqe8+PI05ST4m3LoUpBKB+oU0H84aet5etGpIi4CthvazGencFObWJWNRzxk9BXIX2YoAdXB8b7JFwlxVdhgzZK0zkkrzSSmX9iJcNoi6Tp+RtnljzLTAv6xh8gwytIW5F2e5sVh7aiqo4sji0aE+ToqyNPV7eE9Idi2ZNeEbnJ9LX127uOl5jB280hs0caXLUrYiR15+Y31wtlD8JVeTDxDDac6v+e3C4VX+28mg9bYQ7NGYXZc7yZANC/nWTn+/hkTZUvR0gi+PUz4o/DSdKzbvVCAlqdjArcKkWW4r/WKUSLskoOKRPxdNLPVBl2S6blje4LvBzulpeHWubXWfCW4ILuOI'
# Per-app install location for packages whose winget manifest REQUIRES one (otherwise
# winget prompts "Specify the install root:" and blocks the run). Add IDs here as needed.
$script:AppLocations = @{
    'Blizzard.BattleNet' = 'C:\Program Files (x86)\Battle.net'
}
# Skip-if-already-installed detection by Add/Remove Programs DisplayName (-like pattern),
# for apps often present OUTSIDE winget so 'winget list' alone won't see them. Add IDs here as needed.
$script:AppDetectNames = @{
    'Blizzard.BattleNet' = '*Battle.net*'   # its setup finishes outside winget (winget reports "Installation abandoned")
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
        Require    = { Test-GpuVendor '10DE' 'NVIDIA' }   # by PCI ID: before its driver is in, the card is a "Microsoft Basic Display Adapter"
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
    # ---- drivers from the maker's own site, not Windows Update (superuser, 2026-09-27). PC only: a laptop keeps its
    # maker's tuned drivers (AMD and Intel both say so); never in a virtual machine (emulated chipset). Every file must be
    # signed by the vendor or it is not run.
    @{  # AMD Chipset Software - Ryzen chipset, power management and (X3D) V-Cache drivers; one package for every Ryzen
        # board, read off the AM5 page (the file name changes: AMD_Chipset_Software_* / amd_software_*). amd.com serves
        # the file only with an amd.com Referer (else an HTML page). Only with AMD chipset devices present - a VM on an
        # AMD host says AMD CPU but has none, and the installer would refuse there. Its setup runs VBScript (kept on AMD).
        Name       = 'AMD Chipset Software'
        UrlScript  = {
            $html = (Invoke-WebRequest 'https://www.amd.com/en/support/downloads/drivers.html/chipsets/am5/x870e.html' -UseBasicParsing -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -ErrorAction Stop).Content
            [regex]::Matches($html, '(?i)https://drivers\.amd\.com/drivers/[^"''<> ]*(chipset_software|amd_software)[^"''<> ]*\.exe') |
                ForEach-Object { $_.Value } | Where-Object { $_ -notmatch '(?i)win7|raid' } | Select-Object -First 1
        }
        Headers    = @{ Referer = 'https://www.amd.com/' }
        SilentArgs = '/S'
        DetectName = 'AMD Chipset Software*'
        Signer     = 'Advanced Micro Devices'
        Machine    = 'PC'
        Require    = { (Get-CpuVendor) -eq 'AuthenticAMD' -and (Test-PciVendor '1022') -and -not (Test-VirtualMachine) }
        RequireMsg = 'no AMD chipset'
    }
    @{  # Intel Chipset Device Software (the INF update utility - mostly device names). Intel's page answers 403 to
        # PowerShell, so it is read with Windows' own curl.exe; if that fails, the last known build.
        Name       = 'Intel Chipset Device Software'
        UrlScript  = {
            $html = ''
            try { $html = (& curl.exe -s -L --max-time 30 'https://www.intel.com/content/www/us/en/download/19347/chipset-inf-utility.html' 2>$null) -join "`n" } catch { }
            $m = [regex]::Match([string]$html, '(?i)https://downloadmirror\.intel\.com/\d+/SetupChipset\.exe')
            if ($m.Success) { $m.Value } else { 'https://downloadmirror.intel.com/925343/SetupChipset.exe' }   # 10.1.20658.8883
        }
        SilentArgs = '/exenoui /qn /norestart'   # since 10.1.20378 an Advanced Installer package (the old -s is not silent);
                                                  # verified on VM 102: silent, exit 0, 28 s
        DetectName = 'SetupChipset*', 'Intel(R) Chipset Device Software*'   # the new name in Add/Remove Programs, and the old
        Signer     = 'Intel Corporation'
        Machine    = 'PC'
        Require    = { (Get-CpuVendor) -eq 'GenuineIntel' -and (Test-PciVendor '8086') -and -not (Test-VirtualMachine) }
        RequireMsg = 'no Intel chipset'
    }
    @{  # AMD Software: Adrenalin Edition - the Radeon driver + its app. The combined "-c" package (RX 5000 and newer,
        # Ryzen 7000+ graphics; ~1.7 GB) linked from the current release notes, which the RX 9070 XT page links to.
        # -INSTALL is silent (NOT -BOOT: that reboots). Older Vega / Polaris chips aren't in it - the installer refuses
        # them (FAILED; amd.com has a separate package for those).
        Name       = 'AMD Software Adrenalin'
        UrlScript  = {
            $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            $gpu = (Invoke-WebRequest 'https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-9000-series/amd-radeon-rx-9070-xt.html' -UseBasicParsing -UserAgent $ua -ErrorAction Stop).Content
            $rn = [regex]::Match($gpu, '(?i)/en/resources/support-articles/release-notes/RN-RAD-WIN-[0-9a-z-]+\.html').Value
            if (-not $rn) { throw 'no release-notes link on the AMD page' }
            $notes = (Invoke-WebRequest ('https://www.amd.com' + $rn) -UseBasicParsing -UserAgent $ua -ErrorAction Stop).Content
            [regex]::Match($notes, '(?i)https://drivers\.amd\.com/drivers/[^"''<> ]*-win11-c\.exe').Value
        }
        Headers    = @{ Referer = 'https://www.amd.com/' }
        SilentArgs = '-INSTALL'
        WaitMainOnly = $true
        DetectName = 'AMD Software*'
        Signer     = 'Advanced Micro Devices'
        Machine    = 'PC'
        # not next to an NVIDIA card: Ryzen 7000 / 9000 CPUs have Radeon graphics of their own, often visible to Windows
        Require    = { (Test-GpuVendor '1002' 'Radeon') -and -not (Test-GpuVendor '10DE' 'NVIDIA') }
        RequireMsg = 'no AMD Radeon card (or an NVIDIA card is the main one)'
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
    # the rail: "  |- WIN11-TEST . Windows 11 Pro 25H2 (26200) . PC . Gele"
    $g = $script:G
    $osName = ("$($os.Caption)" -replace '^\s*Microsoft\s+', '').Trim(); if (-not $osName) { $osName = 'Windows' }
    $ver = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion'
    if ($ver) { $osName += " $ver" }
    if ($os.BuildNumber) { $osName += " {d:($($os.BuildNumber))}" }
    $pcName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'this PC' }
    Write-Ui "  {d:$($g.Bar)}"
    $bits = @($osName, $script:MachineType, $script:UserLabel | ForEach-Object { "{d:$($g.Dot)} $_" })
    Write-Ui ("  {d:$($g.Tee)$($g.Rule)} {w:$pcName} " + ($bits -join ' '))
    if ($script:DryRun) { Write-Ui "  {d:$($g.Bar)}  {y:DRY RUN - nothing will be changed}" }
}

function Invoke-Tweaks {
    # The tweak phase runs every tweak except the Late ones; -Late runs only those (Main, after the installs).
    # The rail: one live line while the phase runs (the groups are printed after it - Write-TweakGroups); the Late
    # ones are "Finishing", one line each.
    param([switch]$Late)
    $list = @($script:Tweaks | Where-Object { [bool]$_.Late -eq [bool]$Late })
    Write-UiPhase $(if ($Late) { 'Finishing' } else { 'Tweaks' })
    $n = 0
    foreach ($t in $list) {
        $n++
        if ($t.Machine -and $t.Machine -ne $script:MachineType) {   # e.g. Ultimate Performance is PC only
            Write-Log INFO ("Skipping {0} ({1} only)" -f $t.Content, $t.Machine) $t.Id
            $rec = [pscustomobject]@{ Phase='Tweak'; Id=$t.Id; Content=$t.Content; Status='SKIPPED'; Detail="$($t.Machine) only"; Seconds=0 }
            $script:Results.Add($rec)
            if ($Late) { Write-Ui (Format-TweakLine $rec) }
            continue
        }
        Write-Log INFO ("Applying {0}" -f $t.Content) $t.Id
        if ($Late) { Start-LiveItem -Name (Get-ShortName $t.Content) }
        else { Show-Live (Format-Row -Glyph "{b:$($script:G.Run)}" -Name $t.Content -NameWidth 60 -Right "$n/$($list.Count)") }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 'OK'; $detail = ''; $warnsBefore = $script:WarnCount
        try { & $t.Apply }
        catch { $status = 'FAILED'; $detail = $_.Exception.Message; Write-Log ERROR "tweak failed: $detail" $t.Id }
        # Set-Reg / Set-Svc / Invoke-Step log a WARN instead of throwing -> a tweak with a failed step is WARN, not OK
        if ($status -eq 'OK' -and $script:WarnCount -gt $warnsBefore) {
            $status = 'WARN'; $detail = '{0} step(s) failed - see the log' -f ($script:WarnCount - $warnsBefore)
        }
        if ($status -eq 'OK' -and $script:DryRun) { $status = 'DRYRUN' }
        switch ($status) {
            'FAILED' { Write-Log ERROR 'Failed' $t.Id }
            'WARN'   { Write-Log WARN "Done, but $detail" $t.Id }
            default  { Write-Log OK 'Done!' $t.Id }
        }
        $rec = [pscustomobject]@{ Phase='Tweak'; Id=$t.Id; Content=$t.Content; Status=$status; Detail=$detail; Seconds=$sw.Elapsed.TotalSeconds }
        $script:Results.Add($rec)
        if ($Late) { $null = Stop-LiveItem; Write-Ui (Format-TweakLine $rec) }
    }
}

function Format-TweakLine {
    # A Finishing line: short name, what came of it (the tweak's note - or what went wrong), time
    param($Rec)
    $note = if ($Rec.Status -in 'FAILED', 'WARN', 'SKIPPED') { $Rec.Detail } elseif ($script:UiNotes.ContainsKey($Rec.Id)) { $script:UiNotes[$Rec.Id] } else { '' }
    $color = switch ($Rec.Status) { 'FAILED' { 'r' } 'WARN' { 'y' } default { 'd' } }
    $right = switch ($Rec.Status) { 'DRYRUN' { 'dry run' } 'SKIPPED' { '' } default { Format-Span $Rec.Seconds } }
    return Format-Row -Glyph (Get-Glyph $Rec.Status) -Name (Get-ShortName $Rec.Content) -Text $note -TextColor $color -Right $right -NameWidth 24
}

function Write-TweakGroups {
    # The tweak phase on the rail, once it's over: one line per group - done (what it did, its time), or the first thing
    # that went wrong ("! Edge  Microsoft Edge - Debloat: 1 step(s) failed - see the log") - then the tweaks this
    # machine type skips, on one line ("Laptop only  Power plan, Sleep on battery").
    if (-not $script:Ui) { return }
    $late = @{}; foreach ($t in $script:Tweaks) { if ($t.Late) { $late[$t.Id] = $true } }
    $done = @($script:Results | Where-Object { $_.Phase -eq 'Tweak' -and -not $late.ContainsKey($_.Id) })
    $pins = @($script:Results | Where-Object { $_.Phase -eq 'Taskbar' -and $_.Id -ne 'Chrome.Pin' })
    $known = @{}; foreach ($grp in $script:TweakGroups) { foreach ($id in $grp.Ids) { $known[$id] = $true } }
    $groups = [System.Collections.Generic.List[object]]::new(); foreach ($grp in $script:TweakGroups) { $groups.Add($grp) }
    $other = @($done | Where-Object { -not $known.ContainsKey($_.Id) } | ForEach-Object { $_.Id })
    if ($other) { $groups.Add([pscustomobject]@{ Name = 'Other'; Text = ''; Ids = $other }) }
    foreach ($grp in $groups) {
        $rs = @($done | Where-Object { $grp.Ids -contains $_.Id -and $_.Status -ne 'SKIPPED' })
        if ($grp.PSObject.Properties['Pins'] -and $grp.Pins) { $rs += $pins }
        if (-not $rs) { continue }
        $secs = 0.0; foreach ($r in $rs) { if ($r.PSObject.Properties['Seconds']) { $secs += [double]$r.Seconds } }
        $bad = @($rs | Where-Object { $_.Status -in 'FAILED', 'WARN' })
        $text = if ($grp.Text -is [scriptblock]) { [string](& $grp.Text) } elseif ($grp.Text -is [hashtable]) { [string]$grp.Text[$script:MachineType] } else { [string]$grp.Text }
        if ($bad) {
            $st = if (@($bad | Where-Object { $_.Status -eq 'FAILED' })) { 'FAILED' } else { 'WARN' }
            $why = if ($bad[0].Detail) { $bad[0].Detail } else { 'see the log' }
            $more = if ($bad.Count -gt 1) { " (+$($bad.Count - 1) more)" } else { '' }
            Write-Ui (Format-Row -Glyph (Get-Glyph $st) -Name $grp.Name -Text ('{0}: {1}{2}' -f $bad[0].Content, $why, $more) `
                -TextColor $(if ($st -eq 'FAILED') { 'r' } else { 'y' }) -Right (Format-Span $secs))
        } elseif ($script:DryRun) {
            Write-Ui (Format-Row -Glyph (Get-Glyph 'DRYRUN') -Name $grp.Name -Text $text -Right 'dry run')
        } else {
            Write-Ui (Format-Row -Glyph (Get-Glyph 'OK') -Name $grp.Name -Text $text -Right (Format-Span $secs))
        }
    }
    foreach ($only in @($done | Where-Object { $_.Status -eq 'SKIPPED' } | Group-Object Detail)) {
        Write-Ui (Format-Row -Glyph (Get-Glyph 'SKIPPED') -Name $only.Name -Text ((@($only.Group | ForEach-Object { Get-ShortName $_.Content })) -join ', '))
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
    $placed = 0
    foreach ($dir in $rarDirs) {
        try { [System.IO.File]::WriteAllBytes((Join-Path $dir 'rarreg.key'), $rkBytes); $placed++; Write-Log DEBUG "placed rarreg.key in $dir" }
        catch { Write-Log DEBUG "place failed in ${dir}: $($_.Exception.Message)" }
    }
    $st = if ($placed) { 'OK' } else { 'FAILED' }   # OK only if the key actually landed somewhere
    $why = if ($placed) { '' } else { 'could not write rarreg.key' }
    if ($placed) { Write-Log OK "Done!" } else { Write-Log WARN "Failed - WinRAR license ($why)" }
    $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='WinRAR.License'; Content='WinRAR license (rarreg.key)'; Status=$st; Detail=$why })
}

function Install-Alienware {
    # Alienware Command Center - only called on Alienware / Dell G hardware (the vendor gate in
    # Invoke-InstallPhase checks Win32_ComputerSystem, so other boxes show SKIPPED, not a scary "Failed").
    # Returns a STATUS ('OK'/'FAILED'/'DRYRUN'). Tries the Microsoft Store first (official/latest); if the
    # Store gating misfires, falls back to Dell's DIRECT Full Installer EXE (bypasses the Store). Only a
    # genuine install failure -> FAILED.
    # NOTE: the Dell URL is version-pinned (update when Dell ships newer) + /s is a best-effort silent
    # switch; can't be tested on the non-Alienware VM.
    $id = '9PMHP03NJ9QP'; $label = 'Alienware Command Center'
    $dellUrl = 'https://dl.dell.com/FOLDER12874937M/2/Alienware-Command-Center-6-x-Full-Installer-for_5T498_WIN64_6.7.37.0_A00_01.EXE'
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would install $label"; return 'DRYRUN' }
    if (Test-AppInstalled -NamePattern 'Alienware Command Center*') { Write-Log OK "Already installed - $label"; $script:ItemNote = 'already installed'; return 'OK' }
    Write-Log INFO "Installing $label"
    # 1) Microsoft Store (official, always-latest)
    $wo = Join-Path $env:TEMP 'winget_awcc.log'
    try {
        $code = Invoke-Winget -OutFile $wo -ArgumentList "install $id --accept-package-agreements --accept-source-agreements --source msstore --silent"
        if ($code -eq 0) { Remove-Item $wo -Force -EA SilentlyContinue; Write-Log OK "Done!"; return 'OK' }
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
        Write-Log WARN "Failed - $label (install manually from dell.com/support)"; $script:ItemFail = 'install it from dell.com/support'; return 'FAILED'
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Log WARN "Failed - $label (Dell fallback download failed: $($_.Exception.Message))"; $script:ItemFail = 'the Dell download failed'; return 'FAILED'
    }
}

function Get-CpuVendor {
    # 'AuthenticAMD' / 'GenuineIntel' (the CPU's own vendor string - not translated)
    return [string](Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Manufacturer
}

function Test-VirtualMachine {
    # A virtual machine (Proxmox/QEMU, VMware, Hyper-V, VirtualBox, Parallels, Xen): its chipset is emulated - no chipset
    # driver from AMD or Intel belongs there.
    return ((Get-Hardware) -match '(?i)QEMU|VMware|Virtual Machine|VirtualBox|innotek|Parallels|Xen|KVM|Standard PC \(')
}

function Test-DualCcdX3D {
    # A Ryzen X3D with two CCDs (7900X3D, 7950X3D, 9900X3D, 9950X3D, 7945HX3D...): AMD's V-Cache driver keeps games on the
    # CCD with the cache by PARKING the other one - through the Balanced plan's core parking, which Ultimate switches off.
    $c = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    return ("$($c.Name)" -match 'X3D' -and [int]$c.NumberOfCores -gt 8)
}

function Test-PciVendor {
    # Is there a PCI device from this vendor ('1022' AMD, '8086' Intel, '10DE' NVIDIA, '1002' AMD graphics)? A VM on an
    # AMD host reports an AMD CPU but has only emulated devices - AMD's chipset installer would refuse there.
    param([string]$Vendor)
    return [bool](Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -like "PCI\VEN_$Vendor*" } | Select-Object -First 1)
}

function Test-GpuVendor {
    # A graphics card from this PCI vendor ('10DE' NVIDIA, '1002' AMD) - by its PCI ID, so it's found before its driver is
    # installed (until then Windows calls it "Microsoft Basic Display Adapter"); the name is a second chance.
    param([string]$Vendor, [string]$NamePattern)
    return [bool](Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { "$($_.PNPDeviceID)" -match "VEN_$Vendor" -or ($NamePattern -and "$($_.Name)" -match $NamePattern) })
}

function Get-Hardware {
    # "<Manufacturer> <Model>" - what $script:VendorApps' Hardware regexes are matched against
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    return ("{0} {1}" -f $cs.Manufacturer, $cs.Model).Trim()
}

function Skip-NotSelected {
    # A "New user" said n to this app (or wasn't offered it): log it, record it as SKIPPED and return $true
    # (the caller moves on).
    param([string]$Key, [string]$Content, [string]$Label)
    if (-not ($script:NotSelected -and $script:NotSelected.ContainsKey($Key))) { return $false }
    $why = $script:NotSelected[$Key]; if ($why -isnot [string]) { $why = 'not selected' }
    Write-Log INFO ("Skipping {0} ({1})" -f $Label, $why)
    $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$Key; Content=$Content; Status='SKIPPED'; Detail=$why })
    return $true
}

function Format-ItemLine {
    # An app's rail line: glyph, name, note (what came with it / why not), time
    param([string]$Name, [string]$Status, [string]$Note = '', [double]$Seconds = -1, [switch]$Warn)
    $color = if ($Status -eq 'FAILED') { 'r' } elseif ($Warn) { 'y' } else { 'd' }
    $right = if ($Status -eq 'DRYRUN') { 'dry run' }
             elseif ($Status -in 'OK', 'FAILED' -and $Seconds -ge 0 -and $Note -ne 'already installed') { Format-Span $Seconds } else { '' }
    return Format-Row -Glyph (Get-Glyph $Status -Warn:$Warn) -Name $Name -Text $Note -TextColor $color -Right $right -NameWidth 32
}

function Write-AppLine {
    # An app's line once it - and its desktop icon / license / taskbar pin, the records from index $From on - is done
    param([string]$Name, [string]$Status, [int]$From)
    $secs = Stop-LiveItem
    $extras = [System.Collections.Generic.List[string]]::new(); $warn = $false
    for ($i = $From; $i -lt $script:Results.Count; $i++) {
        $x = $script:Results[$i]
        $what = switch -Wildcard ($x.Id) { 'Desktop.*' { 'desktop icon' } 'WinRAR.License' { 'license' } 'Chrome.Pin' { 'pinned to the taskbar' } default { $null } }
        if (-not $what) { continue }
        if ($x.Status -eq 'OK' -and $x.Detail -ne 'exists') { $extras.Add("+ $what") }
        elseif ($x.Status -eq 'FAILED') { $extras.Add("$what failed"); $warn = $true }
    }
    $note = switch ($Status) {
        'FAILED'  { if ($script:ItemFail) { "$($script:ItemFail), see the log" } else { 'see the log' } }
        'SKIPPED' { $script:ItemNote }
        default   { (@($script:ItemNote) + @($extras) | Where-Object { $_ }) -join ', ' }
    }
    Write-Ui (Format-ItemLine -Name $Name -Status $Status -Note $note -Seconds $secs -Warn:$warn)
}

function Invoke-InstallPhase {
    Write-Log INFO "=========== INSTALLING APPS ==========="
    Write-UiPhase 'Apps'
    $notSelected = [System.Collections.Generic.List[string]]::new()   # a New user's "n" apps - one rail line at the end

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if ($script:VCRedists.Count) {   # Visual C++ Redistributables first (apps/games need them) - ONE rail line for all
            $vcName = "Visual C++ 2005$($script:G.Dash)2022"; $vc = @(); $k = 0
            Start-LiveItem -Name $vcName -What "0/$($script:VCRedists.Count)"
            foreach ($id in $script:VCRedists) {
                $script:ItemNote = ''; $script:ItemFail = ''
                $st = Install-App -Id $id
                $script:Results.Add([pscustomobject]@{ Phase='VCRedist'; Id=$id; Content=$id; Status=$st; Detail=$script:ItemFail })
                $vc += [pscustomobject]@{ Status = $st; Note = $script:ItemNote }
                $k++; Set-LiveWhat "$k/$($script:VCRedists.Count)"
            }
            $secs = Stop-LiveItem
            $failed = @($vc | Where-Object { $_.Status -eq 'FAILED' }).Count
            if ($script:DryRun) { Write-Ui (Format-ItemLine -Name $vcName -Status 'DRYRUN' -Note "$($vc.Count) runtimes") }
            elseif ($failed) { Write-Ui (Format-ItemLine -Name $vcName -Status 'FAILED' -Note "$failed of $($vc.Count) failed, see the log" -Seconds $secs) }
            else {
                $new = @($vc | Where-Object { $_.Note -ne 'already installed' }).Count
                Write-Ui (Format-ItemLine -Name $vcName -Status 'OK' -Note $(if ($new) { "$($vc.Count) runtimes" } else { 'already installed' }) -Seconds $secs)
            }
        }
        foreach ($id in $script:AppsToInstall) {
            $label = if ($script:AppNames.ContainsKey($id)) { $script:AppNames[$id] } else { $id }
            $only = $script:AppMachine[$id]
            if ($only -and $only -ne $script:MachineType) {   # e.g. NZXT CAM is PC only
                Write-Log INFO ("Skipping {0} ({1} only)" -f $label, $only)
                $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$id; Content=$id; Status='SKIPPED'; Detail="$only only" })
                Write-Ui (Format-ItemLine -Name $label -Status 'SKIPPED' -Note "$only only")
                continue
            }
            if (Skip-NotSelected -Key $id -Content $id -Label $label) { $notSelected.Add($label); continue }   # no icon / WinRAR license either
            $from = $script:Results.Count + 1
            $script:ItemNote = ''; $script:ItemFail = ''
            Start-LiveItem -Name $label -What 'installing'
            $st = Install-App -Id $id -Location $script:AppLocations[$id] -DetectName $script:AppDetectNames[$id]
            $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$id; Content=$id; Status=$st; Detail=$script:ItemFail })
            if ($st -ne 'FAILED' -and $script:DesktopShortcutApps.ContainsKey($id)) { $sc = $script:DesktopShortcutApps[$id]; New-DesktopShortcut -Name $sc.Name -Exe $sc.Exe }
            if ($id -eq 'RARLab.WinRAR') { Set-WinRarLicense }   # license right after WinRAR installs (clean pairing)
            Write-AppLine -Name $label -Status $st -From $from
        }
    } else {
        Write-Log ERROR "winget not found; skipping VC++/app installs. Install 'App Installer' (Microsoft.DesktopAppInstaller) and re-run."
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='winget'; Content='winget missing'; Status='SKIPPED'; Detail='no winget' })
        Write-Ui (Format-ItemLine -Name 'winget' -Status 'FAILED' -Note 'not found: install App Installer from the Store, then run again')
    }

    # Non-winget apps (direct vendor download): Bitwarden, Parsec, NVIDIA App (GPU only)
    foreach ($d in $script:DirectApps) {
        if ($d.Machine -and $d.Machine -ne $script:MachineType) {   # e.g. the chipset / Radeon drivers are PC only
            Write-Log INFO ("Skipping {0} ({1} only)" -f $d.Name, $d.Machine)
            $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$d.Name; Content=$d.Name; Status='SKIPPED'; Detail="$($d.Machine) only" })
            Write-Ui (Format-ItemLine -Name $d.Name -Status 'SKIPPED' -Note "$($d.Machine) only")
            continue
        }
        if (Skip-NotSelected -Key $d.Name -Content $d.Name -Label $d.Name) {   # no icon / Chrome pin either
            if ($script:NotSelected[$d.Name] -eq 'not offered') { Write-Ui (Format-ItemLine -Name $d.Name -Status 'SKIPPED' -Note $(if ($d.RequireMsg) { $d.RequireMsg } else { 'not offered' })) }
            else { $notSelected.Add($d.Name) }
            continue
        }
        $from = $script:Results.Count + 1
        $script:ItemNote = ''; $script:ItemFail = ''
        Start-LiveItem -Name $d.Name -What 'downloading'
        $st = Install-DirectDownload @d
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$d.Name; Content=$d.Name; Status=$st; Detail=$(if ($st -eq 'FAILED' -and $script:ItemFail) { $script:ItemFail } else { 'direct' }) })
        if ($st -eq 'OK' -and $script:DesktopShortcutApps.ContainsKey($d.Name)) { $sc = $script:DesktopShortcutApps[$d.Name]; New-DesktopShortcut -Name $sc.Name -Exe $sc.Exe }
        if ($d.Name -eq 'Google Chrome') { $script:ChromePinned = Add-ChromeTaskbarPin }   # pin Chrome to the taskbar RIGHT AFTER it installs
        Write-AppLine -Name $d.Name -Status $st -From $from
    }

    # (WinRAR license is created right after WinRAR installs, in the loop above - see Set-WinRarLicense.)

    # Vendor apps LAST - installed (a New user was asked) ONLY on that vendor's hardware, desktop or laptop alike:
    #   Alienware Command Center -> Alienware / Dell G-series.
    $hw = Get-Hardware
    foreach ($a in $script:VendorApps) {
        if ($hw -notmatch $a.Hardware) {   # NOT a failure - just not this vendor's machine
            Write-Log DEBUG "$($a.Name): skipped (not $($a.Vendor) hardware: '$hw')"
            $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$a.Id; Content=$a.Name; Status='SKIPPED'; Detail="not $($a.Vendor) hardware" })
            Write-Ui (Format-ItemLine -Name $a.Name -Status 'SKIPPED' -Note "not $($a.Vendor) hardware")
            continue
        }
        if (Skip-NotSelected -Key $a.Id -Content $a.Name -Label $a.Name) { $notSelected.Add($a.Name); continue }
        $from = $script:Results.Count + 1
        $script:ItemNote = ''; $script:ItemFail = ''
        Start-LiveItem -Name $a.Name -What 'installing'
        if ($a.Id -eq '9PMHP03NJ9QP') { $st = Install-Alienware }   # Store first, then Dell's direct installer
        else { $st = Install-App -Id $a.Id -Name $a.Name -Source $a.Source }
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$a.Id; Content=$a.Name; Status=$st; Detail=$(if ($st -eq 'FAILED' -and $script:ItemFail) { $script:ItemFail } else { $hw }) })
        Write-AppLine -Name $a.Name -Status $st -From $from
    }
    if ($notSelected.Count) { Write-Ui (Format-Row -Glyph (Get-Glyph 'SKIPPED') -Name 'Not selected' -Text ($notSelected -join ', ') -NameWidth 32) }

    # (.NET 3.5 was started in the BACKGROUND before this phase (Start-DotNet35) so it downloads in
    #  parallel; it's finished after this phase (Enable-DotNetFeatures). Desktop icons are per-app above.)
}

function Start-DotNet35 {
    # Kick off the SLOW NetFx3 (.NET 3.5) Windows-Update download in the BACKGROUND, BEFORE the install
    # phase, so it overlaps the ~15 min of app installs instead of adding ~11 min serially at the end.
    # Finished by Enable-DotNetFeatures. (Runs after the tweaks' Recall DISM, so no DISM-vs-DISM clash.)
    if ($script:DryRun) { Write-Log DEBUG "[DRYRUN] would start .NET 3.5 (NetFx3) download in the background"; return }
    $state = "$((Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction SilentlyContinue).State)"
    if ($state -eq 'Enabled') { Write-Log DEBUG ".NET 3.5 already enabled - nothing to start"; return }
    if ($state -eq 'EnablePending') { Write-Log DEBUG ".NET 3.5 already installed - Windows finishes it at the next restart"; return }
    $dlog = Join-Path $env:TEMP 'dism_NetFx3.log'
    Write-Log DEBUG "starting .NET 3.5 (NetFx3) download in the background (shown as Installing/Done at the end)"
    try {
        $script:DotNet35Proc = Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" -WindowStyle Hidden -PassThru `
            -ArgumentList '/Online','/Enable-Feature','/FeatureName:NetFx3','/All','/NoRestart','/Quiet',"/LogPath:$dlog"
        $script:DotNet35Clock = [System.Diagnostics.Stopwatch]::StartNew()   # the rail shows how long it has been downloading
    } catch { Write-Log DEBUG ".NET 3.5 background start failed: $($_.Exception.Message)" }
}

function Format-PhaseLine {
    # "  |- Name   text                                   right" - a phase that is one line (.NET 3.5)
    param([string]$Name, [string]$Text, [string]$Right = '')
    $line = "  {d:$($script:G.Tee)$($script:G.Rule)} {w:$Name}   $Text"
    if ($Right) { $line += (' ' * [math]::Max(2, (Get-UiWidth) - (Get-Visible $line).Length - $Right.Length)) + "{d:$Right}" }
    return $line
}

function Enable-DotNetFeatures {
    # Print a clean "Installing .NET 3.5 / Done!" pair HERE at the end. The download already ran in the
    # background during the install phase (Start-DotNet35), so on a normal machine this is instant; if it's
    # still going we WAIT until it fully finishes (live heartbeat, no cap). Then .NET 4 (quiet).
    # The rail: ONE line - ".NET 3.5   ready", "ready at the next restart", or why not.
    $g = $script:G
    Write-Ui "  {d:$($g.Bar)}"
    if ($script:DryRun) {
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NetFx3'; Content='.NET 3.5'; Status='DRYRUN'; Detail='' })
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NetFx4-AdvSrvs'; Content='.NET 4'; Status='DRYRUN'; Detail='' })
        Write-Ui (Format-PhaseLine '.NET 3.5' '{d:dry run}')
        return
    }
    Write-Log INFO "Installing .NET 3.5"
    # Recorded up-front as BACKGROUND and updated below: if the run is stopped (Ctrl+C) during the wait, the
    # summary - written from Main's finally - still shows that .NET 3.5 is finishing in the background.
    $rec3 = [pscustomobject]@{ Phase='Install'; Id='NetFx3'; Content='.NET 3.5'; Status='BACKGROUND'; Detail='' }
    $script:Results.Add($rec3)
    $st3 = 'OK'; $waited = 0.0
    if ($script:DotNet35Proc -and -not $script:DotNet35Proc.HasExited) {
        # Still downloading from Windows Update (started before the install phase). WAIT until it fully
        # finishes - no cap. The background DISM holds the servicing lock, so we do NOT query the feature
        # state while it runs (that can block ON the lock); we just wait for the DISM PROCESS to exit,
        # showing a live line so the console never looks frozen. On a normal machine this is seconds; on a
        # WU-throttled box it can be ~30 min. Ctrl+C stops the run here: the summary is still written and DISM
        # keeps going on its own (/NoRestart - no surprise reboot). Console only - it never spams the log file.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $clock = if ($script:DotNet35Clock) { $script:DotNet35Clock } else { $sw }
        while (-not $script:DotNet35Proc.HasExited) {
            if ($script:Ui) {
                $s = [int][math]::Floor($clock.Elapsed.TotalSeconds)
                Show-Live (Format-PhaseLine '.NET 3.5' ("{d:downloading from Windows Update $($g.Dot)} {b:" + ('{0:00}:{1:00}' -f [math]::Floor($s / 60), ($s % 60)) + '}'))
                Start-Sleep -Seconds 1
            } else {
                Write-Host ("`r  .NET 3.5 still installing (downloading from Windows Update)... {0:mm\:ss}   " -f $sw.Elapsed) -NoNewline -ForegroundColor DarkYellow
                Start-Sleep -Seconds 3
            }
        }
        if (-not $script:Ui) { Write-Host ("`r{0}`r" -f (' ' * 78)) -NoNewline }   # wipe the heartbeat line before the final status
        $waited = $sw.Elapsed.TotalSeconds
        Start-Sleep -Milliseconds 500
    }
    # .NET 3.5 was already enabled, the DISM just finished, or it was never started - safe to query state now.
    # EnablePending = installed, Windows finishes it at the next restart: while Windows already waits for a restart
    # (a removed component, a Windows update) it holds a new feature back like that - DISM says "Reboot required".
    $code = ''
    if ($script:DotNet35Proc) {
        $c = $script:DotNet35Proc.ExitCode
        $code = if ($null -eq $c -or "$c" -eq '') { 'unknown' } elseif ([int64]$c -lt 0) { '0x{0:X8}' -f [int]$c } else { "$c" }
        Write-Log DEBUG "DISM exit code $code"
    }
    $wait = if ($waited -ge 1) { 'waited ' + (Format-Span $waited) } else { '' }
    $state = "$((Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction SilentlyContinue).State)"
    if ($state -eq 'Enabled') {
        Write-Log OK "Done!"
        if ($script:DotNet35Proc) { Write-Ui (Format-PhaseLine '.NET 3.5' "ready {d:$($g.Dot) downloaded next to the apps}" $wait) }
        else { Write-Ui (Format-PhaseLine '.NET 3.5' 'already on') }
    } elseif ($state -eq 'EnablePending') {
        Write-Log OK "Done! (finishes at the next restart)"; $rec3.Detail = 'finishes at the next restart'
        Write-Ui (Format-PhaseLine '.NET 3.5' 'ready at the next restart' $wait)
    } elseif (-not $script:DotNet35Proc) {
        Write-Log WARN "Failed - .NET 3.5 (was not started)"; $st3 = 'FAILED'; $rec3.Detail = 'was not started'
        Write-Ui (Format-PhaseLine '.NET 3.5' "{r:$($g.Fail) not started, see the log}")
    } else {
        Write-Log WARN "Failed - .NET 3.5 (DISM exit code $code, state '$state' - see %TEMP%\dism_NetFx3.log)"; $st3 = 'FAILED'
        $rec3.Detail = "DISM exit code $code"
        Write-Ui (Format-PhaseLine '.NET 3.5' "{r:$($g.Fail) not installed (DISM $code), see the log}" $wait)
    }
    $rec3.Status = $st3
    # .NET 4 is already enabled on Win11 -> record quietly (no console clutter); enable only if somehow off.
    if ((Get-WindowsOptionalFeature -Online -FeatureName 'NetFx4-AdvSrvs' -ErrorAction SilentlyContinue).State -eq 'Enabled') {
        Write-Log DEBUG ".NET 4 already enabled"
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NetFx4-AdvSrvs'; Content='.NET 4'; Status='OK'; Detail='already enabled' })
    } else {
        Start-LiveItem -Name '.NET 4' -What 'installing'
        $st4 = Enable-Feature -Name 'NetFx4-AdvSrvs' -Display '.NET 4'
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NetFx4-AdvSrvs'; Content='.NET 4'; Status=$st4; Detail='' })
        Write-AppLine -Name '.NET 4' -Status $st4 -From $script:Results.Count
    }
}

function Write-Summary {
    Write-Log INFO "=========== SUMMARY ==========="
    foreach ($g in ($script:Results | Group-Object Status | Sort-Object Name)) {
        Write-Log INFO ("{0,-8}: {1}" -f $g.Name, $g.Count)
    }
    foreach ($r in ($script:Results | Where-Object { $_.Status -eq 'WARN' })) {
        Write-Log WARN ("WARN    [{0}] {1}{2}" -f $r.Phase, $r.Content, $(if ($r.Detail) { " - $($r.Detail)" }))
    }
    foreach ($r in ($script:Results | Where-Object { $_.Status -eq 'FAILED' })) {
        Write-Log ERROR ("FAILED  [{0}] {1}{2}" -f $r.Phase, $r.Content, $(if ($r.Detail) { " - $($r.Detail)" }))
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
    $restart = -not $script:DryRun -and (Test-RestartPending)
    if ($script:DotNet35Proc -and -not $script:DotNet35Proc.HasExited) {
        Write-Log WARN ".NET 3.5 is still installing in the background - reboot / sign out only after it finishes."
    } elseif ($restart) {
        Write-Log WARN "Restart the PC to finish - Windows completes some of the changes only at a restart (a sign-out is not enough)."
    } else {
        Write-Log WARN "A reboot / sign-out is recommended to fully apply the changes."
    }
    # The rail: "Done in 19m 29s   93 OK . 7 skipped . 0 failed", every problem again, what to do next, the log
    if (-not $script:Ui) { return }
    $gl = $script:G
    $count = @{}; foreach ($r in $script:Results) { $count[[string]$r.Status] = 1 + [int]$count[[string]$r.Status] }
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($script:DryRun) { $parts.Add(('{0} would apply' -f [int]$count['DRYRUN'])) } else { $parts.Add(('{{g:{0} OK}}' -f [int]$count['OK'])) }
    if ($count['SKIPPED']) { $parts.Add(('{0} skipped' -f $count['SKIPPED'])) }
    if ($count['WARN']) { $parts.Add(('{{y:{0} warning{1}}}' -f $count['WARN'], $(if ($count['WARN'] -gt 1) { 's' }))) }
    if ($count['BACKGROUND']) { $parts.Add(('{{y:{0} still installing}}' -f $count['BACKGROUND'])) }
    $parts.Add($(if ($count['FAILED']) { '{{r:{0} failed}}' -f $count['FAILED'] } else { '0 failed' }))
    $time = if ($script:RunClock) { Format-Span $script:RunClock.Elapsed.TotalSeconds } else { '-' }
    $head = if (-not $script:RunFinished) { "Stopped after $time" } elseif ($script:DryRun) { "Dry run done in $time" } else { "Done in $time" }
    Write-Ui "  {d:$($gl.Bar)}"
    Write-Ui ("  {d:$($gl.End)$($gl.Rule)} {w:$head}   " + ($parts -join " {d:$($gl.Dot)} "))
    foreach ($r in @($script:Results | Where-Object { $_.Status -in 'WARN', 'FAILED' })) {
        $label = if ($script:AppNames.ContainsKey([string]$r.Id)) { $script:AppNames[[string]$r.Id] } else { [string]$r.Content }
        $why = if ($r.Detail -and $r.Detail -ne 'direct') { ": $($r.Detail)" } else { '' }
        Write-Ui ('     ' + (Get-Glyph $r.Status) + ' ' + (Get-Cut ("$label$why" -replace '[{}]', '') ((Get-UiWidth) - 7)))
    }
    Write-Ui ''
    $next = if (-not $script:RunFinished) { 'Run the script again to finish the rest.' }
            elseif ($script:DotNet35Proc -and -not $script:DotNet35Proc.HasExited) { '.NET 3.5 is still installing in the background - restart only after it finishes.' }
            elseif ($script:DryRun) { 'Dry run - nothing was changed.' }
            elseif ($restart) { 'Restart the PC to finish. Windows completes some changes only at a restart.' }
            else { 'Restart or sign out to apply everything.' }
    Write-Ui "     {y:$($gl.Run)} $next"
    Write-Ui "       {d:Log}  $($script:LogFile)"
}

function Test-TaskbarPinned {
    # A taskbar-pinned item has a matching <Name>.lnk in the User Pinned\TaskBar Quick Launch folder (Win11).
    param([string]$Name)
    Test-Path (Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\$Name.lnk")
}

function Get-PinHelper {
    # Return a ready-to-use Pin-Taskbar helper path (in TEMP), fetching it ONCE and only when needed. Prefer
    # OUR copy next to the script (download/.bat -> no download); else fetch OUR copy from OUR repo (one-liner).
    # Cached in $script:PinHelper (deleted by Add-ChromeTaskbarPin, else at the end of Main). Returns $null on failure.
    if ($script:PinHelper -and (Test-Path $script:PinHelper)) { return $script:PinHelper }
    $helper = Join-Path $env:TEMP 'Pin-Taskbar.ps1'
    try {
        $bundled = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Pin-Taskbar.ps1' } else { $null }
        if ($bundled -and (Test-Path $bundled)) {
            Copy-Item -LiteralPath $bundled -Destination $helper -Force
            Write-Log DEBUG "using the bundled Pin-Taskbar helper (next to the script - no download)"
        } else {
            Write-Log INFO "fetching the Pin-Taskbar helper (our copy, from our repo; temporary)"
            if (-not $script:Live) { Show-LiveText 'fetching the Pin-Taskbar helper' }
            $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri 'https://gitlab.msuhost.com/superuser/win11-tweaks/-/raw/main/Pin-Taskbar.ps1' -OutFile $helper -UseBasicParsing -ErrorAction Stop
            $ProgressPreference = $pp
        }
        Unblock-File $helper -ErrorAction SilentlyContinue
        $script:PinHelper = $helper
        return $helper
    } catch { Write-Log WARN "could not get the Pin-Taskbar helper: $($_.Exception.Message)"; return $null }
}

function Invoke-PinHelper {
    # Run the Pin-Taskbar helper in its OWN Windows PowerShell process with -ExecutionPolicy Bypass (like the
    # .bat and the self-elevation relaunch do). Run in-process, the helper - a .ps1 FILE - was blocked by
    # Windows' default 'Restricted' policy whenever the `irm | iex` one-liner was started from an already
    # elevated window (iex itself isn't subject to the policy, script files are). A separate process also
    # keeps the helper's own `exit` / error handling out of this session.
    # The helper's exit code: 0 = OK, 2 = nothing found to pin/unpin, 3 = failed, 1 = it crashed - anything
    # but 0 becomes an exception that the caller records as FAILED.
    param([string]$Helper, [string]$Target, [switch]$Unpin)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { throw "Windows PowerShell not found at $ps" }
    $helperArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Helper, $Target, '-Silent')
    if ($Unpin) { $helperArgs += '-Unpin' }
    $out = & $ps @helperArgs 2>&1   # it runs -Silent, so anything it prints is an error message - kept for the log
    if ($LASTEXITCODE -ne 0) {
        # FIRST lines: a crash prints the message first, then "At ...", code context, CategoryInfo, ErrorId
        @($out) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -First 10 | ForEach-Object { Write-Log DEBUG "  pin-helper> $_" }
        $why = switch ($LASTEXITCODE) { 2 { 'nothing found to pin/unpin' } 3 { 'pin/unpin failed' } default { 'helper error' } }
        throw ("Pin-Taskbar exit code {0} ({1})" -f $LASTEXITCODE, $why)
    }
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
            Show-LiveText 'pinning This PC to the taskbar'
            Invoke-PinHelper -Helper $helper -Target $lnk
            Write-Log OK "pinned This PC to the taskbar"; $r.Status = 'OK'
        } catch { Write-Log WARN "This PC pin failed: $($_.Exception.Message)"; $r.Detail = $_.Exception.Message }
        $script:Results.Add($r)
    } else { Write-Log DEBUG "This PC already pinned - skipping" }
    # (b) UNPIN Edge + Store - only if currently pinned
    foreach ($app in 'Microsoft Edge', 'Microsoft Store') {
        if (-not (Test-TaskbarPinned $app)) { Write-Log DEBUG "$app already unpinned - skipping"; continue }
        $u = [pscustomobject]@{ Phase='Taskbar'; Id="Unpin.$app"; Content="Unpinned $app from taskbar"; Status='FAILED'; Detail='' }
        try { Show-LiveText "unpinning $app"; Invoke-PinHelper -Helper $helper -Target $app -Unpin; Write-Log OK "unpinned $app from the taskbar"; $u.Status = 'OK' }
        catch { Write-Log WARN "unpin $app failed: $($_.Exception.Message)"; $u.Detail = $_.Exception.Message }
        $script:Results.Add($u)
    }
    # (helper kept for Add-ChromeTaskbarPin, which deletes it - Main's finally does if Chrome was left out)
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
        if (-not $helper) {
            $script:Results.Add([pscustomobject]@{ Phase='Taskbar'; Id='Chrome.Pin'; Content='Google Chrome pinned to taskbar'; Status='FAILED'; Detail='no Pin-Taskbar helper' })
            return $false
        }
        $lnk = Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Filter 'Google Chrome.lnk' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        $target = if ($lnk) { $lnk.FullName } else { $chromeExe }
        Invoke-PinHelper -Helper $helper -Target $target
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

function Set-QuickEdit {
    # The classic console window PAUSES the whole run when someone clicks into it (QuickEdit "Select" mode)
    # until Enter/Esc - an unattended run then just sits there. Turn QuickEdit off for the run; -Restore puts
    # the original mode back (so text can be selected again afterwards). No-op without a real console
    # (SSH, ISE, redirected input) and in Windows Terminal, where a click never pauses anything.
    param([switch]$Restore)
    try {
        if (-not ([System.Management.Automation.PSTypeName]'Native.ConsoleMode').Type) {
            Add-Type -Namespace Native -Name ConsoleMode -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        }
        $h = [Native.ConsoleMode]::GetStdHandle(-10)   # STD_INPUT_HANDLE
        if ($Restore) {
            if ($null -ne $script:ConsoleModeSaved) { [void][Native.ConsoleMode]::SetConsoleMode($h, $script:ConsoleModeSaved); $script:ConsoleModeSaved = $null }
            return
        }
        $mode = [uint32]0
        if (-not [Native.ConsoleMode]::GetConsoleMode($h, [ref]$mode)) { return }   # no console
        if (-not ($mode -band 0x40)) { return }                                     # QuickEdit is already off
        $script:ConsoleModeSaved = $mode
        # clear ENABLE_QUICK_EDIT_MODE (0x40); ENABLE_EXTENDED_FLAGS (0x80) must be set for that to stick
        if ([Native.ConsoleMode]::SetConsoleMode($h, [uint32](($mode -bor 0x80) - 0x40))) {
            Write-Log DEBUG "QuickEdit off for the run (a click in the window would pause it)"
        }
    } catch { Write-Log DEBUG "console mode left as is: $($_.Exception.Message)" }
}

function Test-Interactive {
    # Is someone at a console to answer questions? (Not over SSH / a service - there it's $false.) Wrapped so the
    # tests can say yes on a non-interactive runner.
    return [Environment]::UserInteractive
}

function Show-Intro {
    # The rail head and the questions - each on ONE line, the answer typed right after it
    $g = $script:G; $bar = "  {d:$($g.Bar)}"
    Write-Ui -Always ''
    Write-Ui -Always "  {d:$($g.Top)}  {b:MSUHost}  {w:win11-tweaks} {d:$($script:Version)}"
    Write-Ui -Always "$bar  {d:Windows 11 setup: tweaks, apps and runtimes. About 20 minutes.}"
    Write-Ui -Always $bar
    if (Test-Interactive) {
        $ans = Read-Answer "  {b:?}  {w:Continue?} {d:(Y/n)} {b:$($g.Next)} "
        if ($ans -match '^\s*(n|no)\s*$') {
            Write-Ui -Always "  {d:$($g.End)$($g.Rule)} {r:Cancelled - nothing was changed.}"
            $script:Cancelled = $true   # NOT `exit` - that would close the host window when run via `irm|iex`
            return
        }
    }
    # Machine type - a laptop skips the PC-only items (Ultimate Performance, hibernation off, NZXT CAM). (Alienware Command
    # Center goes by the actual hardware instead - see Invoke-InstallPhase.)
    if ($Machine -eq 'PC' -or $Machine -eq 'Laptop') {
        $script:MachineType = if ($Machine -eq 'Laptop') { 'Laptop' } else { 'PC' }
    } elseif (Test-Interactive) {
        $mt = Read-Choice -Title 'PC or laptop?' -Options 'PC', 'Laptop'
        $script:MachineType = if ($mt -eq '2') { 'Laptop' } else { 'PC' }   # $null (no keyboard) -> PC
    } else {
        $script:MachineType = 'PC'   # non-interactive default (override with -Machine PC|Laptop)
    }
    # Who is it? Gele gets the full app set, as always. A New user answers (Y/n) for every app BEFORE anything
    # is downloaded; after the last answer the run goes on unattended. Non-interactive = Gele.
    $newUser = $false
    if (Test-Interactive) {
        $newUser = (Read-Choice -Title 'Who is it?' -Options 'Gele', 'New user') -eq '2'   # $null (no keyboard) -> Gele
        if ($newUser) { $sel = Read-AppSelection }
    }
    Write-Log INFO ("Machine type: {0}" -f $script:MachineType)
    if ($newUser) {
        $kept = @($script:NewUserKeepApps.Keys | Where-Object { $script:KeepApps.ContainsKey($_) } | ForEach-Object { $script:NewUserKeepApps[$_] })
        $keeps = if ($kept) { ', keeps ' + ($kept -join ' + ') } else { '' }
        Write-Log INFO ("User: New user - {0} of {1} apps selected{2}" -f $sel.Picked, $sel.Asked, $keeps)
        $script:UserLabel = 'New user, {0} of {1} apps' -f $sel.Picked, $sel.Asked
    }
    else { Write-Log INFO "User: Gele - installing all apps"; $script:UserLabel = 'Gele' }
}

function Read-Choice {
    # A one-line menu in colour - "  ?  Title  1 PC  2 Laptop  >" - asked again until a valid number is typed. Returns
    # that number as a string, or $null when there's no keyboard (input redirected: Read-Host gives nothing back), so the
    # caller falls back to its default instead of asking forever.
    param([string]$Title, [string[]]$Options)
    $opts = @(for ($i = 0; $i -lt $Options.Count; $i++) { "{b:$($i + 1)} $($Options[$i])" }) -join '  '
    do { $ans = Read-Answer "  {b:?}  {w:$Title}  $opts  {b:$($script:G.Next)} " }
    until ($null -eq $ans -or ($ans -match '^\s*\d+\s*$' -and [int]$ans -ge 1 -and [int]$ans -le $Options.Count))
    if ($null -eq $ans) { return $null }
    return $ans.Trim()
}

function Get-AppChoices {
    # The apps a New user is asked about, in install order: the winget apps (minus the runtimes and the apps
    # for the other machine type), the direct downloads whose gate passes (NVIDIA App only with an NVIDIA card)
    # and the vendor apps for this hardware (Alienware Command Center on Alienware / Dell G).
    # Key = what the install phase looks up in $script:NotSelected.
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $script:AppsToInstall) {
        if ($script:RuntimeApps -contains $id) { continue }
        $only = $script:AppMachine[$id]
        if ($only -and $only -ne $script:MachineType) { continue }
        $list.Add([pscustomobject]@{ Key = $id; Name = $(if ($script:AppNames.ContainsKey($id)) { $script:AppNames[$id] } else { $id }) })
    }
    foreach ($d in $script:DirectApps) {
        if ($d.Machine -and $d.Machine -ne $script:MachineType) { continue }
        if ($d.Require) { $met = $false; try { $met = [bool](& $d.Require) } catch { }; if (-not $met) { continue } }
        $list.Add([pscustomobject]@{ Key = $d.Name; Name = $d.Name })
    }
    $hw = Get-Hardware
    foreach ($a in $script:VendorApps) {
        if ($hw -match $a.Hardware) { $list.Add([pscustomobject]@{ Key = $a.Id; Name = $a.Name }) }
    }
    return $list
}

function Format-Question {
    # "  |  Revo Uninstaller ................ Y/n > " - one (Y/n) question on the rail
    param([string]$Name)
    $n = Get-Cut $Name 30
    return "  {d:$($script:G.Bar)}  $n {d:" + ('.' * (32 - $n.Length)) + "} {d:Y/n} {b:$($script:G.Next)} "
}

function Read-AppSelection {
    # New user: one (Y/n) per app - Enter (or anything but n/no) = yes. The no's go into $script:NotSelected.
    # Returns how many apps were asked about (.Asked) and picked (.Picked).
    $choices = @(Get-AppChoices)
    $g = $script:G; $bar = "  {d:$($g.Bar)}"
    Write-Ui -Always $bar
    Write-Ui -Always ("  {b:?}  {w:Apps for this $(if ($script:MachineType -eq 'Laptop') { 'laptop' } else { 'PC' })}  {d:Enter = yes, n = no}")
    Write-Ui -Always "$bar  {d:Visual C++, DirectX and .NET 3.5 always go in - games and apps need them.}"
    $no = 0
    foreach ($c in $choices) {
        $ans = Read-Answer (Format-Question $c.Name)
        if ($ans -match '^\s*(n|no)\s*$') { $script:NotSelected[$c.Key] = 'not selected'; $no++ }
    }
    # Built-in apps the script would remove (Gele never gets asked - they go): Enter keeps them, n removes them.
    Write-Ui -Always $bar
    Write-Ui -Always "  {b:?}  {w:Keep these Windows apps?}  {d:Enter = yes, n = no}"
    foreach ($k in $script:NewUserKeepApps.Keys) {
        $ans = Read-Answer (Format-Question $script:NewUserKeepApps[$k])
        if ($ans -notmatch '^\s*(n|no)\s*$') { $script:KeepApps[$k] = $script:NewUserKeepApps[$k] }
    }
    # A direct app that wasn't offered (its gate failed - e.g. no NVIDIA driver yet) must not install later
    # either: the install phase checks the gate again, and Windows Update can add the NVIDIA driver mid-run.
    $offered = @($choices | ForEach-Object { $_.Key })
    foreach ($d in $script:DirectApps) { if ($offered -notcontains $d.Name) { $script:NotSelected[$d.Name] = 'not offered' } }
    return [pscustomobject]@{ Asked = $choices.Count; Picked = $choices.Count - $no }
}

# --------------------------------------------------------------------------------------
#  Main
# --------------------------------------------------------------------------------------
try {
    Set-QuickEdit                       # a click into the window must not pause the run (restored in finally)
    Show-Intro
    if ($script:Cancelled) { return }   # user answered "n" to Continue
    $script:RunStarted = $true          # from here on the summary is written - also if the run is stopped (see finally)
    $script:RunClock = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Banner
    if ($script:DryRun) { Write-Log WARN "DRY RUN - no changes will be made." }
    Invoke-Tweaks
    Invoke-TaskbarPins        # This PC pin + unpin Edge/Store BEFORE installs...
    if ($script:NeedExplorerRestart -and -not $script:DryRun) { Update-Explorer -Action restart }   # ...then restart explorer so the taskbar/desktop is already clean (no Widgets/Search) during the installs
    Write-TweakGroups         # the tweak phase on the rail: one line per group, now that it's over
    Start-DotNet35            # fire the slow .NET 3.5 WU download NOW so it overlaps the install phase (parallel)
    Invoke-InstallPhase       # apps + per-app desktop icons (Chrome is pinned right after it installs, inside this)
    if ($script:ChromePinned -and -not $script:DryRun) { Update-Explorer -Action restart }   # refresh the taskbar to show the Chrome pin
    Enable-DotNetFeatures     # finish .NET 3.5 (usually already done) + .NET 4
    Invoke-Tweaks -Late       # last: what must wait for the installers (VBScript) and for .NET 3.5 (old components) - DISM is free again here
    $script:RunFinished = $true
}
finally {
    # The summary is written HERE so it also lands when the run is stopped early with Ctrl+C - e.g. during
    # the .NET 3.5 wait, which then simply keeps installing in the background (/NoRestart).
    if ($script:RunStarted) {
        if (-not $script:RunFinished) {
            if ($script:LiveOpen) { Clear-Live } elseif ($script:Detailed) { Write-Host '' }   # Ctrl+C can land mid-line (the live step / the .NET 3.5 heartbeat)
            # e.g. Ctrl+C in the .NET 3.5 wait: the last steps (old components, refresh rate, VBScript) come after it
            Write-Log WARN "Stopped early - this summary only covers what ran. Run the script again to finish the rest."
        }
        Write-Summary
        Write-Log INFO ("=========== WIN11-TWEAKS {0} ===========" -f $(if ($script:RunFinished) { 'DONE' } else { 'STOPPED' }))
    }
    # The Pin-Taskbar helper is normally deleted by the Chrome pin - but not when Chrome was left out (New user)
    # or the run was stopped before it. Don't leave it in TEMP.
    if ($script:PinHelper) { Remove-Item $script:PinHelper -Force -ErrorAction SilentlyContinue; $script:PinHelper = $null }
    Set-QuickEdit -Restore
    try { Stop-Transcript | Out-Null } catch { }
}
if ($script:RunFinished -and $Reboot -and -not $script:DryRun) {
    Write-Log WARN "Rebooting in 15s (-Reboot given). Press Ctrl+C to cancel."
    Write-Ui "     {y:$($script:G.Run)} Restarting in 15 s (-Reboot) - Ctrl+C cancels."
    Start-Sleep -Seconds 15
    Restart-Computer -Force
}
