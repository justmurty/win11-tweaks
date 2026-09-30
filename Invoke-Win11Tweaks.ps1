#Requires -Version 5.1
<#
.SYNOPSIS
    Applies a fixed set of Windows 11 tweaks, then installs a defined application set via
    winget (plus Visual C++ redists, .NET features and, on a PC, the chipset / Radeon drivers from
    the maker's own site). A window asks the setup questions and shows the run (the tweaks as groups,
    one line per app, the step running now); -Console shows the same in the console (a rail).
    Everything goes to a log file for later.

.DESCRIPTION
    The 55 tweaks (25 standard + 30 custom) and the install list are a fixed, curated set
    (see docs/2026-07-11-win11-tweaks-design.md). Only the ON toggles / checked items are
    applied; nothing else is touched.
    The script makes NO restore point and does NOT reboot unless -Reboot is given.

.PARAMETER DryRun
    Log what WOULD happen and make NO system changes. Recommended for the first run.

.PARAMETER Reboot
    Reboot 15 seconds after finishing (cancellable with Ctrl+C). Off by default. An unattended
    run: the console shows it (no window).

.PARAMETER Machine
    'PC' or 'Laptop' - overrides what the script detects (the case and the firmware say it; a battery
    only when they say nothing - a desktop's UPS is a battery to Windows too). A laptop skips the PC-only
    items: the Ultimate Performance power plan (a laptop keeps Windows' own plan), hibernation off, the
    highest monitor refresh rate and the chipset / Radeon drivers; a PC skips the laptop-only items (no
    network while asleep on battery). The apps for hardware (NZXT CAM, Alienware Command Center, Armoury
    Crate...) go by the hardware itself, not by this.

.PARAMETER LogDir
    Directory for the log file. Default: %TEMP%\win11-tweaks (the Temporary Files tweak leaves it
    alone; fallback: the Desktop if it cannot be written).

.PARAMETER Console
    The rail in this console instead of the window. The console is also what you get without a
    desktop (SSH, a service), with -Detailed or -Reboot, or when the window cannot open.

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
    [string]$LogDir,
    [switch]$Console,   # the rail in this console instead of the window
    [switch]$Relaunched # internal: set by the elevation relaunch below - that console is the run's own, it goes with the window
)

$ErrorActionPreference = 'Continue'
# The window's own progress / warning settings - put back at the end: `irm | iex` from an already elevated window runs
# this in that window's own scope, and it should not stay silenced after the run.
$script:SavedPrefs = @{ Progress = $ProgressPreference; Warning = $WarningPreference }
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
$script:MachineType          = ''      # 'PC' or 'Laptop' - detected (or -Machine) before the run; a laptop skips the PC-only tweaks/apps
$script:WarnCount            = 0       # WARN lines logged so far - a tweak that logs one is reported WARN, not OK
$script:RunStarted           = $false  # past the intro -> Main's finally writes the summary (also after Ctrl+C)
$script:RunFinished          = $false  # got to the end without being stopped
$script:DotNet35Proc         = $null   # background DISM process for .NET 3.5 (started early, finished at the end)
$script:PinHelper            = $null   # Pin-Taskbar helper path (kept after Invoke-TaskbarPins for the Chrome pin)
$script:ChromePinned         = $false  # set by Add-ChromeTaskbarPin (right after Chrome installs) - Main refreshes the taskbar if true
$script:NotSelected          = @{}     # apps taken off the window's list (winget ID / direct-app Name / vendor Id) - the install phase skips them
$script:PnpIds               = $null   # every device's ID (PCI\VEN_..., USB\VID_...), read once per run - Get-PnpIds
$script:DetectedWhy          = ''      # why the machine is a PC or a laptop, in words - for the log (Get-DetectedMachineType)
$script:SettingsPagesHidden  = @()     # Settings pages hidden so far in this run (SettingsPageVisibility is one merged string)
$script:ConsoleModeSaved     = $null   # console input mode before Set-QuickEdit turned QuickEdit off (put back at the end)
$script:Results              = [System.Collections.Generic.List[object]]::new()
# The console view ("Rail", superuser's pick from the design page, 2026-09-28) - see Write-Ui
$script:Version              = '1.8.0' # on the rail head and in the window's title bar - bumped with every release
$script:Ui                   = -not $script:Detailed   # the console shows the rail; -Detailed puts the full log there instead
# Cmdlets' own warnings would print straight onto the rail's live line (superuser's run, 2026-09-28: DISM's "WARNING:
# Restart is suppressed because NoRestart is specified.") - off in the rail view; -Detailed shows the other cmdlet warnings
# (that DISM one is switched off where it's called - the restart advice comes from the script itself).
if ($script:Ui) { $WarningPreference = 'SilentlyContinue' }
$script:UiLines              = [System.Collections.Generic.List[string]]::new()   # every rail line printed (the tests read it)
$script:UiLive               = ''      # what the live line shows right now
$script:LiveOpen             = $false  # the live line is on the console without its newline yet
$script:Live                 = $null   # the step running now: Name / What / Clock - Update-LiveTick redraws it with the time
$script:UiNotes              = @{}     # tweak Id -> what came of it, for its Finishing line ('7 removed')
$script:UiWarn               = @{}     # tweak Id -> why it is a WARN, in words (instead of "1 step(s) failed")
$script:UiCount              = @{ Appx = 0; Svc = 0 }   # apps removed / services changed - for the tweak group lines
$script:UiRemoved            = [System.Collections.Generic.List[string]]::new()   # old components removed (their labels)
$script:ItemNote             = ''      # what an installer says about the app it just handled ('already installed', a skip reason)
$script:ItemFail             = ''      # ... or why it failed ('winget exit code 0x8A150011')
$script:RunClock             = $null   # started when the run starts ("Done in 19m 29s")
$script:DotNet35Clock        = $null   # started with the .NET 3.5 download
$script:AppsLabel            = ''      # "all 27 apps" / "24 of 27 apps" - on the machine line (Set-AppsLabel)
$script:LastPrompt           = ''      # the question on the console right now, as plain text
# The window (variant A of the design page, superuser's pick 2026-09-28) - see Start-Gui. The run only FEEDS it.
$script:ConsoleOnly          = [bool]$Console   # -Console: the rail in the console, no window
$script:Gui                  = $null   # while the window is open: @{ Shared; PowerShell; Runspace; Handle }
$script:SetupPayload         = $null   # what the window's setup screen shows - gathered while the window starts (Start-Gui)
$script:UiRow                = $null   # the row the last rail formatter built, for the window (Write-Ui sends it with its line)
$script:UiPhase              = ''      # the phase the rail is in (Tweaks / Apps / .NET 3.5 / Finishing) - rows go under it
$script:SummaryLine          = ''      # "Done in 19m 51s . 95 OK . 7 skipped . 0 failed" - for the console when the window closes
$script:Relaunched           = [bool]$Relaunched   # this console was opened by the elevation relaunch, only for the run
$script:ConsoleHidden        = $false  # the console is hidden behind the window (Set-ConsoleWindow)
$script:MainEnded            = $false  # Main got to its end - or was stopped / cancelled; not an error
$script:ExitWhenDone         = $false  # the run's own console closes at the very end (Exit-Console)
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
            # it isn't). Outside TEMP, which the "Temporary Files" tweak empties (all but its win11-tweaks log folder).
            $dir = Join-Path $env:LOCALAPPDATA 'win11-tweaks'
            $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
            $scriptFile = Join-Path $dir 'Invoke-Win11Tweaks.ps1'
            Invoke-WebRequest -Uri $SelfUrl -OutFile $scriptFile -UseBasicParsing -ErrorAction Stop
            $fwd = @()   # (the log goes to %TEMP%\win11-tweaks - Get-DefaultLogDir)
        }
        $argList = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"{0}"' -f $scriptFile)) + $fwd + @('-Relaunched')   # -NoLogo: the rail starts at the top
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

function Clear-TempFolder {
    # Everything in a temp folder goes - but our logs: %TEMP%\win11-tweaks (or win11-tweaks_* right in TEMP with
    # -LogDir %TEMP%), this run's log among them
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'win11-tweaks' -and $_.Name -notlike 'win11-tweaks_*' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-DefaultLogDir {
    # The logs: %TEMP%\win11-tweaks - out of the way, not on the Desktop (superuser, 2026-09-29). The Temporary Files
    # tweak leaves that folder alone, so this run's log and the earlier ones stay. No TEMP: the Desktop.
    if ($env:TEMP) { return (Join-Path $env:TEMP 'win11-tweaks') }
    return [Environment]::GetFolderPath('Desktop')
}
if (-not $LogDir) { $LogDir = Get-DefaultLogDir }
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
    if ($w -le 0) { return 94 }
    return [math]::Max(1, [math]::Min($w - 1, 94))
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
    if (Test-ConsoleQuiet) { return }   # the window shows the run
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
    $script:LiveOpen = $false
    if (Test-ConsoleQuiet) { return }
    Write-Host ("`r" + (' ' * (Get-UiWidth)) + "`r") -NoNewline
}

function Write-Ui {
    # One line of the rail. -Always: with -Detailed too (the rail head and the questions). A row a formatter built with a
    # status (Format-Row -Status) goes to the window as well - under the phase the rail is in.
    param([string]$Markup = '', [switch]$Always)
    if (-not ($script:Ui -or $Always)) { return }
    Clear-Live
    Resume-Console
    $script:UiLines.Add($Markup)
    $r = $script:UiRow; $script:UiRow = $null
    if ($r -and $r.Markup -eq $Markup) {
        Send-GuiEvent 'row' @{ Phase = $script:UiPhase; Status = $r.Status; Warn = $r.Warn; Name = $r.Name; Text = $r.Text; Right = $r.Right }
    }
    Write-Markup $Markup
}

function Resume-Console {
    # The window went before the end (it failed): the console takes over - shown again, with the rail so far, once.
    # From Write-Ui AND Show-Live: a long step (the .NET 3.5 wait) only redraws its live line.
    if (-not ($script:Gui -and $script:Gui.Shared.Closed -and -not $script:Gui.Replayed)) { return }
    $script:Gui.Replayed = $true
    Set-ConsoleWindow -Show
    foreach ($l in $script:UiLines) { Write-Markup $l }
}

function Show-Live {
    # The live line: the step running now, redrawn in place on ONE console line (padded, so a shorter text leaves
    # nothing of the longer one behind)
    param([string]$Markup)
    if (-not $script:Ui) { return }
    Resume-Console
    $script:UiLive = $Markup
    if ((Test-ConsoleQuiet) -or -not (Test-LiveConsole)) { return }
    $w = Get-UiWidth
    $plain = Get-Visible $Markup
    if ($plain.Length -gt $w) { $Markup = Get-Cut $plain $w; $plain = $Markup }   # a live line that wraps leaves a copy per redraw
    $pad = $w - $plain.Length
    Write-Host "`r" -NoNewline
    Write-Markup $Markup -NoNewline
    if ($pad -gt 0) { Write-Host (' ' * $pad) -NoNewline }
    $script:LiveOpen = $true
}

function Format-Row {
    # "  |  <glyph> <Name padded>  <text, cut to fit>  <right, flush with the right edge>" - $Glyph is markup.
    # -Status (with -Warn): a result row - kept for the window too, whole (not cut to the console), see Write-Ui.
    param([string]$Glyph, [string]$Name, [string]$Text = '', [string]$TextColor = 'd', [string]$Right = '',
          [string]$RightColor = 'd', [int]$NameWidth = 18, [string]$Status = '', [switch]$Warn)
    $plain = { param($s) ([string]$s) -replace '\{', '(' -replace '\}', ')' }   # braces would break the markup
    $row = if ($Status) { @{ Status = $Status; Warn = [bool]$Warn; Name = (& $plain $Name); Text = (& $plain $Text); Right = (& $plain $Right) } } else { $null }
    $w = Get-UiWidth
    $NameWidth = [math]::Max(2, [math]::Min($NameWidth, $w - 7))   # a narrow window: the name gives way first
    $n = Get-Cut (& $plain $Name) ($NameWidth - 1)
    $line = "  {d:$($script:G.Bar)}  $Glyph {w:$n}" + (' ' * ($NameWidth - $n.Length))
    $used = 7 + $NameWidth
    $Right = & $plain $Right
    if ($Right -and $used + $Right.Length + 2 -gt $w) { $Right = '' }   # ...then the time
    $t = Get-Cut (& $plain $Text) ($w - $used - $(if ($Right) { $Right.Length + 2 } else { 0 }))
    if ($t) { $line += $(if ($TextColor) { "{${TextColor}:$t}" } else { $t }) }
    if ($Right) {
        $gap = [math]::Max(2, $w - $used - $t.Length - $Right.Length)
        $line += (' ' * $gap) + $(if ($RightColor) { "{${RightColor}:$Right}" } else { $Right })
    }
    if ($row) { $row.Markup = $line; $script:UiRow = $row }
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
    # "  |" then "  |- Name" - the start of a phase on the rail (and in the window)
    param([string]$Name, [string]$Rest = '')
    $script:UiPhase = $Name
    Send-GuiEvent 'phase' @{ Name = $Name }
    Write-Ui "  {d:$($script:G.Bar)}"
    Write-Ui ("  {d:$($script:G.Tee)$($script:G.Rule)} {w:$Name}" + $Rest)
}

function Show-LiveText {
    # a live line that is just a text: "  |  > restarting Explorer"
    param([string]$Text)
    Send-GuiEvent 'live' @{ Name = $Text; What = ''; Clock = $false }
    Show-Live (Format-Row -Glyph "{b:$($script:G.Run)}" -Name $Text -NameWidth 60)
}

function Start-LiveItem {
    # The live line for one step: "  |  > Name   what   mm:ss" - its clock ticks while Update-LiveTick is called.
    # -NoClock while something blocks the script (a download, Start-Process -Wait): a clock stuck at 00:00 looks hung.
    # (The window keeps its own clock - it is not blocked.)
    param([string]$Name, [string]$What = '', [switch]$NoClock)
    $script:Live = @{ Name = $Name; What = $What; Clock = [System.Diagnostics.Stopwatch]::StartNew(); ShowClock = -not $NoClock }
    Send-GuiEvent 'live' @{ Name = $Name; What = $What; Clock = $true }
    Update-LiveTick
}

function Set-LiveWhat {
    param([string]$What, [switch]$NoClock)
    if ($script:Live) { $script:Live.What = $What; $script:Live.ShowClock = -not $NoClock; Send-GuiEvent 'what' @{ What = $What }; Update-LiveTick }
}

function Update-LiveTick {
    # redraw the live step with its clock (about once a second while an installer runs)
    if (-not $script:Live) { return }
    $s = [int][math]::Floor($script:Live.Clock.Elapsed.TotalSeconds)
    $clock = if ($script:Live.ShowClock) { '{0:00}:{1:00}' -f [math]::Floor($s / 60), ($s % 60) } else { '' }
    Show-Live (Format-Row -Glyph "{b:$($script:G.Run)}" -Name $script:Live.Name -Text $script:Live.What -Right $clock -RightColor 'b' -NameWidth 32)
}

function Stop-LiveItem {
    # how long the live step took (seconds; -1 if there was none)
    $s = if ($script:Live) { $script:Live.Clock.Elapsed.TotalSeconds } else { -1 }
    if ($script:Live) { Send-GuiEvent 'live-end' }
    $script:Live = $null
    return $s
}

function Get-ShortName {
    # "Old Windows components - Remove (...)" -> "Old Windows components"
    param([string]$Content)
    return (($Content -split ' - ')[0]).Trim()
}

function Set-UiNote {
    # what came of a tweak, for its line on the rail ('7 removed', '64 Hz, already the highest'). -Warn: why it is
    # a WARN, in words - it replaces the generic "1 step(s) failed" on the rail and in the summary.
    param([string]$Id, [string]$Text, [switch]$Warn)
    if ($Warn) { $script:UiWarn[$Id] = $Text } else { $script:UiNotes[$Id] = $Text }
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
        foreach ($c in $caps) { $null = Remove-WindowsCapability -Online -Name $c.Name -ErrorAction Stop -WarningAction SilentlyContinue }
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
        $null = Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop -WarningAction SilentlyContinue   # "restart suppressed" - the rail ends with "Restart the PC" anyway
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
    # Screen modes (user32) for the refresh-rate tweak. Compiled once per PowerShell session and KEPT there: when this C#
    # changes, bump the namespace (W11T3 -> W11T4), or a second run in the same window would quietly use the old copy.
    if ('W11T3.Display' -as [type]) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace W11T3 {
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
    foreach ($l in [W11T3.Display]::List()) {
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
    return [W11T3.Display]::SetRate($Device, $Hz)
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
        Set-UiNote $Id 'screen was locked, not changed - run again at an unlocked screen' -Warn
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
    # powercfg -duplicatescheme: the NEW plan's GUID, or $null when Windows refuses.
    param([string]$From)
    $out = (powercfg -duplicatescheme $From 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { return $null }
    $m = [regex]::Match($out, '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    if ($m.Success) { return $m.Value }
    return $null
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

function Reset-LaptopPowerPlan {
    # Laptop (superuser, 2026-09-30): the power plan is Windows' own. 1.6 and 1.7 gave a laptop their plan "Ultimate +
    # Balanced on battery" (remembered as LaptopPowerPlan): if it is the active one, Balanced is back; the plan is deleted.
    param([string]$Id = '')
    $balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $guid = Find-PowerPlan -StateName 'LaptopPowerPlan' -Name 'Ultimate + Balanced on battery'
    if (-not $guid) { Write-Log DEBUG 'no power plan from an earlier version - the plan stays as it is' $Id; return }
    if ((powercfg -getactivescheme | Out-String) -match [regex]::Escape($guid)) {
        $null = powercfg -setactive $balanced
        Write-Log INFO "power plan: Balanced again - the laptop plan of an earlier version goes" $Id
    }
    $null = powercfg -delete $guid
    if ($LASTEXITCODE -ne 0) { Write-Log WARN ("the old laptop plan {0} could not be deleted (powercfg exit code {1})" -f $guid, $LASTEXITCODE) $Id }
    else { Write-Log DEBUG "deleted the old laptop plan $guid" $Id }
    Set-Reg -Id $Id -Path $script:StateKey -Name 'LaptopPowerPlan' -Type String -Value '<RemoveEntry>'
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

function Get-ForegroundProcess {
    # The process whose window is in front (it has the keyboard) - $null when there is none, or no desktop
    try {
        if (-not ([System.Management.Automation.PSTypeName]'Native.Foreground').Type) {
            Add-Type -Namespace Native -Name Foreground -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
'@ -ErrorAction Stop
        }
        $h = [Native.Foreground]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return $null }
        $fgPid = [uint32]0; $null = [Native.Foreground]::GetWindowThreadProcessId($h, [ref]$fgPid)
        return (Get-Process -Id $fgPid -ErrorAction Stop)
    } catch { return $null }
}

function Clear-StuckSearch {
    # Windows' Search window can be stuck in front of everything when a run ends: invisible, yet it takes every click
    # over the middle of the screen (superuser's run 2026-09-29: the Done screen's "Open log" / "Close" did nothing - the
    # clicks went to SearchHost; "Restart now", just outside it, worked). Search in front at the end: close it (Windows
    # starts it again for the next search). Anything else in front is left alone.
    $p = Get-ForegroundProcess
    Write-Log DEBUG ('the end: in front is {0}' -f $(if ($p) { "$($p.ProcessName) (pid $($p.Id))" } else { 'nothing' }))
    if (-not $p -or $p.ProcessName -ne 'SearchHost') { return }
    if ($script:DryRun) { Write-Log DEBUG '[DRYRUN] would close Windows Search (stuck in front of everything)'; return }
    try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Write-Log INFO 'Windows Search was stuck in front of everything (it takes the clicks) - closed it; Windows starts it again for the next search' }
    catch { Write-Log WARN "Windows Search is stuck in front of everything and could not be closed: $($_.Exception.Message)" }
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
    Set-LiveWhat 'installing' -NoClock:(-not $WaitMainOnly)   # only the WaitMainOnly wait below can tick the clock
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
        for ($i = 0; $i -lt 5 -and -not $p.HasExited; $i++) { Start-Sleep -Seconds 1; Update-LiveTick }   # the live clock ticks
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
      Invoke-Step -Id 'WPFTweaksDeleteTempFiles' -Description 'erase TEMP folders (not our log folder, win11-tweaks)' -Action {
          Clear-TempFolder $Env:Temp
          Clear-TempFolder "$Env:SystemRoot\Temp"
      }
  }}

  # Unwanted Pre-Installed Apps ---------------------------------------------------
  [pscustomobject]@{ Id='WPFTweaksDeBloat'; Content='Unwanted Pre-Installed Apps - Remove'; Category='Essential'; Apply={
      $id='WPFTweaksDeBloat'
      # (Microsoft.GetHelp is NOT removed: the troubleshooters in Settings > System > Troubleshoot open through it. Paint
      # and Media Player stay too - superuser, 2026-09-30.)
      $apps = @(
          'Microsoft.WindowsFeedbackHub','Microsoft.BingNews','Microsoft.BingSearch',
          'Microsoft.BingWeather','Clipchamp.Clipchamp','Microsoft.Todos','Microsoft.PowerAutomateDesktop',
          'Microsoft.MicrosoftSolitaireCollection','Microsoft.WindowsSoundRecorder','Microsoft.MicrosoftStickyNotes',
          'Microsoft.Windows.DevHome','Microsoft.OutlookForWindows','Microsoft.WindowsAlarms',
          'Microsoft.StartExperiencesApp',
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
              Disable-WindowsOptionalFeature -FeatureName Recall -Online -NoRestart -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
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

  # Ultimate Performance power plan - max performance, then ACTIVATE it. PC only (Machine='PC'): a laptop keeps Windows'
  # own plan (superuser, 2026-09-30 - on battery Ultimate would keep the CPU from idling).
  [pscustomobject]@{ Id='CustomUltimatePerf'; Content='Ultimate Performance - power plan'; Category='Custom'; Machine='PC'; Apply={
      Invoke-Step -Id 'CustomUltimatePerf' -Description 'enable + activate Ultimate Performance power plan' -Action { Set-PcPowerPlan -Id 'CustomUltimatePerf' }
  }}

  # Laptop power (superuser, 2026-09-30): Windows' own plan - the performance tweaks are for a PC. A laptop that ran 1.6 /
  # 1.7 got their "Ultimate + Balanced on battery" plan: that goes, Balanced is back (Reset-LaptopPowerPlan).
  [pscustomobject]@{ Id='CustomLaptopPower'; Content='Power plan - Windows'' own (an earlier version''s plan removed)'; Category='Custom'; Machine='Laptop'; Apply={
      Invoke-Step -Id 'CustomLaptopPower' -Description "power plan: Windows' own - an earlier version's laptop plan removed" -Action { Reset-LaptopPowerPlan -Id 'CustomLaptopPower' }
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

  # Calls (superuser, 2026-09-28): when a call starts (Discord, Teams...) Windows turns every other sound down by 80%,
  # the game included. 3 = "Do nothing" on the Communications tab of the Sound control panel (no value = the 80%).
  [pscustomobject]@{ Id='CustomNoCallDucking'; Content='Sound - no volume drop during calls'; Category='Custom'; Apply={
      Set-Reg -Id 'CustomNoCallDucking' -Path 'HKCU:\Software\Microsoft\Multimedia\Audio' -Name 'UserDuckingPreference' -Type DWord -Value '3'
  }}

  # Clipboard history (superuser, 2026-09-28): Win+V shows the history from the first press instead of asking to turn
  # it on. On this PC only - syncing it to other devices (the cloud clipboard) stays off.
  [pscustomobject]@{ Id='CustomClipboardHistory'; Content='Clipboard history (Win+V) - Enable'; Category='Custom'; Apply={
      Set-Reg -Id 'CustomClipboardHistory' -Path 'HKCU:\Software\Microsoft\Clipboard' -Name 'EnableClipboardHistory' -Type DWord -Value '1'
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
  # features. (Windows Media Player Legacy can go: the new Media Player is never removed.)
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
      Remove-WinCapability -Id $id -Name 'Media.WindowsMediaPlayer' -Label 'Windows Media Player Legacy'
      Disable-WinFeature   -Id $id -Name 'WindowsMediaPlayer' -Label 'Windows Media Player Legacy (feature)'
      $n = $script:UiRemoved.Count
      $note = if ($n) { '{0} removed' -f $n } else { 'nothing left to remove' }   # which ones: the log (superuser: no list on the line)
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
    [pscustomobject]@{ Name = 'Performance'; Text = @{ PC = 'Ultimate Performance, Memory Integrity off, no hibernation'; Laptop = 'Memory Integrity off, Windows'' own power plan' }
        Ids = @('CustomUltimatePerf', 'CustomLaptopPower', 'CustomDisableVBS', 'WPFToggleGameMode', 'CustomHibernateOff', 'WPFToggleStandbyFix', 'CustomStandbyNoNetBattery') }
    [pscustomobject]@{ Name = 'Input & look'; Text = 'dark theme, Num Lock, Win+V history, no mouse acceleration'
        Ids = @('WPFToggleDarkMode', 'WPFToggleLoginBlur', 'WPFToggleNumLock', 'CustomMouseAccel', 'CustomStickyKeysOff', 'CustomClipboardHistory') }
    [pscustomobject]@{ Name = 'Sound'; Text = 'no volume drop during calls'; Ids = @('CustomNoCallDucking') }
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
# Vendor apps: installed (picked, like every app in the window's list) but ONLY on that vendor's hardware, desktop or
# laptop alike (Hardware is a regex against Win32_ComputerSystem "<Manufacturer> <Model>", or Require a test):
#   Alienware Command Center -> Alienware / Dell G-series (msstore - the Store only offers it there; if the
#                               Store install fails, Install-Alienware falls back to Dell's direct installer).
#                               Older G models have no "Dell " in the model ("Dell Inc. G5 5500"), newer ones
#                               do ("Dell Inc. Dell G15 5511") - hence "Dell ... G<n> <4 digits>".
# (AnyDesk and HP Support Assistant removed per user request.)
$script:VendorApps = @(
    @{ Id='9PMHP03NJ9QP'; Name='Alienware Command Center'; Vendor='Alienware/Dell G'; Hardware='Alienware|^Dell\b.*\bG\d{1,2}\s+\d{4}\b'; Source='msstore' }
)
# winget apps that need their hardware (like the direct apps' Require) - SKIPPED with the reason where it isn't there.
# Keyed by winget ID.
$script:AppRequire = @{
    'NZXT.CAM' = @{ Require = { Test-NzxtHardware }; RequireMsg = 'no NZXT device' }   # NZXT coolers, fans, cases, keyboards
}
# The apps for the hardware in this machine (superuser, 2026-09-30: detected, not a question). They are in the window's
# list - picked, in their own row - only where their hardware is found; the install phase checks it again. Keys as the
# install phase knows them: winget ID / direct-app Name / vendor-app Id.
$script:HardwareApps = @('NZXT.CAM', 'NVIDIA App', 'AMD Chipset Software', 'Intel Chipset Device Software', 'AMD Software Adrenalin', '9PMHP03NJ9QP')
$script:HardwareGroup = 'Drivers & hardware'   # their row in the window
# Runtimes in $script:AppsToInstall: installed for EVERY machine - never in the window's list (games and apps need them;
# the Visual C++ redists and .NET 3.5 aren't in the app lists at all).
$script:RuntimeApps = @('Microsoft.DirectX')
# What the script remembers between runs on this PC: the date the promo apps were removed (CustomRemoveMoreApps) and the
# GUID of the power plan it made (PcPowerPlan; LaptopPowerPlan = 1.6 / 1.7's laptop plan, until it is removed).
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
# The window's app list shows the apps in these rows, in this order - keys as Get-AppChoices gives them (winget ID /
# direct-app Name / vendor-app Id). The hardware apps found here get their own row ($script:HardwareGroup); an app in no
# row lands in "Other".
$script:AppGroups = [ordered]@{
    'Games'            = @('Valve.Steam', 'EpicGames.EpicGamesLauncher', 'Blizzard.BattleNet', 'Ubisoft.Connect', 'Google Play Games')
    'Chat & streaming' = @('Discord.Discord', 'OBSProject.OBSStudio', 'Parsec')
    'Media'            = @('VideoLAN.VLC', 'FL Studio')
    'Tools'            = @('RARLab.WinRAR', 'RevoUninstaller.RevoUninstaller', 'Skillbrains.Lightshot', 'CPUID.HWMonitor', 'SavardSoftware.TurboTop')
    'Internet'         = @('Google Chrome', 'Bitwarden', 'Nextcloud.NextcloudDesktop')
}

# --------------------------------------------------------------------------------------
#  Runner + install phase + summary
# --------------------------------------------------------------------------------------
function Get-OsName {
    # "Windows 11 Pro 25H2 {d:(26200)}" - the build in rail markup (dim)
    param($Os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue))
    $osName = ("$($Os.Caption)" -replace '^\s*Microsoft\s+', '').Trim(); if (-not $osName) { $osName = 'Windows' }
    $ver = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion'
    if ($ver) { $osName += " $ver" }
    if ($Os.BuildNumber) { $osName += " {d:($($Os.BuildNumber))}" }
    return $osName
}

function Write-Banner {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    Write-Log INFO  "=========== WIN11-TWEAKS START ==========="
    Write-Log DEBUG ("host={0}  user={1}" -f $env:COMPUTERNAME, $env:USERNAME)
    Write-Log DEBUG ("os={0}  build={1}" -f $os.Caption, $os.BuildNumber)
    Write-Log DEBUG ("psver={0}  mode={1}" -f $PSVersionTable.PSVersion, ($(if ($script:DryRun) {'DRYRUN'} else {'APPLY'})))
    Write-Log DEBUG ("logfile={0}" -f $script:LogFile)
    # the rail: "  |- WIN11-TEST . Windows 11 Pro 25H2 (26200) . PC . all 27 apps"
    $g = $script:G
    $osName = Get-OsName -Os $os
    $pcName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'this PC' }
    Send-GuiEvent 'banner' @{ Machine = $pcName; Os = (Get-Visible $osName); MachineType = $script:MachineType; User = $script:AppsLabel; DryRun = [bool]$script:DryRun; Log = $script:LogFile }
    Write-Ui "  {d:$($g.Bar)}"
    $bits = @(@($osName, $script:MachineType, $script:AppsLabel) | Where-Object { $_ } | ForEach-Object { "{d:$($g.Dot)} $_" })
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
        Test-GuiStop   # Stop in the window: before the next tweak
        $n++
        if (-not $Late) { Send-GuiEvent 'progress' @{ Name = $t.Content; N = $n; Total = $list.Count } }
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
        try { $null = & $t.Apply }   # a stray output would print onto the live line
        catch { $status = 'FAILED'; $detail = $_.Exception.Message; Write-Log ERROR "tweak failed: $detail" $t.Id }
        # Set-Reg / Set-Svc / Invoke-Step log a WARN instead of throwing -> a tweak with a failed step is WARN, not OK
        if ($status -eq 'OK' -and $script:WarnCount -gt $warnsBefore) {
            $status = 'WARN'; $detail = '{0} step(s) failed - see the log' -f ($script:WarnCount - $warnsBefore)
            if ($script:UiWarn.ContainsKey($t.Id)) { $detail = $script:UiWarn[$t.Id] }   # the tweak said why, in words
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
    return Format-Row -Glyph (Get-Glyph $Rec.Status) -Name (Get-ShortName $Rec.Content) -Text $note -TextColor $color -Right $right -NameWidth 24 -Status $Rec.Status
}

function Write-TweakGroups {
    # The tweak phase on the rail, once it's over: one line per group - done (what it did, its time), or the first thing
    # that went wrong ("! Edge  Microsoft Edge - Debloat: 1 step(s) failed - see the log") - then the tweaks this
    # machine type skips, on one line ("Laptop only  Power plan, Sleep on battery").
    if (-not $script:Ui) { return }
    $late = @{}; foreach ($t in $script:Tweaks) { if ($t.Late) { $late[$t.Id] = $true } }
    $done = @($script:Results | Where-Object { $_.Phase -eq 'Tweak' -and -not $late.ContainsKey($_.Id) })
    $of = { param($r) if ("$($r.Id)" -like 'Trialware.*') { 'CustomOemTrialware' } else { [string]$r.Id } }   # McAfee / Norton rows belong to that tweak
    $pins = @($script:Results | Where-Object { $_.Phase -eq 'Taskbar' -and $_.Id -ne 'Chrome.Pin' })
    $known = @{}; foreach ($grp in $script:TweakGroups) { foreach ($id in $grp.Ids) { $known[$id] = $true } }
    $groups = [System.Collections.Generic.List[object]]::new(); foreach ($grp in $script:TweakGroups) { $groups.Add($grp) }
    $other = @($done | Where-Object { -not $known.ContainsKey((& $of $_)) } | ForEach-Object { $_.Id })
    if ($other) { $groups.Add([pscustomobject]@{ Name = 'Other'; Text = ''; Ids = $other }) }
    foreach ($grp in $groups) {
        $rs = @($done | Where-Object { $grp.Ids -contains (& $of $_) -and $_.Status -ne 'SKIPPED' })
        if ($grp.PSObject.Properties['Pins'] -and $grp.Pins) { $rs += $pins }
        if (-not $rs) { continue }
        $secs = 0.0; foreach ($r in $rs) { if ($r.PSObject.Properties['Seconds']) { $secs += [double]$r.Seconds } }
        $bad = @($rs | Where-Object { $_.Status -in 'FAILED', 'WARN' })
        $text = if ($grp.Text -is [scriptblock]) { [string](& $grp.Text) } elseif ($grp.Text -is [hashtable]) { [string]$grp.Text[$script:MachineType] } else { [string]$grp.Text }
        $time = if ($secs -gt 0) { Format-Span $secs } else { '' }
        if ($bad) {
            $st = if (@($bad | Where-Object { $_.Status -eq 'FAILED' })) { 'FAILED' } else { 'WARN' }
            $what = if ($bad[0].Detail) { '{0}: {1}' -f $bad[0].Content, $bad[0].Detail } else { [string]$bad[0].Content }
            if ($bad.Count -gt 1) { $what += " (+$($bad.Count - 1) more)" }
            Write-Ui (Format-Row -Glyph (Get-Glyph $st) -Name $grp.Name -Text $what -TextColor $(if ($st -eq 'FAILED') { 'r' } else { 'y' }) -Right $time -Status $st)
        } elseif ($script:DryRun) {
            Write-Ui (Format-Row -Glyph (Get-Glyph 'DRYRUN') -Name $grp.Name -Text $text -Right 'dry run' -Status 'DRYRUN')
        } else {
            Write-Ui (Format-Row -Glyph (Get-Glyph 'OK') -Name $grp.Name -Text $text -Right $time -Status 'OK')
        }
    }
    foreach ($only in @($done | Where-Object { $_.Status -eq 'SKIPPED' } | Group-Object Detail)) {
        Write-Ui (Format-Row -Glyph (Get-Glyph 'SKIPPED') -Name $only.Name -Text ((@($only.Group | ForEach-Object { Get-ShortName $_.Content })) -join ', ') -Status 'SKIPPED')
    }
    # the window: the phase is over - how many tweaks were applied and how long they took
    $ran = @($done | Where-Object { $_.Status -ne 'SKIPPED' -and "$($_.Id)" -notlike 'Trialware.*' })
    $all = 0.0; foreach ($r in $ran) { if ($r.PSObject.Properties['Seconds']) { $all += [double]$r.Seconds } }
    Send-GuiEvent 'phase-done' @{ Name = 'Tweaks'; Count = $ran.Count; Time = $(if ($all -gt 0) { Format-Span $all } else { '' }) }
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
    Set-LiveWhat "from Dell's site" -NoClock   # download + Start-Process -Wait: nothing ticks the clock
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
    # 'AuthenticAMD' / 'GenuineIntel' (the CPU's own vendor string - not translated). Only that property: the whole
    # Win32_Processor samples the CPU load first - a second a call (4 of the 5 s of "Getting ready" on VM 102, 2026-09-29)
    return [string](Get-CimInstance Win32_Processor -Property Manufacturer -ErrorAction SilentlyContinue | Select-Object -First 1).Manufacturer
}

function Test-VirtualMachine {
    # A virtual machine (Proxmox/QEMU, VMware, Hyper-V, VirtualBox, Parallels, Xen): its chipset is emulated - no chipset
    # driver from AMD or Intel belongs there.
    return ((Get-Hardware) -match '(?i)QEMU|VMware|Virtual Machine|VirtualBox|innotek|Parallels|Xen|KVM|Standard PC \(')
}

function Test-DualCcdX3D {
    # A Ryzen X3D with two CCDs (7900X3D, 7950X3D, 9900X3D, 9950X3D, 7945HX3D...): AMD's V-Cache driver keeps games on the
    # CCD with the cache by PARKING the other one - through the Balanced plan's core parking, which Ultimate switches off.
    $c = Get-CimInstance Win32_Processor -Property Name, NumberOfCores -ErrorAction SilentlyContinue | Select-Object -First 1   # (only these - Get-CpuVendor)
    return ("$($c.Name)" -match 'X3D' -and [int]$c.NumberOfCores -gt 8)
}

function Get-PnpIds {
    # Every device's ID (PCI\VEN_..., USB\VID_..., HID\VID_...) - read ONCE per run and kept: the hardware checks ask for
    # it several times, and the whole Win32_PnPEntity class takes a moment. Only the ID (see Get-CpuVendor).
    if ($null -eq $script:PnpIds) {
        $script:PnpIds = @(Get-CimInstance Win32_PnPEntity -Property DeviceID -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.DeviceID })
    }
    return $script:PnpIds
}

function Test-PciVendor {
    # Is there a PCI device from this vendor ('1022' AMD, '8086' Intel, '10DE' NVIDIA, '1002' AMD graphics)? A VM on an
    # AMD host reports an AMD CPU but has only emulated devices - AMD's chipset installer would refuse there.
    param([string]$Vendor)
    return [bool](@(Get-PnpIds) | Where-Object { $_ -like "PCI\VEN_$Vendor*" } | Select-Object -First 1)
}

function Test-UsbVendor {
    # A USB device from this vendor ('1E71' NZXT) - the device itself or its HID part
    param([string]$Vendor)
    return [bool](@(Get-PnpIds) | Where-Object { $_ -like "USB\VID_$Vendor*" -or $_ -like "HID\VID_$Vendor*" } | Select-Object -First 1)
}

function Get-Board {
    # "<Manufacturer> <Product>" of the motherboard. A home-built PC says "System manufacturer / System Product Name" in
    # Win32_ComputerSystem - the board is where its maker shows (ASUS ROG STRIX..., NZXT N7...).
    $b = Get-CimInstance Win32_BaseBoard -Property Manufacturer, Product -ErrorAction SilentlyContinue | Select-Object -First 1
    return ("{0} {1}" -f $b.Manufacturer, $b.Product).Trim()
}

function Test-NzxtHardware {
    # What NZXT CAM is for: a Kraken cooler, a Smart Device / RGB & Fan controller (also inside NZXT cases), an NZXT keyboard
    # or mouse - all USB vendor 1E71 - or an NZXT board / an NZXT-built PC
    if (Test-UsbVendor '1E71') { return $true }
    return (((Get-Hardware) -match '(?i)\bNZXT\b') -or ((Get-Board) -match '(?i)\bNZXT\b'))
}

function Test-Gate {
    # A hardware requirement (a Require scriptblock): $true only if it answers yes - an error is a no
    param([scriptblock]$Require)
    $met = $false; try { $met = [bool](& $Require) } catch { }
    return $met
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
    # This app was taken off the window's list: log it, record it as SKIPPED and return $true
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
    return Format-Row -Glyph (Get-Glyph $Status -Warn:$Warn) -Name $Name -Text $Note -TextColor $color -Right $right -NameWidth 32 -Status $Status -Warn:$Warn
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
        'FAILED'     { if ($script:ItemFail) { "$($script:ItemFail), see the log" } else { 'see the log' } }
        'SKIPPED'    { $script:ItemNote }
        'BACKGROUND' { 'still installing in the background' }
        default   { (@($script:ItemNote) + @($extras) | Where-Object { $_ }) -join ', ' }
    }
    Write-Ui (Format-ItemLine -Name $Name -Status $Status -Note $note -Seconds $secs -Warn:$warn)
}

function Get-InstallPlan {
    # The apps this run will go through, in order - the window lists the ones still to come (queued). The apps the
    # install phase skips outright (taken off the list, other machine type, their hardware not here) are not in it.
    param([string]$Hardware = (Get-Hardware))
    $plan = [System.Collections.Generic.List[string]]::new()
    $take = { param($key) -not ($script:NotSelected -and $script:NotSelected.ContainsKey($key)) }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if ($script:VCRedists.Count) { $plan.Add("Visual C++ 2005$($script:G.Dash)2022") }
        foreach ($id in $script:AppsToInstall) {
            $req = $script:AppRequire[$id]
            if (-not (& $take $id) -or ($req -and -not (Test-Gate $req.Require))) { continue }
            $plan.Add((Get-AppLabel $id))
        }
    }
    foreach ($d in $script:DirectApps) {
        if (($d.Machine -and $d.Machine -ne $script:MachineType) -or -not (& $take $d.Name)) { continue }
        if ($script:HardwareApps -contains $d.Name -and $d.Require -and -not (Test-Gate $d.Require)) { continue }
        $plan.Add($d.Name)
    }
    foreach ($a in $script:VendorApps) { if (-not (Get-VendorAppMiss $a $Hardware) -and (& $take $a.Id)) { $plan.Add($a.Name) } }
    $plan
}

function Invoke-InstallPhase {
    Write-Log INFO "=========== INSTALLING APPS ==========="
    Write-UiPhase 'Apps'
    $notSelected = [System.Collections.Generic.List[string]]::new()   # the apps taken off the list - one rail line at the end
    $hw = Get-Hardware
    if ($script:Gui) { Send-GuiEvent 'plan' @{ Apps = @(Get-InstallPlan -Hardware $hw) } }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if ($script:VCRedists.Count) {   # Visual C++ Redistributables first (apps/games need them) - ONE rail line for all
            Test-GuiStop
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
            Test-GuiStop   # Stop in the window: before the next app
            $label = Get-AppLabel $id
            $req = $script:AppRequire[$id]
            if ($req -and -not (Test-Gate $req.Require)) {   # e.g. NZXT CAM with no NZXT device
                Write-Log INFO ("Skipping {0} ({1})" -f $label, $req.RequireMsg)
                $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$id; Content=$id; Status='SKIPPED'; Detail=[string]$req.RequireMsg })
                Write-Ui (Format-ItemLine -Name $label -Status 'SKIPPED' -Note ([string]$req.RequireMsg))
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
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='winget'; Content='winget'; Status='FAILED'; Detail='not found - install App Installer from the Store, then run the script again' })
        Write-Ui (Format-ItemLine -Name 'winget' -Status 'FAILED' -Note 'not found: install App Installer from the Store, then run again')
    }

    # Non-winget apps (direct vendor download): Chrome, Bitwarden, Parsec... and the drivers (their hardware only)
    foreach ($d in $script:DirectApps) {
        Test-GuiStop
        if ($d.Machine -and $d.Machine -ne $script:MachineType) {   # e.g. the chipset / Radeon drivers are PC only
            Write-Log INFO ("Skipping {0} ({1} only)" -f $d.Name, $d.Machine)
            $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$d.Name; Content=$d.Name; Status='SKIPPED'; Detail="$($d.Machine) only" })
            Write-Ui (Format-ItemLine -Name $d.Name -Status 'SKIPPED' -Note "$($d.Machine) only")
            continue
        }
        if (Skip-NotSelected -Key $d.Name -Content $d.Name -Label $d.Name) { $notSelected.Add($d.Name); continue }   # no icon / Chrome pin either
        $from = $script:Results.Count + 1
        $script:ItemNote = ''; $script:ItemFail = ''
        Start-LiveItem -Name $d.Name -What 'downloading' -NoClock   # Invoke-WebRequest blocks - no clock to tick
        $st = Install-DirectDownload @d
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$d.Name; Content=$d.Name; Status=$st; Detail=$(if ($st -eq 'FAILED' -and $script:ItemFail) { $script:ItemFail } elseif ($st -eq 'SKIPPED' -and $script:ItemNote) { $script:ItemNote } else { 'direct' }) })
        if ($st -eq 'OK' -and $script:DesktopShortcutApps.ContainsKey($d.Name)) { $sc = $script:DesktopShortcutApps[$d.Name]; New-DesktopShortcut -Name $sc.Name -Exe $sc.Exe }
        if ($d.Name -eq 'Google Chrome') { $script:ChromePinned = Add-ChromeTaskbarPin }   # pin Chrome to the taskbar RIGHT AFTER it installs
        Write-AppLine -Name $d.Name -Status $st -From $from
    }

    # (WinRAR license is created right after WinRAR installs, in the loop above - see Set-WinRarLicense.)

    # Vendor apps LAST - installed ONLY on that vendor's hardware, desktop or laptop alike:
    #   Alienware Command Center -> Alienware / Dell G-series.
    foreach ($a in $script:VendorApps) {
        Test-GuiStop
        $miss = Get-VendorAppMiss $a $hw
        if ($miss) {   # NOT a failure - just not this vendor's machine
            Write-Log DEBUG "$($a.Name): skipped (${miss}: '$hw')"
            $script:Results.Add([pscustomobject]@{ Phase='Install'; Id=$a.Id; Content=$a.Name; Status='SKIPPED'; Detail=$miss })
            Write-Ui (Format-ItemLine -Name $a.Name -Status 'SKIPPED' -Note $miss)
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
    if ($notSelected.Count) { Write-Ui (Format-Row -Glyph (Get-Glyph 'SKIPPED') -Name 'Not selected' -Text ($notSelected -join ', ') -NameWidth 32 -Status 'SKIPPED') }

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
        Send-GuiEvent 'dotnet' @{ State = 'running' }   # the window: "downloading in the background" next to the apps
    } catch { Write-Log DEBUG ".NET 3.5 background start failed: $($_.Exception.Message)" }
}

function Format-PhaseLine {
    # "  |- Name   text                                   right" - a phase that is one line (.NET 3.5). -Status: its
    # result, for the window (see Format-Row).
    param([string]$Name, [string]$Text, [string]$Right = '', [string]$Status = '')
    $line = "  {d:$($script:G.Tee)$($script:G.Rule)} {w:$Name}   $Text"
    if ($Right) { $line += (' ' * [math]::Max(2, (Get-UiWidth) - (Get-Visible $line).Length - $Right.Length)) + "{d:$Right}" }
    if ($Status) {   # (the window has its own status glyph - not the rail's again at the start of the text)
        $plain = (Get-Visible $Text) -replace ('^' + [regex]::Escape($script:G.Fail) + '\s+'), ''
        $script:UiRow = @{ Markup = $line; Status = $Status; Warn = $false; Name = $Name; Text = $plain; Right = $Right }
    }
    return $line
}

function Enable-DotNetFeatures {
    # Print a clean "Installing .NET 3.5 / Done!" pair HERE at the end. The download already ran in the
    # background during the install phase (Start-DotNet35), so on a normal machine this is instant; if it's
    # still going we WAIT until it fully finishes (live heartbeat, no cap). Then .NET 4 (quiet).
    # The rail: ONE line - ".NET 3.5   ready", "ready at the next restart", or why not.
    $g = $script:G
    $script:UiPhase = '.NET 3.5'; Send-GuiEvent 'phase' @{ Name = '.NET 3.5' }
    Write-Ui "  {d:$($g.Bar)}"
    if ($script:DryRun) {
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NetFx3'; Content='.NET 3.5'; Status='DRYRUN'; Detail='' })
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NetFx4-AdvSrvs'; Content='.NET 4'; Status='DRYRUN'; Detail='' })
        Write-Ui (Format-PhaseLine '.NET 3.5' '{d:dry run}' -Status 'DRYRUN')
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
        Send-GuiEvent 'live' @{ Name = '.NET 3.5'; What = 'downloading from Windows Update'; Clock = $true; Since = $clock.Elapsed.TotalSeconds }
        while (-not $script:DotNet35Proc.HasExited) {
            Test-GuiStop   # Stop in the window: DISM keeps going on its own (/NoRestart), like with Ctrl+C
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
        Send-GuiEvent 'live-end'
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
        if ($script:DotNet35Proc) { Write-Ui (Format-PhaseLine '.NET 3.5' "ready {d:$($g.Dot) downloaded next to the apps}" $wait -Status 'OK') }
        else { Write-Ui (Format-PhaseLine '.NET 3.5' 'already on' -Status 'OK') }
    } elseif ($state -eq 'EnablePending') {
        Write-Log OK "Done! (finishes at the next restart)"; $rec3.Detail = 'finishes at the next restart'
        Write-Ui (Format-PhaseLine '.NET 3.5' 'ready at the next restart' $wait -Status 'OK')
    } elseif (-not $script:DotNet35Proc) {
        Write-Log WARN "Failed - .NET 3.5 (was not started)"; $st3 = 'FAILED'; $rec3.Detail = 'was not started'
        Write-Ui (Format-PhaseLine '.NET 3.5' "{r:$($g.Fail) not started, see the log}" -Status 'FAILED')
    } else {
        Write-Log WARN "Failed - .NET 3.5 (DISM exit code $code, state '$state' - see %TEMP%\dism_NetFx3.log)"; $st3 = 'FAILED'
        $rec3.Detail = "DISM exit code $code"
        Write-Ui (Format-PhaseLine '.NET 3.5' "{r:$($g.Fail) not installed (DISM $code), see the log}" $wait -Status 'FAILED')
    }
    $rec3.Status = $st3
    # .NET 4 is already enabled on Win11 -> record quietly (no console clutter); enable only if somehow off.
    if ((Get-WindowsOptionalFeature -Online -FeatureName 'NetFx4-AdvSrvs' -ErrorAction SilentlyContinue).State -eq 'Enabled') {
        Write-Log DEBUG ".NET 4 already enabled"
        $script:Results.Add([pscustomobject]@{ Phase='Install'; Id='NetFx4-AdvSrvs'; Content='.NET 4'; Status='OK'; Detail='already enabled' })
    } else {
        $script:ItemNote = ''; $script:ItemFail = ''
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
    # (the window gets the same, as data)
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
    $problems = @(foreach ($r in @($script:Results | Where-Object { $_.Status -in 'WARN', 'FAILED' })) {
        $label = if ($script:AppNames.ContainsKey([string]$r.Id)) { $script:AppNames[[string]$r.Id] } else { [string]$r.Content }
        $why = if ($r.Detail -and $r.Detail -ne 'direct') { ": $($r.Detail)" } else { '' }
        @{ Status = [string]$r.Status; Text = ("$label$why" -replace '[{}]', '') }   # whole - it may hold a link to follow
    })
    $dismBusy = $script:DotNet35Proc -and -not $script:DotNet35Proc.HasExited
    $next = @(
        if ($dismBusy) { '.NET 3.5 is still installing in the background - no restart until it is done.' }
        if (-not $script:RunFinished) { $(if ($dismBusy) { 'Then run the script again to finish the rest.' } else { 'Run the script again to finish the rest.' }) }
        elseif ($script:DryRun) { 'Dry run - nothing was changed.' }
        elseif ($restart) { 'Restart the PC to finish. Windows completes some changes only at a restart.' }
        else { 'Restart or sign out to apply everything.' }
    )
    $script:SummaryLine = "$head   " + (Get-Visible ($parts -join " $($gl.Dot) "))
    Send-GuiEvent 'summary' @{ Head = $head; Ok = [int]$count['OK']; Skipped = [int]$count['SKIPPED']; Warn = [int]$count['WARN']
        Failed = [int]$count['FAILED']; Background = [int]$count['BACKGROUND']; WouldApply = [int]$count['DRYRUN']; DryRun = [bool]$script:DryRun
        Finished = [bool]$script:RunFinished; Restart = [bool]($restart -and $script:RunFinished -and -not $dismBusy); Problems = $problems
        Next = $next; Log = $script:LogFile }
    if (-not $script:Ui) { return }
    Write-Ui "  {d:$($gl.Bar)}"
    Write-Ui ("  {d:$($gl.End)$($gl.Rule)} {w:$head}   " + ($parts -join " {d:$($gl.Dot)} "))
    foreach ($p in $problems) { Write-Ui ('     ' + (Get-Glyph $p.Status) + ' ' + $p.Text) }
    Write-Ui ''
    foreach ($line in $next) { Write-Ui "     {y:$($gl.Run)} $line" }
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
    # The rail head and "Continue?" - then the machine type (detected, or -Machine) and the app list: on the console
    # everything goes in (taking apps off the list is the window's job). With the window open, the window asks instead
    # (its Setup screen - Invoke-GuiSetup).
    if ($script:Gui) {
        Invoke-GuiSetup
        if ($script:Gui) { return }   # answered - or cancelled - in the window
        # the window broke before it got an answer (Invoke-GuiSetup let it go): the console, below
    }
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
    $mc = Get-MachineChoice
    $script:MachineType = $mc.Type
    Write-Log INFO ("Machine type: {0} ({1})" -f $mc.Type, $mc.Why)
    $hw = @(Get-HardwareApps)
    Write-HardwareLog $hw
    Set-AppsLabel -Total (@(Get-AppChoices).Count + @($hw | Where-Object { $_.Found }).Count)
}

function Get-DetectedMachineType {
    # PC or laptop, by what the machine says it is: its case (Laptop, Notebook, Convertible...) or its firmware's power
    # profile (Mobile). A battery decides only when the case says nothing (Other / Unknown - a VM): a desktop's UPS is a
    # "battery" to Windows too. Why goes into $script:DetectedWhy (the log).
    $portable = @{ 8 = 'Portable'; 9 = 'Laptop'; 10 = 'Notebook'; 11 = 'Hand Held'; 12 = 'Docking Station'; 14 = 'Sub Notebook'; 30 = 'Tablet'; 31 = 'Convertible'; 32 = 'Detachable' }
    $desktop = @{ 3 = 'Desktop'; 4 = 'Low Profile Desktop'; 5 = 'Pizza Box'; 6 = 'Mini Tower'; 7 = 'Tower'; 13 = 'All in One'; 15 = 'Space-saving'; 16 = 'Lunch Box'; 24 = 'Sealed-case PC'; 35 = 'Mini PC'; 36 = 'Stick PC' }
    $cs = Get-CimInstance Win32_ComputerSystem -Property PCSystemType -ErrorAction SilentlyContinue | Select-Object -First 1
    $cases = @(Get-CimInstance Win32_SystemEnclosure -Property ChassisTypes -ErrorAction SilentlyContinue | ForEach-Object { @($_.ChassisTypes) } |
        Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
    $lap = @($cases | Where-Object { $portable.ContainsKey($_) })
    if ($lap) { $script:DetectedWhy = 'a laptop case ({0})' -f $portable[$lap[0]]; return 'Laptop' }
    if ([int]$cs.PCSystemType -eq 2) { $script:DetectedWhy = 'a Mobile power profile'; return 'Laptop' }
    $known = @($cases | Where-Object { $_ -gt 2 })
    if ($known) { $script:DetectedWhy = 'a desktop case ({0})' -f $(if ($desktop.ContainsKey($known[0])) { $desktop[$known[0]] } else { "type $($known[0])" }); return 'PC' }
    $bat = $false; try { $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop).Count -gt 0 } catch { }
    if ($bat) { $script:DetectedWhy = 'a battery'; return 'Laptop' }
    $script:DetectedWhy = 'no battery'; return 'PC'
}

function Get-MachineChoice {
    # PC or laptop: -Machine when it was given, else what the machine says it is - and why, for the log
    if ($Machine -eq 'PC' -or $Machine -eq 'Laptop') { return @{ Type = $(if ($Machine -eq 'Laptop') { 'Laptop' } else { 'PC' }); Why = 'set by -Machine' } }
    $t = Get-DetectedMachineType
    return @{ Type = $t; Why = "detected - $($script:DetectedWhy)" }
}

function Get-AppLabel([string]$Id) {
    # an app's name as people know it (a winget ID has a friendly name; direct / vendor apps are their name already)
    if ($script:AppNames.ContainsKey($Id)) { return $script:AppNames[$Id] }
    return $Id
}

function Get-AppChoices {
    # The apps in the window's list, in install order: the winget apps (not the runtimes) and the direct downloads. The
    # hardware apps are not here - they join the list where their hardware is found (Get-HardwareApps). Key = what the
    # install phase looks up in $script:NotSelected.
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $script:AppsToInstall) {
        if ($script:RuntimeApps -contains $id -or $script:HardwareApps -contains $id) { continue }
        $list.Add([pscustomobject]@{ Key = $id; Name = (Get-AppLabel $id) })
    }
    foreach ($d in $script:DirectApps) {
        if ($script:HardwareApps -contains $d.Name) { continue }
        $list.Add([pscustomobject]@{ Key = $d.Name; Name = $d.Name })
    }
    return $list
}

function Get-HardwareApps {
    # The hardware apps, in install order, and whether this machine has what each is for: Key / Name / Found / Why (why
    # not - for the log and the install phase). A PC-only one on a laptop is "PC only".
    $hw = Get-Hardware
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $script:AppsToInstall) {
        if ($script:HardwareApps -notcontains $id) { continue }
        $r = $script:AppRequire[$id]
        $why = if ($r -and -not (Test-Gate $r.Require)) { [string]$r.RequireMsg } else { '' }
        $list.Add([pscustomobject]@{ Key = $id; Name = (Get-AppLabel $id); Found = (-not $why); Why = $why })
    }
    foreach ($d in $script:DirectApps) {
        if ($script:HardwareApps -notcontains $d.Name) { continue }
        $why = if ($d.Machine -and $d.Machine -ne $script:MachineType) { "$($d.Machine) only" }
               elseif ($d.Require -and -not (Test-Gate $d.Require)) { $(if ($d.RequireMsg) { [string]$d.RequireMsg } else { 'not for this PC' }) } else { '' }
        $list.Add([pscustomobject]@{ Key = $d.Name; Name = $d.Name; Found = (-not $why); Why = $why })
    }
    foreach ($a in $script:VendorApps) {
        $why = Get-VendorAppMiss $a $hw
        $list.Add([pscustomobject]@{ Key = $a.Id; Name = $a.Name; Found = (-not $why); Why = $why })
    }
    return $list
}

function Get-VendorAppMiss($App, [string]$Hardware) {
    # why a vendor app is not for this machine ('' = it is): its Require test, else its Hardware regex on the model
    if ($App.Require) { if (Test-Gate $App.Require) { return '' } else { return $(if ($App.RequireMsg) { [string]$App.RequireMsg } else { "not $($App.Vendor) hardware" }) } }
    if ($Hardware -match $App.Hardware) { return '' }
    return "not $($App.Vendor) hardware"
}

function Write-HardwareLog($Hardware) {
    # what was found for the hardware apps, and why the others are not for this machine
    $found = @($Hardware | Where-Object { $_.Found } | ForEach-Object { $_.Name })
    $miss = @($Hardware | Where-Object { -not $_.Found } | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Why })
    Write-Log INFO ("Hardware apps: {0}" -f $(if ($found) { $found -join ', ' } else { 'none for this machine' }))
    if ($miss) { Write-Log DEBUG ("not for this machine: {0}" -f ($miss -join ', ')) }
}

function Set-AppsLabel {
    # "Apps: all 27" / "Apps: 24 of 27 - left out: Steam, Parsec, OBS Studio" in the log, and the machine line's label
    param([int]$Total, [string[]]$Left = @())
    $Left = @($Left | Where-Object { $_ })
    $n = $Total - $Left.Count
    if ($Left.Count) {
        Write-Log INFO ("Apps: {0} of {1} - left out: {2}" -f $n, $Total, ($Left -join ', '))
        $script:AppsLabel = '{0} of {1} apps' -f $n, $Total
    } else {
        Write-Log INFO ("Apps: all {0}" -f $Total)
        $script:AppsLabel = 'all {0} apps' -f $Total
    }
}

# --------------------------------------------------------------------------------------
#  The window (variant A of the design page - superuser's pick, 2026-09-28). The run itself does not change: it goes on
#  here, on the main thread, as always, and only FEEDS the window (Send-GuiEvent -> a queue). The window has its own
#  thread (an STA runspace with its own WPF dispatcher, $script:GuiCode): it asks the setup questions, shows the run and
#  can ask the run to stop between two steps (Test-GuiStop). -Console keeps the rail in the console.
# --------------------------------------------------------------------------------------
function Get-SessionId {
    try { return (Get-Process -Id $PID).SessionId } catch { return -1 }
}

function Test-WpfAvailable {
    try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop; return $true } catch { return $false }
}

function Test-GuiMode {
    # The window is for a person at a desktop: not over SSH or from a service (no keyboard, session 0), not with -Console
    # (the rail in the console), -Detailed (the log on the console) or -Reboot (an unattended run: the console counts
    # down to the restart), and only where WPF loads
    if ($script:ConsoleOnly -or $script:Detailed -or $Reboot) { return $false }
    if (-not (Test-Interactive)) { return $false }
    if ((Get-SessionId) -eq 0) { return $false }
    return (Test-WpfAvailable)
}

function Send-GuiEvent {
    # One thing for the window to show - a phase, a row, the step running now, the summary - into its queue. No window,
    # nothing. The run never waits for the window.
    param([string]$Type, [hashtable]$Data = @{})
    if (-not $script:Gui) { return }
    Write-GuiClicks
    $Data['Type'] = $Type
    $script:Gui.Shared.Events.Enqueue($Data)
}

function Write-GuiClicks {
    # What was pressed in the window, with its time - into the log (the window's thread cannot write it). Picked up
    # whenever the run sends the window something, and when it lets the window go (Close-Gui).
    if (-not $script:Gui -or -not $script:Gui.Shared.Clicks) { return }
    $c = $null
    while ($script:Gui.Shared.Clicks.TryDequeue([ref]$c)) { Write-Log INFO "window: $c" }
}

function Test-ConsoleQuiet {
    # While the window is open it shows the run and the console stays quiet. Closed early: the rail comes back.
    return [bool]($script:Gui -and -not $script:Gui.Shared.Closed)
}

function Get-ConsoleInfo {
    # This process's console window and how many programs share the console (the .bat: cmd.exe + powershell.exe = 2)
    if (-not ([System.Management.Automation.PSTypeName]'Native.ConsoleWindow').Type) {
        Add-Type -Namespace Native -Name ConsoleWindow -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint GetConsoleProcessList(uint[] processList, uint processCount);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
    }
    $list = New-Object 'uint32[]' 16
    return @{ Handle = [Native.ConsoleWindow]::GetConsoleWindow(); Processes = [int][Native.ConsoleWindow]::GetConsoleProcessList($list, 16) }
}

function Set-ConsoleVisible {
    # SW_SHOW / SW_HIDE; returns whether the window WAS visible
    param([IntPtr]$Handle, [bool]$Visible)
    return [bool][Native.ConsoleWindow]::ShowWindow($Handle, $(if ($Visible) { 5 } else { 0 }))
}

function Set-ConsoleWindow {
    # The console behind the window: hidden while the window shows the run (superuser: "only the window"), shown again
    # when it is needed - the window went early, or it is your own console at the end. Only a console that is this
    # run's alone (not the .bat's, where cmd waits on a `pause` - it must never be left hidden) and only if it was
    # visible: -Show undoes our own hide, nothing else. (Windows Terminal may keep its window.) No console: nothing.
    param([switch]$Show)
    if ($Show -and -not $script:ConsoleHidden) { return }
    try {
        $c = Get-ConsoleInfo
        if ($c.Handle -eq [IntPtr]::Zero) { return }
        if ($Show) { $null = Set-ConsoleVisible $c.Handle $true; $script:ConsoleHidden = $false; Write-Log DEBUG 'console shown again'; return }
        if ($c.Processes -gt 1) { Write-Log DEBUG "console shared with another program ($($c.Processes) - the .bat's cmd) - left as it is"; return }
        $script:ConsoleHidden = Set-ConsoleVisible $c.Handle $false
        if ($script:ConsoleHidden) { Write-Log DEBUG 'console hidden behind the window' }
    } catch { Write-Log DEBUG "console window left as is: $($_.Exception.Message)" }
}

function Exit-Console {
    # The console the elevation relaunch opened (its -NoExit would keep it) goes with the window - nothing left in it
    Write-Log DEBUG 'the run is over and its window closed - its own console closes too'
    [Environment]::Exit(0)
}

function Test-GuiStop {
    # Stop in the window: the run ends here, between two steps - Main's finally writes the summary, as after Ctrl+C
    if ($script:Gui -and $script:Gui.Shared.Stop) { Write-GuiClicks; throw [System.OperationCanceledException]::new('Stopped from the window') }
}

function Get-AppGroup {
    param([string]$Key)
    foreach ($g in $script:AppGroups.Keys) { if ($script:AppGroups[$g] -contains $Key) { return $g } }
    return 'Other'
}

function Get-SetupPayload {
    # What the window's Setup screen needs: this PC and its type (and why), the app list - row by row, in the rows' order,
    # the hardware apps found here in their own row -, what always goes in, how many tweaks run on this machine type
    $mc = Get-MachineChoice
    $saved = $script:MachineType
    try {
        $script:MachineType = $mc.Type
        $choices = @(Get-AppChoices); $hw = @(Get-HardwareApps)
    } finally { $script:MachineType = $saved }
    $apps = [System.Collections.Generic.List[object]]::new()
    foreach ($g in @($script:AppGroups.Keys) + @('Other')) {
        $in = @($choices | Where-Object { (Get-AppGroup $_.Key) -eq $g })
        if ($g -ne 'Other') { $order = @($script:AppGroups[$g]); $in = @($in | Sort-Object { $order.IndexOf([string]$_.Key) }) }
        foreach ($c in $in) { $apps.Add(@{ Key = $c.Key; Name = $c.Name; Group = $g }) }
    }
    foreach ($h in @($hw | Where-Object { $_.Found })) { $apps.Add(@{ Key = $h.Key; Name = $h.Name; Group = $script:HardwareGroup }) }
    $runtimes = @($script:RuntimeApps | ForEach-Object { Get-AppLabel $_ })
    return @{
        Version = $script:Version; PcName = $(if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'this PC' }); Os = (Get-Visible (Get-OsName))
        Machine = $mc.Type; MachineWhy = $mc.Why
        Apps = @($apps); Hardware = @($hw | Where-Object { $_.Found } | ForEach-Object { $_.Name })
        NotOffered = @($hw | Where-Object { -not $_.Found } | ForEach-Object { @{ Name = $_.Name; Why = $_.Why } })   # for the log
        Groups = @($script:AppGroups.Keys) + @($script:HardwareGroup, 'Other'); HardwareGroup = $script:HardwareGroup
        TweakCount = @($script:Tweaks | Where-Object { -not $_.Machine -or $_.Machine -eq $mc.Type }).Count; Log = $script:LogFile
        Always = @("Visual C++ 2005$($script:G.Dash)2022") + $runtimes + @('.NET 3.5')
    }
}

function Set-SetupAnswer {
    # The window's answer: the machine type it showed, and the apps taken off its list - the install phase skips them
    # ("not selected"). Everything else in the list goes in.
    param([hashtable]$Answer)
    $script:MachineType = if ($Answer.Machine -eq 'Laptop') { 'Laptop' } else { 'PC' }
    Write-Log INFO ("Machine type: {0}{1}" -f $script:MachineType, $(if ($Answer.MachineWhy) { " ($($Answer.MachineWhy))" } else { '' }))
    $hw = @(Get-HardwareApps)
    Write-HardwareLog $hw
    $list = @(Get-AppChoices) + @($hw | Where-Object { $_.Found })
    $off = @($Answer.Off); $left = @()
    foreach ($c in $list) { if ($off -contains $c.Key) { $script:NotSelected[$c.Key] = 'not selected'; $left += $c.Name } }
    Set-AppsLabel -Total $list.Count -Left $left
}

function Invoke-GuiSetup {
    # The window's Setup screen - the machine type it detected and the app list, everything picked; Start or Cancel.
    # Cancel (or closing the window) is "Continue? n": nothing is changed.
    $p = if ($null -ne $script:SetupPayload) { $script:SetupPayload } else { Get-SetupPayload }   # (gathered while the window started - Start-Gui)
    Send-GuiEvent 'setup' @{ Payload = $p }
    $sh = $script:Gui.Shared
    while (-not $sh.Answer -and -not $sh.Closed) { Start-Sleep -Milliseconds 100 }
    $a = $sh.Answer
    if (-not $a -and ($sh.Error -or $sh.ErrorCount)) {
        # it closed itself (it could not draw) - that is no Cancel: the console asks instead (Show-Intro)
        Write-Log WARN 'the window broke before an answer - the console asks instead'
        Close-Gui; Set-ConsoleWindow -Show
        return
    }
    if (-not $a -or $a.Cancel) {
        Write-Log INFO 'Cancelled in the window - nothing was changed.'
        $script:Cancelled = $true
        return
    }
    if (-not $a.MachineWhy) { $a.MachineWhy = $p.MachineWhy }   # (the window only shows it - the log says why)
    Set-SetupAnswer $a
}

function Stop-GuiThread {
    # Let the window's thread go - never blocking the run: on CloseRequest the window closes itself (its timer). Stuck
    # anyway: ask it to stop WITHOUT waiting and leave it be - PowerShell.Stop() (and Dispose) wait for a .NET call like
    # ShowDialog to return, which could be never.
    param($PowerShell, $Runspace, $Handle, [double]$WaitSec = 5)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Handle -and -not $Handle.IsCompleted -and $sw.Elapsed.TotalSeconds -lt $WaitSec) { Start-Sleep -Milliseconds 100 }
    try {
        if ($Handle -and -not $Handle.IsCompleted) {
            $null = $PowerShell.BeginStop($null, $null)
            Write-Log WARN "the window did not close in $WaitSec s - its thread is left to stop on its own"
            return
        }
        if ($PowerShell) { $PowerShell.Dispose() }
        if ($Runspace) { $Runspace.Dispose() }
    } catch { Write-Log DEBUG "the window's thread: $($_.Exception.Message)" }
}

function Find-CascadiaMono {
    # Cascadia Mono on this PC: in Windows' own fonts, or lent by the Windows Terminal app (Windows 11) - the newest one
    $inbox = Join-Path "$env:SystemRoot\Fonts" 'CascadiaMono.ttf'
    if (Test-Path -LiteralPath $inbox) { return $inbox }
    Get-ChildItem "$env:ProgramFiles\WindowsApps" -Directory -Filter 'Microsoft.WindowsTerminal_*_x64__8wekyb3d8bbwe' -ErrorAction SilentlyContinue |
        Sort-Object CreationTime -Descending | ForEach-Object { Join-Path $_.FullName 'CascadiaMono.ttf' } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Get-GuiTextFont {
    # The window's text font: Cascadia Mono - from OUR copy. Windows gets it from the Windows Terminal app, and the Store
    # may update that app mid-run (a new PC's first hour): the old font file goes, and a window still drawing with it
    # cannot draw text any more (superuser's run, 2026-09-29: black at the next redraw, 78,226 errors). Our copy cannot
    # go. No Cascadia Mono here: Consolas (a Windows font).
    try {
        $src = Find-CascadiaMono
        if (-not $src) { Write-Log DEBUG 'window font: no Cascadia Mono on this PC - Consolas'; return 'Consolas' }
        $dir = Join-Path (Join-Path $env:LOCALAPPDATA 'win11-tweaks') 'fonts'
        $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
        $dst = Join-Path $dir 'CascadiaMono.ttf'
        $how = "our copy of Cascadia Mono (from $src)"
        try { Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop }
        catch {   # in use by another run's window: that copy is the same font
            if (-not (Test-Path -LiteralPath $dst)) { throw }
            $how = "our earlier copy of Cascadia Mono (a new copy failed: $($_.Exception.Message))"
        }
        Write-Log DEBUG "window font: $how"
        return ('{0}#Cascadia Mono, Consolas' -f [Uri]::new($dir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [UriKind]::Absolute).AbsoluteUri)
    } catch { Write-Log DEBUG "window font: Consolas ($($_.Exception.Message))"; return 'Consolas' }
}

function Start-Gui {
    # Open the window in its own thread and wait (up to 20 s) until it is up. If it does not open, the console shows
    # the run, as before.
    param([int]$TimeoutSec = 20)
    $sh = [hashtable]::Synchronized(@{ Events = [System.Collections.Concurrent.ConcurrentQueue[object]]::new(); Answer = $null
        Stop = $false; Action = $null; Closed = $false; Ready = $false; Error = $null; CloseRequest = $false
        Clicks = [System.Collections.Concurrent.ConcurrentQueue[string]]::new(); TextFont = (Get-GuiTextFont) })
    $ps = $null; $rs = $null
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('Shared', $sh)
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $null = $ps.AddScript($script:GuiCode + "`nShow-GuiWindow -Shared `$Shared")
        $handle = $ps.BeginInvoke()
    } catch {
        Write-Log WARN "the window could not start ($($_.Exception.Message)) - the console shows the run"
        Stop-GuiThread $ps $rs $null
        return
    }
    # The window takes a second or more to come up (WPF - more on a new PC's first run). Meanwhile this thread does what
    # would otherwise follow it under "Getting ready" (5 s of that on VM 102, 2026-09-29): it gathers the setup screen's
    # facts (the apps for this hardware - WMI queries) and builds the console type that hides the console behind the window
    $t = [System.Diagnostics.Stopwatch]::StartNew()
    try { $script:SetupPayload = Get-SetupPayload; Write-Log DEBUG ('setup screen: gathered in {0:N1} s, while the window started' -f $t.Elapsed.TotalSeconds) }
    catch { $script:SetupPayload = $null; Write-Log DEBUG "setup screen: not gathered ahead ($($_.Exception.Message))" }
    try { $null = Get-ConsoleInfo } catch { }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $sh.Ready -and -not $sh.Error -and -not $handle.IsCompleted -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) { Start-Sleep -Milliseconds 100 }
    if (-not $sh.Ready -or $sh.Error) {
        $why = if ($sh.Error) { [string]$sh.Error } elseif ($ps.Streams.Error.Count) { [string]$ps.Streams.Error[0] } elseif ($handle.IsCompleted) { 'it closed' } else { "no answer in $TimeoutSec s" }
        Write-Log WARN "the window did not open ($why) - the console shows the run"
        $sh.CloseRequest = $true
        Stop-GuiThread $ps $rs $handle 3
        return
    }
    $script:Gui = @{ Shared = $sh; PowerShell = $ps; Runspace = $rs; Handle = $handle }
    Write-Log INFO 'the window is open (-Console keeps the rail in the console)'
    Set-ConsoleWindow   # only the window from now on
}

function Close-Gui {
    # Let the window go (it closes itself if it is still open) and free its thread
    if (-not $script:Gui) { return }
    Write-GuiClicks
    $g = $script:Gui; $script:Gui = $null
    $g.Shared.CloseRequest = $true
    if ($g.Shared.ErrorCount) { Write-Log WARN ("the window: {0} error(s), the last: {1}" -f $g.Shared.ErrorCount, $g.Shared.LastError) }
    if ($g.Shared.FirstError) { Write-Log WARN "the window's first error: $($g.Shared.FirstError)" }
    if ($g.Shared.Error) { Write-Log WARN "the window: $($g.Shared.Error)" }
    Stop-GuiThread $g.PowerShell $g.Runspace $g.Handle
}

function Wait-GuiClose {
    # The window shows how the run went until it is closed. "Restart now" in it restarts the PC (never in a dry run).
    # -Quiet: the console was opened only for the run (the elevation relaunch) - when the window saw the run to its end
    # without errors, the console goes too (Exit-Console at the very end); else it comes back with the summary and log.
    param([switch]$Quiet)
    if (-not $script:Gui) { return }
    $sh = $script:Gui.Shared
    while (-not $sh.Closed -and -not $sh.Action -and -not $script:Gui.Handle.IsCompleted) { Start-Sleep -Milliseconds 200 }
    $action = $sh.Action; $replayed = [bool]$script:Gui.Replayed
    Close-Gui
    if ($Quiet -and -not $replayed -and -not $sh.Error -and -not $sh.ErrorCount) { $script:ExitWhenDone = $true }
    elseif (-not $replayed) {   # (a window that went early: the console already shows the whole rail, the summary with it)
        Set-ConsoleWindow -Show
        if ($script:SummaryLine) { Write-Host ('  ' + $script:SummaryLine) }
        Write-Host ('  Log  ' + $script:LogFile) -ForegroundColor DarkGray
    }
    if ($action -eq 'restart' -and -not $script:DryRun) {
        Write-Log INFO 'Restart now - from the window'
        try { Restart-Computer -Force -ErrorAction Stop }
        catch {   # (e.g. another user is signed in) - the console that was about to close stays to say so
            Write-Log ERROR "Restart now failed: $($_.Exception.Message)"
            if ($script:ExitWhenDone) { $script:ExitWhenDone = $false; Set-ConsoleWindow -Show; if ($script:SummaryLine) { Write-Host ('  ' + $script:SummaryLine) } }
            Write-Host "  Restart now failed: $($_.Exception.Message) - restart the PC yourself." -ForegroundColor Yellow
        }
    }
}

# The window's own code - it runs in the window's thread (Start-Gui adds the call to Show-GuiWindow), never here. Functions
# only, so the tests can load it. ASCII only: every glyph is an XML entity (&#xB7;) or a Segoe Fluent Icons code. The
# look is variant A of the design page: near-black, one line down the left with a dot per phase, one row per app.
$script:GuiCode = @'
$GuiC = @{ bg = '#07090D'; line = '#1B2432'; line2 = '#263246'; tx = '#E6EDF6'; tx2 = '#9AA7B8'; tx3 = '#66728A'; blue = '#3D7BFF'
    ok = '#35C48A'; warn = '#E0A93A'; err = '#FF6B6B'; blue16 = '#293D7BFF'; blue04 = '#0A3D7BFF'; blue10 = '#1A3D7BFF'
    blue18 = '#2E3D7BFF'; blue26 = '#423D7BFF'; blue55 = '#8C3D7BFF'; err16 = '#29FF6B6B'; err25 = '#40FF6B6B'; foot = '#B30B0F15'
    hover = '#141B26'; hover2 = '#0F1520'; primary2 = '#5A8FFF'; close = '#C42B1C' }
$GuiIcons = 'Segoe Fluent Icons, Segoe MDL2 Assets'
$GuiDot = '&#xB7;'
$GuiMore = '&#x2026;'
$GuiNs = "xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'"

function ConvertTo-GuiXml([string]$Text) {
    # data into XAML: escaped, and every non-ASCII character as an entity (the run's texts carry the rail's dots and dashes)
    [regex]::Replace([Security.SecurityElement]::Escape($Text), '[\uD800-\uDBFF][\uDC00-\uDFFF]|[^\x20-\x7E]', {
        param($c)
        $v = -1; try { $v = [char]::ConvertToUtf32($c.Value, 0) } catch { }
        if ($v -lt 0x20 -and $v -notin 9, 10, 13) { return ' ' }   # a control character or half a pair: XML has no entity for it
        '&#x{0:X};' -f $v
    })
}

function Get-GuiNow {
    # Seconds on a clock that only goes forward. Not DateTime: Windows may set the wall clock mid-run - a VM back from a
    # snapshot, a new PC's first time sync - and the window then showed 2830:02 elapsed (superuser's run, 2026-09-29)
    [System.Diagnostics.Stopwatch]::GetTimestamp() / [double][System.Diagnostics.Stopwatch]::Frequency
}

function Get-GuiClock([double]$Seconds) {
    # 0.0, not 0: [math]::Max(0, 3.7) takes the Int32 overload - it rounds 3.7 to 4 first
    $s = [int][math]::Floor([math]::Max(0.0, $Seconds)); '{0:00}:{1:00}' -f [math]::Floor($s / 60), ($s % 60)
}

# ---- building blocks (XAML text). Text handed to New-GuiText is XML already: the callers escape data (ConvertTo-GuiXml).
function New-GuiText {
    param([string]$Text, [string]$Color = $GuiC.tx, [double]$Size = 12.5, [string]$Weight = 'Normal', [string]$Margin = '0', [string]$Extra = '')
    $va = if ($Extra -match 'VerticalAlignment=') { '' } else { "VerticalAlignment='Center'" }
    "<TextBlock Text='$Text' Foreground='$Color' FontSize='$Size' FontWeight='$Weight' Margin='$Margin' $va $Extra/>"
}
function New-GuiGlyph([string]$Code, [double]$Size, [string]$Color, [string]$Margin = '0') {
    "<TextBlock Text='&#x$Code;' FontFamily='$GuiIcons' FontSize='$Size' Foreground='$Color' VerticalAlignment='Center' Margin='$Margin'/>"
}
function New-GuiHover([string]$Normal, [string]$Hover) {
    # a Border's background, lighter under the mouse (a local Background would win over the trigger - so it lives here)
    "<Border.Style><Style TargetType='Border'><Setter Property='Background' Value='$Normal'/><Style.Triggers>" +
        "<Trigger Property='IsMouseOver' Value='True'><Setter Property='Background' Value='$Hover'/></Trigger></Style.Triggers></Style></Border.Style>"
}
function Get-GuiStatusGlyph([string]$Status, [bool]$Warn) {
    if ($Status -eq 'WARN' -or ($Status -eq 'OK' -and $Warn)) { return (New-GuiText '!' $GuiC.warn 13 'Bold') }
    if ($Status -eq 'OK') { return (New-GuiGlyph 'E73E' 11 $GuiC.ok) }
    if ($Status -eq 'FAILED') { return (New-GuiGlyph 'E711' 10 $GuiC.err) }
    return (New-GuiText $GuiDot $GuiC.tx3 14 'Bold')   # SKIPPED / DRYRUN / BACKGROUND
}
function New-GuiButton {
    param([string]$Text, [string]$Tag, [string]$Glyph = '', [string]$Kind = '', [string]$Trail = '')
    $bg = 'Transparent'; $hv = $GuiC.hover; $bd = $GuiC.line2; $fg = $GuiC.tx2; $w = 'Medium'; $fx = ''
    if ($Kind -eq 'primary') {
        $bg = $GuiC.blue; $hv = $GuiC.primary2; $bd = $GuiC.blue; $fg = '#FFFFFF'; $w = 'SemiBold'
        $fx = "<Border.Effect><DropShadowEffect Color='$($GuiC.blue)' BlurRadius='18' ShadowDepth='5' Direction='270' Opacity='0.35'/></Border.Effect>"
    } elseif ($Kind -eq 'danger') { $bg = $GuiC.err16; $hv = $GuiC.err25; $bd = $GuiC.err; $fg = $GuiC.err; $w = 'SemiBold' }
    $g = if ($Glyph) { New-GuiGlyph $Glyph 12 $fg '0,0,7,0' } else { '' }
    $t = if ($Trail) { New-GuiGlyph $Trail 10 $fg '8,0,0,0' } else { '' }
    "<Border Tag='$Tag' Height='32' Padding='14,0' Margin='8,0,0,0' CornerRadius='7' BorderBrush='$bd' BorderThickness='1'>$(New-GuiHover $bg $hv)$fx" +
        "<StackPanel Orientation='Horizontal' IsHitTestVisible='False'>$g$(New-GuiText $Text $fg 12 $w)$t</StackPanel></Border>"
}
function New-GuiSmallButton([string]$Text, [string]$Tag, [switch]$Accent) {
    # a small button in a phase's title line (Deselect all / Select all) - the blue one invites
    $bd = if ($Accent) { $GuiC.blue55 } else { $GuiC.line2 }; $fg = if ($Accent) { $GuiC.blue } else { $GuiC.tx2 }
    $bg = if ($Accent) { $GuiC.blue10 } else { 'Transparent' }; $hv = if ($Accent) { $GuiC.blue18 } else { $GuiC.hover2 }
    "<Border Tag='$Tag' Height='22' Padding='9,0' Margin='12,0,0,0' CornerRadius='6' BorderBrush='$bd' BorderThickness='1' VerticalAlignment='Center'>$(New-GuiHover $bg $hv)" +
        "<StackPanel Orientation='Horizontal' IsHitTestVisible='False'>$(New-GuiText $Text $fg 11.5 'Medium')</StackPanel></Border>"
}
function New-GuiNode {
    # a phase on the rail: its dot (done / warn / fail / live / bg / ask / end / todo), its title, what is on its right,
    # what is under it
    param([string]$Kind, [string]$Title, [string]$Right = '', [string]$Inner = '', [switch]$Last)
    $fill = $GuiC.bg; $stroke = $GuiC.line2; $dash = ''; $fx = ''; $ring = ''
    switch ($Kind) {
        'done' { $fill = $GuiC.ok; $stroke = $GuiC.ok }
        'warn' { $fill = $GuiC.warn; $stroke = $GuiC.warn }
        'fail' { $fill = $GuiC.err; $stroke = $GuiC.err }
        'live' {
            $fill = $GuiC.blue; $stroke = $GuiC.blue
            $fx = "<Ellipse.Effect><DropShadowEffect Color='$($GuiC.blue)' BlurRadius='14' ShadowDepth='0' Opacity='0.9'/></Ellipse.Effect>"
            $ring = "<Ellipse Width='19' Height='19' HorizontalAlignment='Left' VerticalAlignment='Top' Margin='-3,2,0,0' Fill='$($GuiC.blue18)'/>"
        }
        'bg'  { $stroke = $GuiC.blue; $dash = "StrokeDashArray='1.4 1.2'" }
        'ask' { $stroke = $GuiC.blue }
        'end' { $fill = $GuiC.tx; $stroke = $GuiC.tx }
    }
    $line = if ($Last) { '' } else { "<Rectangle Width='1' Fill='$($GuiC.line2)' HorizontalAlignment='Left' Margin='6,14,0,-14'/>" }
    @"
<Grid Margin='0,0,0,12'>
  <Grid.ColumnDefinitions><ColumnDefinition Width='30'/><ColumnDefinition/></Grid.ColumnDefinitions>
  $line$ring
  <Ellipse Width='11' Height='11' HorizontalAlignment='Left' VerticalAlignment='Top' Margin='1,6,0,0' Fill='$fill' Stroke='$stroke' StrokeThickness='1.5' $dash>$fx</Ellipse>
  <StackPanel Grid.Column='1'>
    <DockPanel Height='22' LastChildFill='False'>
      <StackPanel DockPanel.Dock='Left' Orientation='Horizontal'>$Title</StackPanel>
      <StackPanel DockPanel.Dock='Right' Orientation='Horizontal'>$Right</StackPanel>
    </DockPanel>
    $Inner
  </StackPanel>
</Grid>
"@
}
function New-GuiRow {
    # a row under a phase: glyph, name, note, time - the data escaped here
    param([string]$Glyph, [string]$Name, [string]$Note = '', [string]$Time = '', [string]$NameColor = $GuiC.tx, [string]$NoteColor = $GuiC.tx3,
          [string]$Cols = '18,230,*,64', [double]$Size = 12.5, [double]$Height = 22)
    $cd = ($Cols -split ',' | ForEach-Object { "<ColumnDefinition Width='$_'/>" }) -join ''
    "<Grid Height='$Height'><Grid.ColumnDefinitions>$cd</Grid.ColumnDefinitions>$Glyph" +
        (New-GuiText (ConvertTo-GuiXml $Name) $NameColor $Size 'Normal' '0' "Grid.Column='1' TextTrimming='CharacterEllipsis'") +
        (New-GuiText (ConvertTo-GuiXml $Note) $NoteColor $Size 'Normal' '0,0,8,0' "Grid.Column='2' TextTrimming='CharacterEllipsis'") +
        (New-GuiText (ConvertTo-GuiXml $Time) $GuiC.tx2 $Size 'Normal' '0' "Grid.Column='3' HorizontalAlignment='Right'") + '</Grid>'
}
function New-GuiResultRow($R, [double]$Size = 12.5, [double]$Height = 22) {
    # a row the run sent: its glyph, name, what came of it (red when it failed, yellow for a warning), its time
    $noteColor = if ($R.Status -eq 'FAILED') { $GuiC.err } elseif ($R.Status -eq 'WARN' -or $R.Warn) { $GuiC.warn } else { $GuiC.tx3 }
    $nameColor = if ($R.Status -eq 'SKIPPED') { $GuiC.tx3 } else { $GuiC.tx }
    New-GuiRow (Get-GuiStatusGlyph ([string]$R.Status) ([bool]$R.Warn)) ([string]$R.Name) ([string]$R.Text) ([string]$R.Right) $nameColor $noteColor '18,230,*,64' $Size $Height
}
function New-GuiColRow($R) {
    # a row of the two-column app list on Done: glyph, name, its time - or why not / what went wrong
    $why = $R.Status -in 'SKIPPED', 'FAILED' -or $R.Warn
    $right = if ($why) { [string]$R.Text } else { [string]$R.Right }
    $rc = if ($R.Status -eq 'FAILED') { $GuiC.err } elseif ($R.Warn) { $GuiC.warn } elseif ($why) { $GuiC.tx3 } else { $GuiC.tx2 }
    $rs = if ($why) { 10.5 } else { 12 }
    $nc = if ($R.Status -eq 'SKIPPED') { $GuiC.tx3 } else { $GuiC.tx }
    "<Grid Height='20'><Grid.ColumnDefinitions><ColumnDefinition Width='18'/><ColumnDefinition/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>" +
        (Get-GuiStatusGlyph ([string]$R.Status) ([bool]$R.Warn)) +
        (New-GuiText (ConvertTo-GuiXml ([string]$R.Name)) $nc 12 'Normal' '0' "Grid.Column='1' TextTrimming='CharacterEllipsis'") +
        (New-GuiText (ConvertTo-GuiXml $right) $rc $rs 'Normal' '10,0,0,0' "Grid.Column='2' MaxWidth='240' TextTrimming='CharacterEllipsis'") + '</Grid>'
}
function New-GuiLiveRow([string]$Name, [string]$What, [bool]$Clock) {
    # the step running now: highlighted, a sliding bar (LiveBar), its clock (LiveClockText) - Start-GuiMotion and
    # Update-GuiClocks move them between two redraws
    $clk = if ($Clock) { New-GuiText '00:00' $GuiC.blue 12.5 'SemiBold' '0' "x:Name='LiveClockText' Grid.Column='3' HorizontalAlignment='Right'" } else { '' }
    $w = if ($What) { New-GuiText (ConvertTo-GuiXml $What) $GuiC.tx2 12.5 'Normal' '0,0,12,0' "TextTrimming='CharacterEllipsis' MaxWidth='230'" } else { '' }
    @"
<Border Height='28' Margin='-10,2,-10,2' Padding='10,0' CornerRadius='6' BorderBrush='$($GuiC.blue)' BorderThickness='2,0,0,0'>
  <Border.Background><LinearGradientBrush StartPoint='0,0' EndPoint='1,0'><GradientStop Color='$($GuiC.blue16)' Offset='0'/><GradientStop Color='$($GuiC.blue04)' Offset='1'/></LinearGradientBrush></Border.Background>
  <Grid><Grid.ColumnDefinitions><ColumnDefinition Width='18'/><ColumnDefinition Width='230'/><ColumnDefinition/><ColumnDefinition Width='64'/></Grid.ColumnDefinitions>
    $(New-GuiGlyph 'E768' 9 $GuiC.blue)
    $(New-GuiText (ConvertTo-GuiXml $Name) $GuiC.tx 12.5 'Bold' '0' "Grid.Column='1' TextTrimming='CharacterEllipsis'")
    <StackPanel Grid.Column='2' Orientation='Horizontal'>
      $w
      <Border Width='120' Height='3' CornerRadius='2' Background='$($GuiC.blue18)' VerticalAlignment='Center' ClipToBounds='True'>
        <Border x:Name='LiveBar' Width='46' HorizontalAlignment='Left' CornerRadius='2' Background='$($GuiC.blue)'>
          <Border.Effect><DropShadowEffect Color='$($GuiC.blue)' BlurRadius='8' ShadowDepth='0' Opacity='0.9'/></Border.Effect></Border>
      </Border>
    </StackPanel>
    $clk
  </Grid>
</Border>
"@
}
function New-GuiSpinner([double]$Size = 13, [string]$Margin = '0,0,6,0') {
    # an arc that turns (Start-GuiMotion) - one per screen: it is found by its name
    "<Viewbox x:Name='Spin' Width='$Size' Height='$Size' Margin='$Margin' VerticalAlignment='Center'><Canvas Width='24' Height='24'>" +
        "<Path Data='M12,4.5 A7.5,7.5 0 1 1 4.5,12' Stroke='$($GuiC.blue)' StrokeThickness='2.4' StrokeStartLineCap='Round' StrokeEndLineCap='Round'/></Canvas></Viewbox>"
}
function Get-GuiTitleBar($M) {
    # min / close like Windows' own: the glyph in the middle of its 46 px box, the box lit under the mouse, the X white on
    # red (the glyph takes its colour from the box - TextElement.Foreground - so the trigger can change it)
    $cap = { param($glyph, $tag, $hover, $hoverFg)
        "<Border Tag='$tag' Width='46' WindowChrome.IsHitTestVisibleInChrome='True'><Border.Style><Style TargetType='Border'>" +
            "<Setter Property='Background' Value='Transparent'/><Setter Property='TextElement.Foreground' Value='$($GuiC.tx2)'/><Style.Triggers>" +
            "<Trigger Property='IsMouseOver' Value='True'><Setter Property='Background' Value='$hover'/><Setter Property='TextElement.Foreground' Value='$hoverFg'/>" +
            "</Trigger></Style.Triggers></Style></Border.Style>" +
            "<TextBlock Text='&#x$glyph;' FontFamily='$GuiIcons' FontSize='10' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>" }
    $ver = if ($M.Version) { ' ' + (ConvertTo-GuiXml $M.Version) } else { '' }
    @"
<Grid Grid.Row='0' Height='40'>
  <StackPanel Orientation='Horizontal' Margin='14,0,0,0' VerticalAlignment='Center'>
    <Viewbox Width='16' Height='16'><Canvas Width='24' Height='24'>
      <Path Data='M12,2.5 L20.2,7.25 L20.2,16.75 L12,21.5 L3.8,16.75 L3.8,7.25 Z' Fill='#0F1D3A' Stroke='$($GuiC.blue)' StrokeThickness='2' StrokeLineJoin='Round'/>
    </Canvas></Viewbox>
    $(New-GuiText 'MSUHost' $GuiC.tx 12.5 'Bold' '9,0,0,0')
    $(New-GuiText "win11-tweaks$ver" $GuiC.tx3 12.5 'Normal' '9,0,0,0')
  </StackPanel>
  <StackPanel Orientation='Horizontal' HorizontalAlignment='Right'>$(& $cap 'E921' 'cap:min' $GuiC.hover $GuiC.tx)$(& $cap 'E8BB' 'cap:close' $GuiC.close '#FFFFFF')</StackPanel>
</Grid>
"@
}
function Get-GuiHeader([string]$Left, [string]$Right) {
    @"
<Border Grid.Row='1' BorderBrush='$($GuiC.line)' BorderThickness='0,0,0,1' Padding='28,10,28,16'>
  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
    <StackPanel VerticalAlignment='Bottom'>$Left</StackPanel>
    <StackPanel Grid.Column='1' Orientation='Horizontal' VerticalAlignment='Bottom'>$Right</StackPanel>
  </Grid>
</Border>
"@
}
function Get-GuiBody([string]$Inner) {
    "<ScrollViewer x:Name='BodyScroll' Grid.Row='2' VerticalScrollBarVisibility='Auto' HorizontalScrollBarVisibility='Disabled'><StackPanel Margin='20,14,28,4'>$Inner</StackPanel></ScrollViewer>"
}
function Get-GuiFooter([string]$Left, [string]$Right) {
    @"
<Border Grid.Row='3' Height='56' BorderBrush='$($GuiC.line)' BorderThickness='0,1,0,0' Background='$($GuiC.foot)' Padding='28,0,20,0'>
  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
    <Grid VerticalAlignment='Center' Margin='0,0,16,0'>$Left</Grid>
    <StackPanel Grid.Column='1' Orientation='Horizontal' VerticalAlignment='Center'>$Right</StackPanel>
  </Grid>
</Border>
"@
}
function New-GuiTitle([string]$Text, [string]$Color = $GuiC.tx, [string]$Weight = 'Bold') { New-GuiText (ConvertTo-GuiXml $Text) $Color 13 $Weight }
function New-GuiRight([string]$Text) { New-GuiText (ConvertTo-GuiXml $Text) $GuiC.tx3 12 }
function Join-GuiText([object[]]$Parts) { (@($Parts) | Where-Object { $_ }) -join " $([char]0xB7) " }

# ---- the model: what the window shows - changed only by the run's events (Update-GuiModel) and the clicks (Invoke-GuiAction)
function New-GuiModel {
    @{ Screen = 'wait'; WaitText = 'Getting ready'; Setup = $null; Version = ''; Log = ''
       Choice = @{ Machine = 'PC'; Off = @{} }   # the apps taken off the list (key -> $true)
       Banner = @{ Machine = ''; Os = ''; MachineType = ''; User = ''; DryRun = $false }
       Tweaks = @{ State = 'todo'; Rows = [System.Collections.Generic.List[object]]::new(); Progress = $null; Count = 0; Time = '' }
       Apps = @{ State = 'todo'; Rows = [System.Collections.Generic.List[object]]::new(); Plan = @() }
       Net = @{ State = 'todo'; Rows = [System.Collections.Generic.List[object]]::new(); Since = $null }
       Finishing = @{ State = 'todo'; Rows = [System.Collections.Generic.List[object]]::new() }
       Live = $null; Summary = $null; RunStart = $null; ConfirmStop = $false; Stopping = $false; Dirty = $true }
}
function Get-GuiPhase($M, [string]$Name) {
    switch ($Name) { 'Tweaks' { return $M.Tweaks } 'Apps' { return $M.Apps } '.NET 3.5' { return $M.Net } 'Finishing' { return $M.Finishing } }
    return $null
}
function Update-GuiModel($M, $Ev) {
    $M.Dirty = $true
    $now = Get-GuiNow
    switch ([string]$Ev.Type) {
        'setup' {
            $p = $Ev.Payload; $M.Setup = $p; $M.Screen = 'setup'; $M.Version = [string]$p.Version; $M.Log = [string]$p.Log
            $M.Choice.Machine = if ($p.Machine) { [string]$p.Machine } else { 'PC' }   # detected (or -Machine) - shown, not a choice
            $M.Choice.Off = @{}   # everything picked
        }
        'banner' {
            foreach ($k in 'Machine', 'Os', 'MachineType', 'User', 'DryRun') { $M.Banner[$k] = $Ev[$k] }
            if ($Ev.Log) { $M.Log = [string]$Ev.Log }
            $M.Screen = 'run'; if (-not $M.RunStart) { $M.RunStart = $now }
        }
        'phase' {
            foreach ($ph in $M.Tweaks, $M.Apps, $M.Net, $M.Finishing) { if ($ph.State -eq 'live') { $ph.State = 'done' } }
            $ph = Get-GuiPhase $M ([string]$Ev.Name); if ($ph) { $ph.State = 'live' }
            if ($M.Screen -ne 'run') { $M.Screen = 'run' }
            if (-not $M.RunStart) { $M.RunStart = $now }
        }
        'phase-done' {
            $ph = Get-GuiPhase $M ([string]$Ev.Name); if ($ph) { $ph.State = 'done' }
            if ($Ev.Name -eq 'Tweaks') { $M.Tweaks.Count = [int]$Ev.Count; $M.Tweaks.Time = [string]$Ev.Time; $M.Tweaks.Progress = $null }
        }
        'progress' { $M.Tweaks.Progress = @{ Name = [string]$Ev.Name; N = [int]$Ev.N; Total = [int]$Ev.Total } }
        'row'      { $ph = Get-GuiPhase $M ([string]$Ev.Phase); if ($ph) { $ph.Rows.Add($Ev) } }
        'plan'     { $M.Apps.Plan = @($Ev.Apps) }
        'dotnet'   { if ($Ev.State -eq 'running' -and $M.Net.State -eq 'todo') { $M.Net.State = 'running'; $M.Net.Since = $now } }
        'live'     {
            $since = if ($Ev.Since) { [double]$Ev.Since } else { 0 }
            $M.Live = @{ Name = [string]$Ev.Name; What = [string]$Ev.What; Clock = [bool]$Ev.Clock; Started = $now - $since }
        }
        'what'     { if ($M.Live) { $M.Live.What = [string]$Ev.What } }
        'live-end' { $M.Live = $null }
        'summary'  {
            $M.Summary = $Ev; $M.Screen = 'done'; $M.Live = $null; $M.ConfirmStop = $false; $M.Stopping = $false
            # stopped: the phase it was in did not get to its end
            $to = if ($Ev.Finished) { 'done' } else { 'stopped' }
            foreach ($ph in $M.Tweaks, $M.Apps, $M.Net, $M.Finishing) { if ($ph.State -in 'live', 'running') { $ph.State = $to } }
            if ($Ev.Log) { $M.Log = [string]$Ev.Log }
        }
    }
}

# ---- the screens: the header (row 1), the body (row 2), the footer (row 3); Get-GuiXaml adds the title bar and the glow
function Get-GuiKind($Ph) {
    # the dot of a phase that has run: red if something failed, yellow for a warning or a stop, else green
    if ($Ph.State -eq 'todo') { return 'todo' }
    if ($Ph.State -eq 'live') { return 'live' }
    if (@($Ph.Rows | Where-Object { $_.Status -eq 'FAILED' })) { return 'fail' }
    if ($Ph.State -eq 'stopped' -or @($Ph.Rows | Where-Object { $_.Status -eq 'WARN' -or $_.Warn })) { return 'warn' }
    return 'done'
}
function Get-GuiBadRows($Ph) {
    (@($Ph.Rows | Where-Object { $_.Status -in 'WARN', 'FAILED' -or $_.Warn }) | ForEach-Object { New-GuiResultRow $_ }) -join ''
}
function Get-GuiWaitParts($M) {
    (Get-GuiHeader ((New-GuiText 'win11-tweaks' $GuiC.tx 17 'Bold') + (New-GuiText ((ConvertTo-GuiXml $M.WaitText) + $GuiMore) $GuiC.tx3 12 'Normal' '0,3,0,0')) '') +
    "<StackPanel Grid.Row='2' Orientation='Horizontal' VerticalAlignment='Center' HorizontalAlignment='Center'>$(New-GuiSpinner 16 '0,0,10,0')$(New-GuiText ((ConvertTo-GuiXml $M.WaitText) + $GuiMore) $GuiC.tx3 13)</StackPanel>" +
    (Get-GuiFooter '' '')
}
function Get-GuiSetupParts($M) {
    # Set up this PC (superuser, 2026-09-30): one app list, everything picked - take off what you don't want. A row's name
    # takes the whole row off or back on; Deselect all / Select all; the hardware apps found here in their own row.
    $p = $M.Setup; $ch = $M.Choice
    $apps = @($p.Apps | Where-Object { $_ })
    $isOn = { param($a) -not $ch.Off.ContainsKey([string]$a.Key) }
    $on = @($apps | Where-Object { & $isOn $_ }).Count
    $chip = { param($name, $sel, $tag)
        if ($sel) {
            "<Border Tag='$tag' Height='26' Padding='8,0,10,0' Margin='0,0,6,6' CornerRadius='6' BorderBrush='$($GuiC.blue55)' BorderThickness='1'>$(New-GuiHover $GuiC.blue10 $GuiC.blue18)" +
                "<StackPanel Orientation='Horizontal' IsHitTestVisible='False'>$(New-GuiGlyph 'E73E' 10 $GuiC.blue '0,0,6,0')$(New-GuiText (ConvertTo-GuiXml $name) $GuiC.tx 12)</StackPanel></Border>"
        } else {
            "<Border Tag='$tag' Height='26' Padding='8,0,10,0' Margin='0,0,6,6' CornerRadius='6' BorderBrush='$($GuiC.line2)' BorderThickness='1'>$(New-GuiHover 'Transparent' $GuiC.hover2)" +
                "<StackPanel Orientation='Horizontal' IsHitTestVisible='False'><Border Width='10' Height='10' CornerRadius='2' BorderBrush='$($GuiC.line2)' BorderThickness='1.5' Margin='0,0,6,0' VerticalAlignment='Center'/>" +
                "$(New-GuiText (ConvertTo-GuiXml $name) $GuiC.tx3 12)</StackPanel></Border>"
        }
    }
    $box = { param($state)   # the row's own box: all of it on / some / none
        switch ($state) {
            'all'  { "<Border Width='11' Height='11' CornerRadius='3' BorderBrush='$($GuiC.blue55)' Background='$($GuiC.blue18)' BorderThickness='1.5' Margin='0,0,7,0' VerticalAlignment='Center'>$(New-GuiGlyph 'E73E' 7 $GuiC.blue)</Border>" }
            'some' { "<Border Width='11' Height='11' CornerRadius='3' BorderBrush='$($GuiC.blue55)' BorderThickness='1.5' Margin='0,0,7,0' VerticalAlignment='Center'><Rectangle Width='5' Height='1.5' Fill='$($GuiC.blue)' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border>" }
            'none' { "<Border Width='11' Height='11' CornerRadius='3' BorderBrush='$($GuiC.line2)' BorderThickness='1.5' Margin='0,0,7,0' VerticalAlignment='Center'/>" }
            default { "<Border Width='11' Height='11' Margin='0,0,7,0'/>" }
        }
    }
    $row = { param($label, $content, $tag, $state)
        $name = "<StackPanel Orientation='Horizontal' IsHitTestVisible='False'>$(& $box $state)$(New-GuiText (ConvertTo-GuiXml $label) $GuiC.tx3 11.5)</StackPanel>"
        $left = if ($tag) { "<Border Tag='$tag' Height='26' Padding='0,0,8,0' CornerRadius='5' HorizontalAlignment='Left' VerticalAlignment='Top'>$(New-GuiHover 'Transparent' $GuiC.hover2)$name</Border>" }
                else { "<Border Height='26' HorizontalAlignment='Left' VerticalAlignment='Top'>$name</Border>" }
        "<Grid Margin='0,3,0,0'><Grid.ColumnDefinitions><ColumnDefinition Width='170'/><ColumnDefinition/></Grid.ColumnDefinitions>$left<WrapPanel Grid.Column='1'>$content</WrapPanel></Grid>"
    }
    $q = { param($t) (New-GuiText '?' $GuiC.blue 13 'Bold' '0,0,8,0') + (New-GuiTitle $t) }
    $rows = ''
    foreach ($g in @($p.Groups)) {
        $in = @($apps | Where-Object { $_.Group -eq $g }); if (-not $in) { continue }
        $n = @($in | Where-Object { & $isOn $_ }).Count
        $state = if ($n -eq $in.Count) { 'all' } elseif ($n) { 'some' } else { 'none' }
        $chips = (@($in) | ForEach-Object { & $chip ([string]$_.Name) (& $isOn $_) ('app:' + (ConvertTo-GuiXml ([string]$_.Key))) }) -join ''
        $rows += & $row $g $chips ('pick:row:' + (ConvertTo-GuiXml $g)) $state
    }
    $lock = "<StackPanel Orientation='Horizontal' Height='26'>$(New-GuiGlyph 'E72E' 11 $GuiC.tx3 '0,0,7,0')" +
            (New-GuiText ((@($p.Always) | ForEach-Object { ConvertTo-GuiXml ([string]$_) }) -join " $GuiDot ") $GuiC.tx3 12) + '</StackPanel>'
    $rows += & $row 'Always' $lock '' ''
    $toggle = if ($on) { New-GuiSmallButton 'Deselect all' 'pick:apps:none' } else { New-GuiSmallButton 'Select all' 'pick:apps:all' -Accent }
    $right = (New-GuiText "$on" $GuiC.tx 12 'SemiBold') + (New-GuiRight " of $($apps.Count) selected") + $toggle
    $body = New-GuiNode 'ask' (& $q 'Apps') $right $rows -Last
    $foot = @($(if ($apps.Count -and $on -eq $apps.Count) { "all $on apps" } else { "$on apps" }))
    if ($p.TweakCount) { $foot += "$($p.TweakCount) tweaks" }
    $kbd = "<Border BorderBrush='$($GuiC.line2)' BorderThickness='1,1,1,2' CornerRadius='5' Padding='7,1' VerticalAlignment='Center'>$(New-GuiText 'Enter' $GuiC.tx2 11)</Border>"
    $hl = (New-GuiText 'Set up this PC' $GuiC.tx 17 'Bold') + (New-GuiText (ConvertTo-GuiXml (Join-GuiText @($p.PcName, $p.Os, $ch.Machine))) $GuiC.tx3 12 'Normal' '0,3,0,0')
    (Get-GuiHeader $hl ($kbd + (New-GuiText 'to start' $GuiC.tx3 12 'Normal' '10,0,0,0'))) +
    (Get-GuiBody $body) +
    (Get-GuiFooter (New-GuiText (ConvertTo-GuiXml (Join-GuiText $foot)) $GuiC.tx2 12) ((New-GuiButton 'Cancel' 'act:cancel') + (New-GuiButton 'Start' 'act:start' '' 'primary' 'E76C')))
}
function Get-GuiRunParts($M) {
    $b = $M.Banner
    $left = (New-GuiText (ConvertTo-GuiXml ([string]$b.Machine)) $GuiC.tx 17 'Bold') +
            (New-GuiText (ConvertTo-GuiXml (Join-GuiText @($b.Os, $b.MachineType, $b.User))) $GuiC.tx3 12 'Normal' '0,3,0,0') +
            $(if ($b.DryRun) { New-GuiText 'DRY RUN - nothing will be changed' $GuiC.warn 11.5 'SemiBold' '0,3,0,0' } else { '' })
    $right = (New-GuiText '00:00' $GuiC.tx 30 'SemiBold' '0' "x:Name='ElapsedText'") + (New-GuiText 'elapsed' $GuiC.tx3 12 'Normal' '10,0,0,4' "VerticalAlignment='Bottom'")
    # Tweaks: n / N and the tweak now; then its groups (the ones that went wrong as rows)
    $tw = $M.Tweaks; $twBad = @($tw.Rows | Where-Object { $_.Status -in 'WARN', 'FAILED' -or $_.Warn }).Count
    if ($tw.State -eq 'live') {
        $pg = $tw.Progress
        $twRight = if ($pg) { (New-GuiText "$($pg.N)" $GuiC.tx 12 'SemiBold') + (New-GuiRight " / $($pg.Total)") } else { '' }
        $twInner = if ($M.Live) { New-GuiLiveRow $M.Live.Name $M.Live.What $M.Live.Clock } elseif ($pg) { New-GuiLiveRow $pg.Name '' $false } else { '' }
    } elseif ($tw.State -eq 'todo') {
        $twRight = New-GuiRight 'privacy, apps, Start, taskbar, performance'; $twInner = ''
    } else {
        $chips = (@($tw.Rows | Where-Object { $_.Status -in 'OK', 'DRYRUN' -and -not $_.Warn }) | ForEach-Object {
            $g = if ($_.Status -eq 'DRYRUN') { New-GuiText $GuiDot $GuiC.tx3 12 'Bold' '0,0,5,0' } else { New-GuiGlyph 'E73E' 10 $GuiC.ok '0,0,5,0' }
            "<StackPanel Orientation='Horizontal' Margin='0,0,14,4'>$g$(New-GuiText (ConvertTo-GuiXml ([string]$_.Name)) $GuiC.tx2 11.5)</StackPanel>" }) -join ''
        $twInner = "<WrapPanel Margin='0,3,0,2'>$chips</WrapPanel>" + (Get-GuiBadRows $tw)
        $twRight = New-GuiRight (Join-GuiText @($(if ($b.DryRun) { "$($tw.Count) would apply" } else { "$($tw.Count) applied" }), $tw.Time))
    }
    $body = New-GuiNode (Get-GuiKind $tw) (New-GuiTitle 'Tweaks') $twRight $twInner
    # Apps: the last ones done, the one running now, the next ones - and how many more (it has to fit: no scrolling
    # while it runs)
    $ap = $M.Apps; $rows = @($ap.Rows); $plan = @($ap.Plan)
    $live = if ($M.Live -and $ap.State -eq 'live') { $M.Live } else { $null }
    $seen = @{}; foreach ($r in $rows) { $seen[[string]$r.Name] = $true }
    $doneN = @($rows | Where-Object { $plan -contains [string]$_.Name }).Count
    $skipN = @($rows | Where-Object { $_.Status -eq 'SKIPPED' -and $_.Name -ne 'Not selected' }).Count
    if ($ap.State -eq 'live') {
        $queued = @($plan | Where-Object { -not $seen.ContainsKey([string]$_) -and -not ($live -and [string]$_ -eq $live.Name) })
        $budget = 10 - [math]::Min(3, $twBad)
        $tail = [math]::Min($rows.Count, 4); $head = [math]::Max(0, [math]::Min($queued.Count, $budget - $tail))
        $apInner = ''
        if ($tail -gt 0) { $apInner += (@($rows[($rows.Count - $tail)..($rows.Count - 1)]) | ForEach-Object { New-GuiResultRow $_ }) -join '' }
        if ($live) { $apInner += New-GuiLiveRow $live.Name $live.What $live.Clock }
        if ($head -gt 0) { $apInner += (@($queued[0..($head - 1)]) | ForEach-Object { New-GuiRow (New-GuiText $GuiDot $GuiC.line2 14 'Bold') ([string]$_) '' '' $GuiC.tx3 }) -join '' }
        $more = @(); if ($queued.Count -gt $head) { $more += "+ $($queued.Count - $head) more queued" }; if ($skipN) { $more += "$skipN not for this PC" }
        if ($more) { $apInner += New-GuiText (ConvertTo-GuiXml (Join-GuiText $more)) $GuiC.tx3 11.5 'Normal' '18,4,0,0' }
        $apRight = (New-GuiText "$doneN" $GuiC.tx 12 'SemiBold') + (New-GuiRight " / $($plan.Count)")
    } elseif ($ap.State -eq 'todo') {
        $apRight = New-GuiRight 'next'; $apInner = ''
    } else {
        $inst = @($rows | Where-Object { $_.Status -in 'OK', 'DRYRUN' -and $_.Name -ne 'Not selected' }).Count
        $apRight = New-GuiRight (Join-GuiText @("$inst $(if ($b.DryRun) { 'would install' } else { 'installed' })", $(if ($skipN) { "$skipN not for this PC" })))
        $apInner = Get-GuiBadRows $ap
    }
    $body += New-GuiNode (Get-GuiKind $ap) (New-GuiTitle 'Apps') $apRight $apInner
    # .NET 3.5: downloading next to the apps (its own clock), the wait at the end, then its row
    $nt = $M.Net; $ntKind = Get-GuiKind $nt; $ntInner = ''; $ntRight = ''
    switch ($nt.State) {
        'running' {
            $ntKind = 'bg'
            $ntRight = (New-GuiSpinner) + (New-GuiRight "downloading in the background $([char]0xB7) ") + (New-GuiText '00:00' $GuiC.tx2 12 'Normal' '0' "x:Name='NetClockText'")
        }
        'live' {
            $ntInner = (@($nt.Rows) | ForEach-Object { New-GuiResultRow $_ }) -join ''
            if ($M.Live) { $ntInner += New-GuiLiveRow $M.Live.Name $M.Live.What $M.Live.Clock }
        }
        'todo' { $ntRight = New-GuiRight 'after the apps' }
        default {
            $r = @($nt.Rows | Where-Object { $_.Name -eq '.NET 3.5' })[0]
            if ($r) { $ntRight = New-GuiRight (Join-GuiText @($r.Text, $r.Right)) }
            $ntInner = (@($nt.Rows | Where-Object { $_.Name -ne '.NET 3.5' -or $_.Status -eq 'FAILED' }) | ForEach-Object { New-GuiResultRow $_ }) -join ''
        }
    }
    $body += New-GuiNode $ntKind (New-GuiTitle '.NET 3.5') $ntRight $ntInner
    # Finishing: one row each, the step now
    $fn = $M.Finishing
    $fnInner = (@($fn.Rows) | ForEach-Object { New-GuiResultRow $_ }) -join ''
    if ($M.Live -and $fn.State -eq 'live') { $fnInner += New-GuiLiveRow $M.Live.Name $M.Live.What $M.Live.Clock }
    $fnRight = if ($fn.State -eq 'todo') { New-GuiRight "old components $([char]0xB7) monitors $([char]0xB7) VBScript" } else { '' }
    $fnTitle = if ($fn.State -eq 'todo') { New-GuiTitle 'Finishing' $GuiC.tx3 'Medium' } else { New-GuiTitle 'Finishing' }
    $body += New-GuiNode (Get-GuiKind $fn) $fnTitle $fnRight $fnInner -Last
    # the footer: where the run is (Apps is the long one), Log / Stop - Stop asks first
    $seg = { param($ph, $label, $frac, $col)
        $lc = if ($ph.State -eq 'live') { $GuiC.tx } else { $GuiC.tx3 }
        $bar = if ($ph.State -in 'done', 'stopped') { "<Border Height='4' CornerRadius='2' Background='$($GuiC.ok)'/>" }
               elseif ($ph.State -in 'live', 'running') {
                   $f = [math]::Round([math]::Max(0.04, [math]::Min(1.0, $frac)), 3)   # 1.0: Min(1, 0.29) is the Int32 overload = 0
                   "<Border Height='4' CornerRadius='2'><Border.Background><LinearGradientBrush StartPoint='0,0' EndPoint='1,0'><GradientStop Color='$($GuiC.blue)' Offset='0'/>" +
                   "<GradientStop Color='$($GuiC.blue)' Offset='$f'/><GradientStop Color='$($GuiC.line2)' Offset='$f'/><GradientStop Color='$($GuiC.line2)' Offset='1'/></LinearGradientBrush></Border.Background>" +
                   "<Border.Effect><DropShadowEffect Color='$($GuiC.blue)' BlurRadius='10' ShadowDepth='0' Opacity='0.45'/></Border.Effect></Border>"
               } else { "<Border Height='4' CornerRadius='2' Background='$($GuiC.line2)'/>" }
        "<StackPanel Grid.Column='$col' Margin='0,0,6,0'>$bar$(New-GuiText $label $lc 11 'Normal' '0,6,0,0')</StackPanel>"
    }
    $twFrac = if ($tw.Progress) { $tw.Progress.N / [math]::Max(1, $tw.Progress.Total) } else { 0 }
    $apFrac = if ($plan.Count) { $doneN / $plan.Count } else { 0 }
    $apLabel = if ($ap.State -eq 'todo' -or -not $plan.Count) { 'Apps' } else { "Apps $doneN/$($plan.Count)" }
    $segXaml = "<Grid Width='560' HorizontalAlignment='Left'><Grid.ColumnDefinitions><ColumnDefinition Width='1*'/><ColumnDefinition Width='3*'/><ColumnDefinition Width='1*'/><ColumnDefinition Width='1*'/></Grid.ColumnDefinitions>" +
        (& $seg $tw 'Tweaks' $twFrac 0) + (& $seg $ap $apLabel $apFrac 1) + (& $seg $nt '.NET' 0.5 2) + (& $seg $fn 'Finishing' 0.5 3) + '</Grid>'
    $buttons = if ($M.Stopping) { New-GuiText "Stopping after this step$GuiMore" $GuiC.warn 12 'SemiBold' '0,0,8,0' }
               elseif ($M.ConfirmStop) { (New-GuiText 'Stop after this step?' $GuiC.tx 12 'SemiBold' '0,0,4,0') + (New-GuiButton 'Keep going' 'act:stop-no') + (New-GuiButton 'Stop' 'act:stop-yes' 'E71A' 'danger') }
               else { (New-GuiButton 'Log' 'act:log' 'E8A5') + (New-GuiButton 'Stop' 'act:stop') }
    (Get-GuiHeader $left $right) + (Get-GuiBody $body) + (Get-GuiFooter $segXaml $buttons)
}
function Get-GuiDoneParts($M) {
    $s = $M.Summary; $b = $M.Banner
    $left = (New-GuiText (ConvertTo-GuiXml ([string]$s.Head)) $GuiC.tx 17 'Bold') +
            (New-GuiText (ConvertTo-GuiXml (Join-GuiText @($b.Machine, $b.Os))) $GuiC.tx3 12 'Normal' '0,3,0,0')
    # the score: 95 OK . 7 skipped . 0 failed (a warning, "still installing" when there are some)
    $num = { param($n, $label, $color) "<Run Text='$n' FontSize='22' FontWeight='Bold' Foreground='$color'/><Run Text=' $label'/>" }
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($s.DryRun) { $parts.Add((& $num ([int]$s.WouldApply) 'would apply' $GuiC.tx)) } else { $parts.Add((& $num ([int]$s.Ok) 'OK' $GuiC.ok)) }
    if ($s.Skipped) { $parts.Add((& $num ([int]$s.Skipped) 'skipped' $GuiC.tx)) }
    if ($s.Warn) { $parts.Add((& $num ([int]$s.Warn) $(if ($s.Warn -gt 1) { 'warnings' } else { 'warning' }) $GuiC.warn)) }
    if ($s.Background) { $parts.Add((& $num ([int]$s.Background) 'still installing' $GuiC.warn)) }
    $parts.Add((& $num ([int]$s.Failed) 'failed' $(if ($s.Failed) { $GuiC.err } else { $GuiC.tx })))
    $right = "<TextBlock VerticalAlignment='Bottom' FontSize='13' Foreground='$($GuiC.tx2)'>" + ($parts -join "<Run Text=' $GuiDot '/>") + '</TextBlock>'
    $stopped = { param($ph, $text) if ($ph.State -eq 'stopped') { Join-GuiText @($text, 'stopped') } else { $text } }
    # Tweaks
    $tw = $M.Tweaks
    $twText = if ($tw.State -eq 'todo') { 'did not run' } elseif ($tw.Rows.Count) { Join-GuiText @($(if ($b.DryRun) { "$($tw.Count) would apply" } else { "$($tw.Count) applied" }), $tw.Time) } else { '' }
    $body = New-GuiNode (Get-GuiKind $tw) (New-GuiTitle 'Tweaks') (New-GuiRight (& $stopped $tw $twText)) (Get-GuiBadRows $tw)
    # Apps: all of them, in two columns - each with its time, or why not
    $ap = $M.Apps; $rows = @($ap.Rows)
    $inst = @($rows | Where-Object { $_.Status -in 'OK', 'DRYRUN' -and $_.Name -ne 'Not selected' }).Count
    $skipN = @($rows | Where-Object { $_.Status -eq 'SKIPPED' -and $_.Name -ne 'Not selected' }).Count
    $apText = if ($ap.State -eq 'todo') { 'did not run' } else { Join-GuiText @("$inst $(if ($b.DryRun) { 'would install' } else { 'installed' })", $(if ($skipN) { "$skipN not for this PC" })) }
    $apInner = ''
    if ($rows.Count) {
        $half = [math]::Ceiling($rows.Count / 2)
        $colA = (@($rows[0..($half - 1)]) | ForEach-Object { New-GuiColRow $_ }) -join ''
        $colB = if ($rows.Count -gt $half) { (@($rows[$half..($rows.Count - 1)]) | ForEach-Object { New-GuiColRow $_ }) -join '' } else { '' }
        $apInner = "<Grid Margin='0,2,0,0'><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width='28'/><ColumnDefinition/></Grid.ColumnDefinitions>" +
                   "<StackPanel Grid.Column='0'>$colA</StackPanel><StackPanel Grid.Column='2'>$colB</StackPanel></Grid>"
    }
    $body += New-GuiNode (Get-GuiKind $ap) (New-GuiTitle 'Apps') (New-GuiRight (& $stopped $ap $apText)) $apInner
    # .NET 3.5: its one line
    $nt = $M.Net; $r = @($nt.Rows | Where-Object { $_.Name -eq '.NET 3.5' })[0]
    $ntText = if ($r) { Join-GuiText @($r.Text, $r.Right) } elseif ($s.Background) { 'still installing in the background' } elseif ($nt.State -eq 'todo') { 'did not run' } else { '' }
    $ntKind = if ($r) { Get-GuiKind $nt } elseif ($s.Background) { 'bg' } else { Get-GuiKind $nt }
    $ntInner = (@($nt.Rows | Where-Object { $_.Status -in 'WARN', 'FAILED' -and $_.Name -ne '.NET 3.5' }) | ForEach-Object { New-GuiResultRow $_ }) -join ''
    $body += New-GuiNode $ntKind (New-GuiTitle '.NET 3.5') (New-GuiRight $(if ($r) { $ntText } else { & $stopped $nt $ntText })) $ntInner
    # Finishing: one row each
    $fn = $M.Finishing
    $fnInner = (@($fn.Rows) | ForEach-Object { New-GuiResultRow $_ 12 20 }) -join ''
    $body += New-GuiNode (Get-GuiKind $fn) (New-GuiTitle 'Finishing') (New-GuiRight (& $stopped $fn $(if ($fn.State -eq 'todo') { 'did not run' } else { '' }))) $fnInner
    # what went wrong, whole (it may say what to do - or hold a link)
    $probs = @($s.Problems | Where-Object { $_ })
    if ($probs) {
        $pk = if (@($probs | Where-Object { $_.Status -eq 'FAILED' })) { 'fail' } else { 'warn' }
        $pInner = ($probs | ForEach-Object {
            "<Grid Margin='0,1,0,1'><Grid.ColumnDefinitions><ColumnDefinition Width='18'/><ColumnDefinition/></Grid.ColumnDefinitions>" +
            "<Grid Height='18' VerticalAlignment='Top'>$(Get-GuiStatusGlyph ([string]$_.Status) $false)</Grid>" +
            "<TextBlock Grid.Column='1' Text='$(ConvertTo-GuiXml ([string]$_.Text))' Foreground='$($GuiC.tx2)' FontSize='12' TextWrapping='Wrap' LineHeight='18'/></Grid>"
        }) -join ''
        $body += New-GuiNode $pk (New-GuiTitle 'Needs a look') (New-GuiRight "$($probs.Count)") $pInner
    }
    # what now: "Restart the PC to finish." - then why, and anything else
    $next = @($s.Next | Where-Object { $_ }); $first = if ($next.Count) { [string]$next[0] } else { 'Done.' }; $why = @()
    $cut = $first.IndexOf('. ')
    if ($cut -gt 0) { $why += $first.Substring($cut + 2); $first = $first.Substring(0, $cut + 1) }
    if ($next.Count -gt 1) { $why += @($next[1..($next.Count - 1)]) }
    $icon = if ($s.Restart) { New-GuiGlyph 'E72C' 13 $GuiC.tx '0,0,8,0' } else { New-GuiGlyph 'E946' 13 $GuiC.tx '0,0,8,0' }
    $whyXaml = ($why | ForEach-Object { New-GuiText (ConvertTo-GuiXml ([string]$_)) $GuiC.tx3 12 'Normal' '21,0,0,0' "TextWrapping='Wrap'" }) -join ''
    $body += New-GuiNode 'end' ($icon + (New-GuiText (ConvertTo-GuiXml $first) $GuiC.tx 13 'Bold')) '' $whyXaml -Last
    # the footer: the log, Open log / Close / Restart now
    $footLeft = "<StackPanel Orientation='Horizontal'>$(New-GuiGlyph 'E8A5' 12 $GuiC.tx3 '0,0,8,0')" +
                (New-GuiText (ConvertTo-GuiXml ([string]$M.Log)) $GuiC.tx3 12 'Normal' '0' "TextTrimming='CharacterEllipsis'") + '</StackPanel>'
    $buttons = (New-GuiButton 'Open log' 'act:log') +
               $(if ($s.Restart) { (New-GuiButton 'Close' 'act:close') + (New-GuiButton 'Restart now' 'act:restart' 'E72C' 'primary') } else { New-GuiButton 'Close' 'act:close' '' 'primary' })
    (Get-GuiHeader $left $right) + (Get-GuiBody $body) + (Get-GuiFooter $footLeft $buttons)
}
function Get-GuiXaml($M) {
    # the whole window content for the screen the model is on
    $parts = switch ($M.Screen) { 'setup' { Get-GuiSetupParts $M } 'run' { Get-GuiRunParts $M } 'done' { Get-GuiDoneParts $M } default { Get-GuiWaitParts $M } }
    @"
<Border $GuiNs Background='$($GuiC.bg)' BorderBrush='$($GuiC.line)' BorderThickness='1'>
<Grid>
  <Grid.Resources>
    <Style TargetType='ScrollBar'><Setter Property='Width' Value='6'/><Setter Property='MinWidth' Value='6'/><Setter Property='Template'><Setter.Value>
      <ControlTemplate TargetType='ScrollBar'><Track x:Name='PART_Track' IsDirectionReversed='True'><Track.Thumb><Thumb><Thumb.Template>
        <ControlTemplate TargetType='Thumb'><Border CornerRadius='3' Background='$($GuiC.line2)'/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track></ControlTemplate>
    </Setter.Value></Setter></Style>
  </Grid.Resources>
  <Grid.RowDefinitions><RowDefinition Height='40'/><RowDefinition Height='Auto'/><RowDefinition Height='*'/><RowDefinition Height='56'/></Grid.RowDefinitions>
  <Rectangle Grid.RowSpan='4' IsHitTestVisible='False'>
    <Rectangle.Fill><RadialGradientBrush Center='0.18,-0.08' GradientOrigin='0.18,-0.08' RadiusX='0.6' RadiusY='0.45'>
      <GradientStop Color='#293D7BFF' Offset='0'/><GradientStop Color='#003D7BFF' Offset='1'/></RadialGradientBrush></Rectangle.Fill>
  </Rectangle>
  $(Get-GuiTitleBar $M)
  $parts
</Grid>
</Border>
"@
}

# ---- the window itself (WPF). What the handlers need lives in $script: variables - a variable made inside a handler is
# gone by the time the next one runs.
function Invoke-GuiRender {
    # the screen again, from the model: parsed, wired, scrolled back to where it was, its motion and clocks going
    $m = $script:GuiM; $offset = 0
    $old = $script:GuiWin.Content
    if ($old -and $script:GuiScreen -eq $m.Screen) { $sv = $old.FindName('BodyScroll'); if ($sv) { $offset = $sv.VerticalOffset } }
    $content = [Windows.Markup.XamlReader]::Parse((Get-GuiXaml $m))
    $script:GuiWin.Content = $content
    $script:GuiScreen = $m.Screen
    Connect-GuiHandlers $content
    if ($offset -gt 0) { $sv = $content.FindName('BodyScroll'); if ($sv) { $sv.ScrollToVerticalOffset($offset) } }
    Start-GuiMotion $content
    $m.Dirty = $false
    $script:GuiLastRender = Get-GuiNow
    Update-GuiClocks
}
function Start-GuiMotion($Content) {
    # the live bar slides, the spinner turns - WPF animates them; a redraw picks each up where the last one was
    try {
        $t = (Get-GuiNow) - $script:GuiT0
        $bar = $Content.FindName('LiveBar')
        if ($bar) {
            $a = New-Object Windows.Media.Animation.DoubleAnimation(0, 74, (New-Object Windows.Duration([TimeSpan]::FromSeconds(1.1))))
            $a.AutoReverse = $true; $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $a.EasingFunction = New-Object Windows.Media.Animation.SineEase
            $a.BeginTime = [TimeSpan]::FromSeconds(-($t % 2.2))
            $tt = New-Object Windows.Media.TranslateTransform; $bar.RenderTransform = $tt
            $tt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $a)
        }
        $spin = $Content.FindName('Spin')
        if ($spin) {
            $a = New-Object Windows.Media.Animation.DoubleAnimation(0, 360, (New-Object Windows.Duration([TimeSpan]::FromSeconds(1.2))))
            $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $a.BeginTime = [TimeSpan]::FromSeconds(-($t % 1.2))
            $rt = New-Object Windows.Media.RotateTransform; $spin.RenderTransformOrigin = New-Object Windows.Point(0.5, 0.5); $spin.RenderTransform = $rt
            $rt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $a)
        }
    } catch { Add-GuiError "motion: $($_.Exception.Message)" }
}
function Update-GuiClocks {
    $c = $script:GuiWin.Content; $m = $script:GuiM; $now = Get-GuiNow
    if (-not $c) { return }
    $e = $c.FindName('ElapsedText'); if ($e -and $m.RunStart) { $e.Text = Get-GuiClock ($now - $m.RunStart) }
    $l = $c.FindName('LiveClockText'); if ($l -and $m.Live) { $l.Text = Get-GuiClock ($now - $m.Live.Started) }
    $n = $c.FindName('NetClockText'); if ($n -and $m.Net.Since) { $n.Text = Get-GuiClock ($now - $m.Net.Since) }
}
function Connect-GuiHandlers($Root) {
    # every element with an action tag (act: / pick: / app: / cap:) gets the hand cursor and a click
    $stack = [System.Collections.Generic.Stack[object]]::new(); $stack.Push($Root)
    while ($stack.Count) {
        $el = $stack.Pop()
        if ($el -is [Windows.FrameworkElement] -and $el.Tag -is [string] -and $el.Tag -match '^(act|pick|app|cap):') {
            $el.Cursor = [Windows.Input.Cursors]::Hand
            $el.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Invoke-GuiAction ([string]$s.Tag) })
        }
        foreach ($ch in [Windows.LogicalTreeHelper]::GetChildren($el)) { if ($ch -is [Windows.DependencyObject]) { $stack.Push($ch) } }
    }
}
function Add-GuiError([string]$Text) {
    # the window cannot write the log (another thread): the run logs these when it lets the window go (Close-Gui)
    $sh = $script:GuiShared; $sh.ErrorCount = 1 + [int]$sh.ErrorCount; $sh.LastError = $Text
}
function Close-GuiWindowNow { $script:GuiAllowClose = $true; $script:GuiWin.Close() }
function Set-GuiFallbackFont { $script:GuiWin.FontFamily = New-Object Windows.Media.FontFamily('Consolas') }
function Register-GuiRenderFailure {
    # A window that cannot draw fails on every frame (a font file gone from under it, 2026-09-29). 10 failures within
    # 3 s: its text font goes back to Consolas (a Windows font) and it draws again; still failing: the window goes and
    # the console shows the run. Never a black window that cannot even be closed.
    $now = Get-GuiNow
    $script:GuiFailTimes = @(@($script:GuiFailTimes) | Where-Object { $now - $_ -lt 3 }) + @($now)
    if ($script:GuiFailTimes.Count -lt 10) { return }
    $script:GuiFailTimes = @()
    if (-not $script:GuiFontFallback) {
        $script:GuiFontFallback = $true
        Add-GuiError 'the window could not draw - its text font is Consolas now'
        try { Set-GuiFallbackFont; Invoke-GuiRender } catch { }
    } else {
        Add-GuiError 'the window still could not draw - it closed, the console shows the run'
        Close-GuiWindowNow
    }
}
function Add-GuiClick([string]$Tag) {
    # a button pressed, for the run's log (Write-GuiClicks)
    $what = switch ($Tag) {
        'act:start' { 'Start' } 'act:cancel' { 'Cancel' } 'act:log' { 'Log opened' } 'act:close' { 'Close' } 'act:restart' { 'Restart now' }
        'act:stop' { 'Stop pressed - it asks "Stop after this step?"' } 'act:stop-yes' { 'Stop confirmed - stops after this step' }
        'act:stop-no' { 'Keep going' } 'cap:close' { 'the X (close) - during the run it asks to stop' } 'cap:min' { 'minimised' }
        'key:alt-f4' { 'closed from outside the window (Alt+F4, the taskbar, End task) - during the run it asks to stop' }
        'pick:apps:none' { 'Deselect all' } 'pick:apps:all' { 'Select all' } default { $null }
    }
    if ($what -and $script:GuiShared.Clicks) { $script:GuiShared.Clicks.Enqueue(('{0} {1}' -f (Get-Date).ToString('HH:mm:ss'), $what)) }
}
function Invoke-GuiAction([string]$Tag) {
    $m = $script:GuiM; $sh = $script:GuiShared
    Add-GuiClick $Tag
    switch -Regex ($Tag) {
        '^cap:min$'           { $script:GuiWin.WindowState = 'Minimized'; return }
        '^cap:close$'         {
            if ($m.Screen -eq 'run') { if (-not $m.Stopping) { $m.ConfirmStop = $true } }   # the run goes on: close = stop, asked first
            else { if ($m.Screen -eq 'setup' -and -not $sh.Answer) { $sh.Answer = @{ Cancel = $true } }; Close-GuiWindowNow; return }
        }
        '^app:(.+)$'          { $k = $Matches[1]; if ($m.Choice.Off.ContainsKey($k)) { $m.Choice.Off.Remove($k) } else { $m.Choice.Off[$k] = $true } }
        '^pick:row:(.+)$'     {   # a row's name: the whole row off - or, when any of it is off, the whole row back on
            $in = @(@($m.Setup.Apps) | Where-Object { $_ -and $_.Group -eq $Matches[1] })
            $allOn = -not @($in | Where-Object { $m.Choice.Off.ContainsKey([string]$_.Key) }).Count
            foreach ($a in $in) { if ($allOn) { $m.Choice.Off[[string]$a.Key] = $true } else { $m.Choice.Off.Remove([string]$a.Key) } }
        }
        '^pick:apps:none$'    { foreach ($a in @($m.Setup.Apps)) { if ($a) { $m.Choice.Off[[string]$a.Key] = $true } } }
        '^pick:apps:all$'     { $m.Choice.Off = @{} }
        '^act:start$'         {
            if ($m.Screen -ne 'setup' -or $sh.Answer) { return }
            $sh.Answer = @{ Machine = $m.Choice.Machine; Off = @($m.Choice.Off.Keys) }
            $m.Screen = 'wait'; $m.WaitText = 'Starting'
        }
        '^act:cancel$'        { if (-not $sh.Answer) { $sh.Answer = @{ Cancel = $true } }; Close-GuiWindowNow; return }
        '^act:stop$'          { if ($m.Screen -eq 'run' -and -not $m.Stopping) { $m.ConfirmStop = $true } }
        '^act:stop-no$'       { $m.ConfirmStop = $false }
        '^act:stop-yes$'      { if ($m.Screen -eq 'run') { $sh.Stop = $true; $m.ConfirmStop = $false; $m.Stopping = $true } }
        '^act:log$'           { if ($m.Log -and (Test-Path -LiteralPath $m.Log)) { try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $m.Log) } catch { Add-GuiError "log: $($_.Exception.Message)" } }; return }
        '^act:close$'         { Close-GuiWindowNow; return }
        '^act:restart$'       { $sh.Action = 'restart'; Close-GuiWindowNow; return }
    }
    $m.Dirty = $true
    Invoke-GuiRender
}
function Save-GuiSnapshot([string]$Name) {
    # test hook (W11T_GUI_SNAP = a folder): the window content as a 2x PNG, straight from WPF
    $c = $script:GuiWin.Content; if (-not $c -or -not $env:W11T_GUI_SNAP) { return }
    try {
        $c.UpdateLayout()
        $w = [int]($c.ActualWidth * 2); $h = [int]($c.ActualHeight * 2)
        $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, 192, 192, [Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($c)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create((Join-Path $env:W11T_GUI_SNAP "$Name.png")); try { $enc.Save($fs) } finally { $fs.Close() }
    } catch { Add-GuiError "snapshot: $($_.Exception.Message)" }
}
function Invoke-GuiTestHooks {
    # only with the test variables set: W11T_GUI_AUTOSTART (1 = as it is, some = a few apps taken off) presses Start, W11T_GUI_STOP=apps
    # stops the run in its Apps phase, W11T_GUI_SNAP saves the screens as PNGs, W11T_GUI_AUTOCLOSE closes the window at the end
    $m = $script:GuiM; $h = $script:GuiHooks; $now = Get-GuiNow
    if ($env:W11T_GUI_AUTOSTART -and $m.Screen -eq 'setup' -and -not $h.Started) {
        if (-not $h.SetupAt) { $h.SetupAt = $now }
        elseif ($now - $h.SetupAt -gt 1.5) {
            if ($env:W11T_GUI_AUTOSTART -eq 'some') { foreach ($a in @($m.Setup.Apps | Select-Object -First 3)) { if ($a) { $m.Choice.Off[[string]$a.Key] = $true } }; Invoke-GuiRender }
            Save-GuiSnapshot 'setup'; $h.Started = $true; Invoke-GuiAction 'act:start'
        }
    }
    if ($m.Screen -eq 'run' -and -not $h.Running -and (($m.Apps.State -eq 'live' -and $m.Apps.Rows.Count -ge 3) -or $m.Finishing.State -ne 'todo')) {
        if ($m.Dirty) { Invoke-GuiRender }
        Save-GuiSnapshot 'running'; $h.Running = $true
    }
    if ($env:W11T_GUI_STOP -eq 'apps' -and $m.Screen -eq 'run' -and $m.Apps.State -eq 'live' -and -not $h.Stopped) {
        Invoke-GuiAction 'act:stop'; Save-GuiSnapshot 'stop-confirm'; Invoke-GuiAction 'act:stop-yes'; $h.Stopped = $true
    }
    if ($m.Screen -eq 'done' -and -not $h.Done) {
        if (-not $h.DoneAt) { $h.DoneAt = $now }
        elseif ($now - $h.DoneAt -gt 1) {
            Save-GuiSnapshot 'done'; $h.Done = $true
            if ($env:W11T_GUI_AUTOCLOSE) { Invoke-GuiAction 'act:close' }
        }
    }
}
function Show-GuiWindow {
    # The window's thread: build the window, take the run's events ten times a second, redraw what changed (at most
    # every 150 ms). Returns when the window is closed ($Shared.Closed). A window that keeps failing to draw closes
    # itself - the console shows the run then.
    param($Shared)
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $script:GuiShared = $Shared; $script:GuiM = New-GuiModel; $script:GuiAllowClose = $false; $script:GuiHooks = @{}
        $script:GuiLastRender = -1e9; $script:GuiT0 = Get-GuiNow; $script:GuiShown = $false; $script:GuiScreen = ''
        $script:GuiFails = 0; $script:GuiFailTimes = @(); $script:GuiFontFallback = $false
        # the window keeps its Windows frame (a shadow, Windows 11's round corners); WindowChrome draws our own title bar
        # over it - a 1px glass edge is what keeps the shadow
        $script:GuiWin = [Windows.Markup.XamlReader]::Parse(("<Window $GuiNs Title='win11-tweaks' Width='1040' Height='680' ResizeMode='CanMinimize' " +
            "WindowStartupLocation='CenterScreen' Background='$($GuiC.bg)' Topmost='True' UseLayoutRounding='True' SnapsToDevicePixels='True' " +
            "TextOptions.TextFormattingMode='Display' FontFamily='Consolas'><WindowChrome.WindowChrome><WindowChrome CaptionHeight='40' " +
            "ResizeBorderThickness='0' GlassFrameThickness='0,0,0,1' CornerRadius='0' UseAeroCaptionButtons='False'/></WindowChrome.WindowChrome></Window>"))
        # a small screen (a laptop at 150%): the window fits it, the body scrolls
        $wa = [Windows.SystemParameters]::WorkArea
        if ($wa.Height -gt 300 -and $wa.Height - 16 -lt $script:GuiWin.Height) { $script:GuiWin.Height = $wa.Height - 16 }
        if ($wa.Width -gt 600 -and $wa.Width - 16 -lt $script:GuiWin.Width) { $script:GuiWin.Width = $wa.Width - 16 }
        $script:GuiWin.Add_ContentRendered({
            if ($script:GuiShown) { return }
            $script:GuiShown = $true; $script:GuiShared.Ready = $true
            # in front once (Topmost only for the start - the console that started it may hold the foreground)
            try { $null = $script:GuiWin.Activate() } catch { }
            $script:GuiWin.Topmost = $false
        })
        $script:GuiWin.Add_Closing({ param($s, $e)
            if (-not $script:GuiAllowClose -and $script:GuiM.Screen -eq 'run') {   # Alt+F4 while it runs: Stop, asked first
                $e.Cancel = $true; Add-GuiClick 'key:alt-f4'; if (-not $script:GuiM.Stopping) { $script:GuiM.ConfirmStop = $true; Invoke-GuiRender }
            }
        })
        $script:GuiWin.Add_Closed({ $script:GuiShared.Closed = $true; try { $script:GuiTimer.Stop() } catch { } })
        $script:GuiWin.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return' -and $script:GuiM.Screen -eq 'setup') { Invoke-GuiAction 'act:start' } })
        # the text font: our own copy of Cascadia Mono (Start-Gui) - set in code, a file:/// location in XAML would need escaping
        try { $script:GuiWin.FontFamily = New-Object Windows.Media.FontFamily($(if ($Shared.TextFont) { [string]$Shared.TextFont } else { 'Consolas' })) } catch { }
        $script:GuiWin.Dispatcher.Add_UnhandledException({ param($s, $e)
            $e.Handled = $true
            if (-not $script:GuiShared.FirstError) { $script:GuiShared.FirstError = ((($e.Exception.ToString() -split "`r?`n") | Select-Object -First 6) -join ' | ') }
            Add-GuiError "unhandled: $($e.Exception.Message)"
            Register-GuiRenderFailure
        })
        $script:GuiTimer = New-Object Windows.Threading.DispatcherTimer
        $script:GuiTimer.Interval = [TimeSpan]::FromMilliseconds(100)
        $script:GuiTimer.Add_Tick({
            $sh = $script:GuiShared; $m = $script:GuiM
            try {
                if ($sh.CloseRequest) { Close-GuiWindowNow; return }
                $ev = $null; $n = 0
                while ($n -lt 500 -and $sh.Events.TryDequeue([ref]$ev)) { Update-GuiModel $m $ev; $n++ }
                if ($m.Dirty -and (Get-GuiNow) - $script:GuiLastRender -ge 0.15) { Invoke-GuiRender } else { Update-GuiClocks }
                Invoke-GuiTestHooks
                $script:GuiFails = 0
            } catch {
                Add-GuiError $_.Exception.Message
                if (++$script:GuiFails -ge 5) { Add-GuiError "closed after 5 failures in a row: $($_.Exception.Message)"; Close-GuiWindowNow }
            }
        })
        Invoke-GuiRender
        $script:GuiTimer.Start()
        $null = $script:GuiWin.ShowDialog()
    } catch {
        $Shared.Error = $_.Exception.Message
    } finally { $Shared.Closed = $true }
}
'@

# --------------------------------------------------------------------------------------
#  Main
# --------------------------------------------------------------------------------------
try {
    Set-QuickEdit                       # a click into the window must not pause the run (restored in finally)
    if (Test-GuiMode) { Start-Gui }     # the window (no desktop, -Console, -Detailed, or it fails to open: the console rail)
    Show-Intro
    if ($script:Cancelled) { $script:MainEnded = $true; return }   # user answered "n" to Continue
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
    $script:MainEnded = $true
}
catch [System.OperationCanceledException] {
    Write-Log WARN 'Stopped from the window.'   # Stop in the window (Test-GuiStop) - the summary below says what ran
    $script:MainEnded = $true
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
        Clear-StuckSearch   # a stuck Windows Search takes the clicks meant for the Done screen (and the desktop)
    }
    # The Pin-Taskbar helper is normally deleted by the Chrome pin - but not when Chrome was taken off the list
    # or the run was stopped before it. Don't leave it in TEMP.
    if ($script:PinHelper) { Remove-Item $script:PinHelper -Force -ErrorAction SilentlyContinue; $script:PinHelper = $null }
    Set-QuickEdit -Restore
    try { Stop-Transcript | Out-Null } catch { }
    if ($script:SavedPrefs) { $ProgressPreference = $script:SavedPrefs.Progress; $WarningPreference = $script:SavedPrefs.Warning }   # the window's own settings
    # the window: it shows the summary until it is closed (Restart now restarts) - or, cancelled at the start, it goes
    # (the console the relaunch opened goes with it - unless something went wrong: then it shows what)
    if ($script:Gui) {
        $quiet = $script:Relaunched -and $script:MainEnded
        if ($script:RunStarted) { Wait-GuiClose -Quiet:$quiet }
        else {
            $gsh = $script:Gui.Shared
            Close-Gui
            if ($quiet -and $script:Cancelled -and -not $gsh.Error -and -not $gsh.ErrorCount) { $script:ExitWhenDone = $true }
            else { Set-ConsoleWindow -Show; if ($script:Cancelled) { Write-Markup "  {r:Cancelled - nothing was changed.}" } }
        }
    }
    if (-not $script:ExitWhenDone) { Set-ConsoleWindow -Show }   # whatever happened: never leave the console hidden
    # HERE, not after the finally: Cancel leaves Main with `return`, and that skips everything after it (no -Reboot
    # with the window, so nothing is lost)
    if ($script:ExitWhenDone) { Exit-Console }
}
if ($script:RunFinished -and $Reboot -and -not $script:DryRun) {
    Write-Log WARN "Rebooting in 15s (-Reboot given). Press Ctrl+C to cancel."
    Write-Ui "     {y:$($script:G.Run)} Restarting in 15 s (-Reboot) - Ctrl+C cancels."
    Start-Sleep -Seconds 15
    Restart-Computer -Force
}
