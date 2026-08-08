<#
================================================================================
 Claude Code sound alerts - one-shot installer (Windows / PowerShell)
================================================================================

 WHAT IT DOES
   Makes Claude Code play a sound when it:
     - finishes a turn                      (soft chime)
     - needs your input or permission       (alert + tray popup)
     - hits your usage limit                (alarm + tray popup)
     - dies on any other API error          (alarm + tray popup)

 HOW TO RUN
   Open PowerShell and paste:

     irm https://raw.githubusercontent.com/azyzex/ClaudeCodeSounds/main/install-claude-sound-alerts.ps1 | iex

   Or save this file and run:

     powershell -ExecutionPolicy Bypass -File .\install-claude-sound-alerts.ps1

 WHAT IT TOUCHES
   ~/.claude/claude-notify.ps1     created / overwritten
   ~/.claude/claude-notify.conf    created if absent, never overwritten
   ~/.claude/settings.json         backed up, then five hook entries added

 SAFE TO RE-RUN. It replaces its own hook entries and leaves everything
 else in settings.json alone. Your options file is left alone too.

 OPTIONS
   -Configure    change the options without reinstalling
   -Uninstall    remove the hooks and the notifier
   $env:NONINTERACTIVE = '1'   never prompt, just take the defaults
================================================================================
#>

[CmdletBinding()]
param([switch]$Uninstall, [switch]$Configure)

$ErrorActionPreference = 'Stop'

$claudeDir    = Join-Path $env:USERPROFILE '.claude'
$notifyScript = Join-Path $claudeDir 'claude-notify.ps1'
$confFile     = Join-Path $claudeDir 'claude-notify.conf'
$settingsPath = Join-Path $claudeDir 'settings.json'
$marker       = 'claude-notify.ps1'   # how we recognise our own hook entries

function Write-Step($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  $msg" -ForegroundColor Green }
function Write-Dim($msg)  { Write-Host "  $msg" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "Claude Code sound alerts" -ForegroundColor White
Write-Host "------------------------"

# ------------------------------------------------------------------ helpers ---

# PowerShell 5.1's ConvertFrom-Json has no -AsHashtable, so convert by hand.
function ConvertTo-Hashtable {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) {
            $h[$p.Name] = ConvertTo-Hashtable $p.Value
        }
        return $h
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @( $InputObject | ForEach-Object { ConvertTo-Hashtable $_ } )
    }

    return $InputObject
}

# Write JSON without a UTF-8 BOM. Some parsers choke on the BOM.
function Save-Json {
    param([hashtable]$Data, [string]$Path)
    $json = $Data | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# Does this hook group belong to us?
function Test-IsOurs {
    param($Group)
    try { return (($Group | ConvertTo-Json -Depth 20 -Compress) -like "*$marker*") }
    catch { return $false }
}

# Strip our entries out of one event, keep everyone else's.
function Remove-OurHooks {
    param($Existing)
    if ($null -eq $Existing) { return @() }
    return @( @($Existing) | Where-Object { -not (Test-IsOurs $_) } )
}

function New-HookGroup {
    param([string]$Kind, [string]$Matcher)

    $handler = @{
        type    = 'command'
        command = 'powershell.exe'
        args    = @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-Command'
            "& `"`$env:USERPROFILE\.claude\$marker`" -Kind $Kind"
        )
        async   = $true
        timeout = 30
    }

    $group = @{ hooks = @($handler) }
    if ($Matcher) { $group['matcher'] = $Matcher }
    return $group
}

# ------------------------------------------------------------------ options ---
# Defaults, overridden by anything already in the config file, then by the
# interactive picker. Same file, same key names as the Linux and macOS version.
$opt = [ordered]@{
    MIN_SECONDS           = '30'
    SUPPRESS_WHEN_FOCUSED = '1'
    PROJECT_PITCH         = '1'
    SPEAK                 = '0'
    TOAST_ON_DONE         = '0'
    DEBOUNCE_SECONDS      = '2'
    ALWAYS_ALERT          = 'blocked,limit,error'
    MUTE                  = ''
    QUIET_HOURS           = ''
    DONE_VOLUME           = '70'
    BLOCKED_VOLUME        = '100'
    LIMIT_VOLUME          = '100'
    ERROR_VOLUME          = '100'
}

# Read a KEY=value out of the config file. Parsed, never invoked, so a stray
# expression in someone's config file cannot execute.
function Read-Conf {
    if (-not (Test-Path $confFile)) { return }
    foreach ($line in (Get-Content $confFile)) {
        if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') {
            $k = $matches[1]
            if ($opt.Contains($k)) { $opt[$k] = $matches[2] }
        }
    }
}
Read-Conf

# Prompt only when there is a real console to prompt on. Piping the script
# through `irm | iex` under automation, and CI capturing stdout, both correctly
# fall through to the defaults instead of hanging.
function Test-CanPrompt {
    if ($env:NONINTERACTIVE -eq '1') { return $false }
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        if ([Console]::IsInputRedirected)  { return $false }
        return [Environment]::UserInteractive
    } catch { return $false }
}

function Read-YesNo {
    param([string]$Prompt, [string]$Current)
    $hint = if ($Current -eq '1') { 'Y/n' } else { 'y/N' }
    $reply = Read-Host "  $Prompt [$hint]"
    switch -Regex ($reply) {
        '^[Yy]' { return '1' }
        '^[Nn]' { return '0' }
        default { return $Current }
    }
}

function Read-Number {
    param([string]$Prompt, [string]$Current)
    $reply = Read-Host "  $Prompt [$Current]"
    if ($reply -match '^\d+$') { return $reply }
    return $Current
}

function Select-Options {
    Write-Host ""
    Write-Step "Options. Press enter to keep the value in brackets."
    Write-Host ""
    Write-Dim "Every one of these can be changed later by editing"
    Write-Dim "$confFile"
    Write-Dim "or by re-running this script with -Configure. No reinstall needed."
    Write-Host ""

    $opt['MIN_SECONDS']           = Read-Number "Stay quiet if a turn finished in under N seconds (0 = always chime)" $opt['MIN_SECONDS']
    $opt['SUPPRESS_WHEN_FOCUSED'] = Read-YesNo  "Skip the sound when the terminal is already focused?"               $opt['SUPPRESS_WHEN_FOCUSED']
    $opt['PROJECT_PITCH']         = Read-YesNo  "Use a different finish sound per project?"                          $opt['PROJECT_PITCH']
    $opt['SPEAK']                 = Read-YesNo  "Read the alert aloud instead of playing a sound?"                   $opt['SPEAK']
    $opt['TOAST_ON_DONE']         = Read-YesNo  "Also show a tray popup when a turn just finishes?"                  $opt['TOAST_ON_DONE']
    Write-Host ""
}

function Save-Conf {
    $text = @"
# Claude Code sound alerts - options
#
# Edit a value and save. The notifier re-reads this file on every alert, so
# changes take effect immediately with no reinstall and no restart. Delete a
# line to go back to its default. Re-run the installer with -Configure to be
# walked through these again.

# Stay silent when a turn finished faster than this many seconds. Short
# back-and-forth turns are the main source of alert fatigue. 0 = always alert.
MIN_SECONDS=$($opt['MIN_SECONDS'])

# Skip the alert when the terminal is already the focused window, on the basis
# that you are evidently already looking at it.
SUPPRESS_WHEN_FOCUSED=$($opt['SUPPRESS_WHEN_FOCUSED'])

# Pick the "finished" sound from the working directory, so with several
# terminals open you can tell which project it was.
PROJECT_PITCH=$($opt['PROJECT_PITCH'])

# Read the alert aloud instead of playing a sound file.
SPEAK=$($opt['SPEAK'])

# Also raise a tray popup when a turn merely finishes, not just when something
# needs you.
TOAST_ON_DONE=$($opt['TOAST_ON_DONE'])

# Ignore repeat alerts for this many seconds, so overlapping events do not
# stutter over each other.
DEBOUNCE_SECONDS=$($opt['DEBOUNCE_SECONDS'])

# Alert kinds that ignore MIN_SECONDS and the focus check, because you want to
# know regardless. Comma separated, from: done blocked limit error
ALWAYS_ALERT=$($opt['ALWAYS_ALERT'])

# Alert kinds to silence completely. Comma separated, same names as above.
MUTE=$($opt['MUTE'])

# Stay silent inside this window, for example 23:00-08:00. Windows that wrap
# past midnight work. Leave empty to disable.
QUIET_HOURS=$($opt['QUIET_HOURS'])

# ---------------------------------------------------------------------------
# Per-event settings. One group per alert kind.
#
#   _ENABLED  0 turns this kind off completely
#   _VOLUME   0-100. Below 100 plays through MediaPlayer instead of SoundPlayer,
#             because SoundPlayer has no volume control
#   _PATTERN  how many times to play, optionally NxMS for the gap in
#             milliseconds. "3x140" is three pulses 140ms apart. Rhythm carries
#             further than pitch when you are not paying attention
#   _SOUND    full path to your own .wav, overriding the built-in choice
# ---------------------------------------------------------------------------

DONE_ENABLED=1
DONE_VOLUME=$($opt['DONE_VOLUME'])
DONE_PATTERN=1
DONE_SOUND=

BLOCKED_ENABLED=1
BLOCKED_VOLUME=$($opt['BLOCKED_VOLUME'])
BLOCKED_PATTERN=2
BLOCKED_SOUND=

LIMIT_ENABLED=1
LIMIT_VOLUME=$($opt['LIMIT_VOLUME'])
LIMIT_PATTERN=3x140
LIMIT_SOUND=

ERROR_ENABLED=1
ERROR_VOLUME=$($opt['ERROR_VOLUME'])
ERROR_PATTERN=2
ERROR_SOUND=
"@
    [System.IO.File]::WriteAllText($confFile, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# ----------------------------------------------------------------- settings ---

if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
    Write-Step "created $claudeDir"
}

if ($Configure) {
    if (-not (Test-CanPrompt)) {
        Write-Host "  -Configure needs a console. Edit $confFile directly instead." -ForegroundColor Red
        exit 1
    }
    Select-Options
    Save-Conf
    Write-Ok "saved $confFile"
    Write-Dim "Takes effect on the next alert. No restart needed."
    Write-Host ""
    exit 0
}

if (-not $Uninstall) {
    if (Test-Path $confFile) {
        Write-Step "keeping your existing options in claude-notify.conf"
        Write-Dim "run with -Configure to change them"
    } elseif (Test-CanPrompt) {
        Select-Options
        Save-Conf
        Write-Ok "wrote claude-notify.conf"
    } else {
        Save-Conf
        Write-Step "wrote claude-notify.conf with defaults"
        Write-Dim "no console to prompt on; run with -Configure to choose options"
    }
}

$settings = @{}
if (Test-Path $settingsPath) {
    $raw = Get-Content $settingsPath -Raw
    if ($raw -and $raw.Trim()) {
        try   { $settings = ConvertTo-Hashtable (ConvertFrom-Json $raw) }
        catch { throw "settings.json is not valid JSON. Fix or move it, then re-run. ($_)" }
    }
    $backup = "$settingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $settingsPath $backup
    Write-Step "backed up settings.json -> $(Split-Path $backup -Leaf)"
}

if (-not ($settings -is [hashtable])) { $settings = @{} }
if (-not $settings.ContainsKey('hooks') -or -not ($settings['hooks'] -is [hashtable])) {
    $settings['hooks'] = @{}
}
$hooks = $settings['hooks']

# Matcher values come from the hooks reference: code.claude.com/docs/en/hooks
#
# UserPromptSubmit only records a start time, so the Stop hook can tell a
# ten-minute turn from a four-second one. It plays nothing.
$wiring = @(
    @{ Event = 'UserPromptSubmit'; Kind = 'mark';    Matcher = $null }
    @{ Event = 'Stop';             Kind = 'done';    Matcher = $null }
    @{ Event = 'Notification';     Kind = 'blocked'; Matcher = 'permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog' }
    @{ Event = 'StopFailure';      Kind = 'limit';   Matcher = 'rate_limit' }
    @{ Event = 'StopFailure';      Kind = 'error';   Matcher = 'overloaded|authentication_failed|oauth_org_not_allowed|billing_error|invalid_request|model_not_found|server_error|max_output_tokens|unknown' }
)

# Clear our old entries first, so re-running never stacks duplicates.
# Elicitation is in the list only to clean up: earlier setups wired it directly,
# but Notification already covers it via the elicitation_dialog matcher.
$ourEvents = @('UserPromptSubmit', 'Stop', 'Notification', 'StopFailure', 'Elicitation')

foreach ($evt in $ourEvents) {
    if ($hooks.ContainsKey($evt)) { $hooks[$evt] = Remove-OurHooks $hooks[$evt] }
}

if ($Uninstall) {
    foreach ($evt in $ourEvents) {
        if ($hooks.ContainsKey($evt) -and @($hooks[$evt]).Count -eq 0) { $hooks.Remove($evt) }
    }
    if ($hooks.Count -eq 0) { $settings.Remove('hooks') }
    Save-Json -Data $settings -Path $settingsPath
    if (Test-Path $notifyScript) { Remove-Item $notifyScript -Force }
    Write-Ok "removed. restart Claude Code."
    Write-Dim "left claude-notify.conf in place, in case you reinstall"
    Write-Host ""
    return
}

foreach ($w in $wiring) {
    $existing = @()
    if ($hooks.ContainsKey($w.Event)) { $existing = @($hooks[$w.Event]) }
    $hooks[$w.Event] = @( $existing + (New-HookGroup -Kind $w.Kind -Matcher $w.Matcher) )
}

# Don't leave "Elicitation": [] behind after the cleanup pass above.
foreach ($evt in @($hooks.Keys)) {
    if (@($hooks[$evt]).Count -eq 0) { $hooks.Remove($evt) }
}

Save-Json -Data $settings -Path $settingsPath
Write-Ok "wired 5 hooks into settings.json"

# ------------------------------------------------------- the notifier script ---

$notifyBody = @'
#requires -version 5
<#
  Claude Code notifier. Called by the hooks in ~/.claude/settings.json.

    -Kind mark     a turn started    records the time, plays nothing
    -Kind done     turn finished     sound
    -Kind blocked  waiting on you    sound + tray popup
    -Kind limit    usage limit hit   sound + tray popup
    -Kind error    other API error   sound + tray popup

  Options live in ~/.claude/claude-notify.conf and are re-read on every call,
  so edits take effect immediately. Set CLAUDE_NOTIFY_DEBUG=1 to print the
  decision instead of staying silent.
#>
param([ValidateSet('mark','done','blocked','limit','error')][string]$Kind = 'done')

$ErrorActionPreference = 'SilentlyContinue'

$confFile = Join-Path $env:USERPROFILE '.claude\claude-notify.conf'
$debug    = ($env:CLAUDE_NOTIFY_DEBUG -eq '1')

# --- options ------------------------------------------------------------------
# Parsed with a regex, never invoked, so nothing in the file can execute.
$opt = @{
    MIN_SECONDS           = '30'
    SUPPRESS_WHEN_FOCUSED = '1'
    PROJECT_PITCH         = '1'
    SPEAK                 = '0'
    TOAST_ON_DONE         = '0'
    DEBOUNCE_SECONDS      = '2'
    ALWAYS_ALERT          = 'blocked,limit,error'
    MUTE                  = ''
    QUIET_HOURS           = ''

    # Per-event, keyed by the uppercased kind. Flat keys rather than sections,
    # so the parser stays one regex and a v1.1.0 config keeps working untouched.
    DONE_ENABLED    = '1'; DONE_VOLUME    = '70';  DONE_PATTERN    = '1';     DONE_SOUND    = ''
    BLOCKED_ENABLED = '1'; BLOCKED_VOLUME = '100'; BLOCKED_PATTERN = '2';     BLOCKED_SOUND = ''
    LIMIT_ENABLED   = '1'; LIMIT_VOLUME   = '100'; LIMIT_PATTERN   = '3x140'; LIMIT_SOUND   = ''
    ERROR_ENABLED   = '1'; ERROR_VOLUME   = '100'; ERROR_PATTERN   = '2';     ERROR_SOUND   = ''
}
if (Test-Path $confFile) {
    foreach ($line in (Get-Content $confFile)) {
        if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') {
            if ($opt.ContainsKey($matches[1])) { $opt[$matches[1]] = $matches[2] }
        }
    }
}

# Resolve the per-event options for this kind.
$ev        = $Kind.ToUpperInvariant()
$evEnabled = $opt["${ev}_ENABLED"]
$evSound   = $opt["${ev}_SOUND"]
$evVolume  = 100
if ($opt["${ev}_VOLUME"] -match '^\d+$') { $evVolume = [int]$opt["${ev}_VOLUME"] }
if ($evVolume -gt 100) { $evVolume = 100 }

# How many times to play, and how far apart. "2" means twice at the default
# spacing; "3x120" means three times, 120ms apart. Rhythm carries further than
# pitch when you are not paying attention.
$repeatCount = 1
$repeatGap   = 220
if ($opt["${ev}_PATTERN"] -match '^(\d+)(?:x(\d+))?$') {
    $repeatCount = [int]$matches[1]
    if ($matches[2]) { $repeatGap = [int]$matches[2] }
}
if ($repeatCount -lt 1) { $repeatCount = 1 }
if ($repeatCount -gt 6) { $repeatCount = 6 }

function Get-IntOpt {
    param([string]$Name, [int]$Default)
    $v = $opt[$Name]
    if ($v -match '^\d+$') { return [int]$v }
    return $Default
}

$minSeconds = Get-IntOpt 'MIN_SECONDS' 30
$debounce   = Get-IntOpt 'DEBOUNCE_SECONDS' 2

function Test-InList {
    param([string]$Needle, [string]$List)
    if (-not $List) { return $false }
    return (($List -split ',' | ForEach-Object { $_.Trim() }) -contains $Needle)
}

function Write-Decision {
    param([string]$Text)
    if ($debug) { Write-Output $Text }
}

# --- read the hook payload ----------------------------------------------------
# Claude Code sends the event JSON on stdin. Every event carries session_id and
# cwd; Notification carries message.
$detail = ''; $session = ''; $cwd = ''
try {
    if ([Console]::IsInputRedirected) {
        $stdin = [Console]::In.ReadToEnd()
        if ($stdin -and $stdin.Trim()) {
            $obj = ConvertFrom-Json $stdin
            foreach ($f in 'message','reason','error_type','last_assistant_message') {
                if (-not $detail -and $obj.$f) { $detail = [string]$obj.$f }
            }
            if ($obj.session_id) { $session = [string]$obj.session_id }
            if ($obj.cwd)        { $cwd     = [string]$obj.cwd }
        }
    }
} catch { }
if (-not $session) { $session = 'nosession' }

$safeSession = ($session -replace '[^A-Za-z0-9_-]', '_')
$startFile   = Join-Path $env:TEMP "claude-notify-start.$safeSession"

# --- mark: a turn began -------------------------------------------------------
# This is the whole job of the UserPromptSubmit hook. No sound, no popup.
if ($Kind -eq 'mark') {
    try { [System.IO.File]::WriteAllText($startFile, [string][int][double]::Parse((Get-Date -UFormat %s))) } catch { }
    Write-Decision "kind=mark session=$session"
    exit 0
}

# --- muted? -------------------------------------------------------------------
if ((Test-InList $Kind $opt['MUTE']) -or $evEnabled -eq '0') {
    Write-Decision "kind=$Kind suppressed=muted"
    exit 0
}

# --- quiet hours? -------------------------------------------------------------
# QUIET_HOURS=23:00-08:00, and windows that wrap past midnight are handled.
# This lives in the config rather than in a resident process, so it works
# whether or not anything else is running.
if ($opt['QUIET_HOURS'] -match '^\s*(\d{1,2}):?(\d{2})\s*-\s*(\d{1,2}):?(\d{2})\s*$') {
    $from = [int]$matches[1] * 60 + [int]$matches[2]
    $to   = [int]$matches[3] * 60 + [int]$matches[4]
    $now  = (Get-Date).Hour * 60 + (Get-Date).Minute
    $quiet = if ($from -le $to) { $now -ge $from -and $now -lt $to }
             else { $now -ge $from -or $now -lt $to }   # wraps midnight
    if ($quiet) {
        Write-Decision "kind=$Kind suppressed=quiet-hours window=$($opt['QUIET_HOURS'])"
        exit 0
    }
}

# Kinds you always want to hear about ignore the elapsed and focus checks.
$always = Test-InList $Kind $opt['ALWAYS_ALERT']

# --- too quick to care? -------------------------------------------------------
$elapsed = $null
if (Test-Path $startFile) {
    try {
        $started = [int](Get-Content $startFile -Raw).Trim()
        $now     = [int][double]::Parse((Get-Date -UFormat %s))
        $elapsed = $now - $started
    } catch { $elapsed = $null }
    Remove-Item $startFile -Force -ErrorAction SilentlyContinue
}
if (-not $always -and $minSeconds -gt 0 -and $null -ne $elapsed -and $elapsed -lt $minSeconds) {
    Write-Decision "kind=$Kind suppressed=too-quick elapsed=$elapsed min=$minSeconds"
    exit 0
}

# --- already looking at it? ---------------------------------------------------
# Compares the foreground window's process against this process's ancestry, so
# it answers "is my terminal in front", not merely "is a terminal in front".
# Any uncertainty resolves to "not focused", so the failure mode is an alert you
# did not strictly need rather than a missed one.
function Test-Focused {
    try {
        if (-not ('ClaudeNotifyFg' -as [type])) {
            Add-Type -Namespace '' -Name 'ClaudeNotifyFg' -MemberDefinition @"
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr hWnd, out int pid);
"@
        }
        $hwnd = [ClaudeNotifyFg]::GetForegroundWindow()
        if ($hwnd -eq [System.IntPtr]::Zero) { return $false }
        $fgPid = 0
        [void][ClaudeNotifyFg]::GetWindowThreadProcessId($hwnd, [ref]$fgPid)
        if (-not $fgPid) { return $false }

        # Walk our own ancestry. The notifier's parents reach the terminal.
        $walk = $PID
        for ($i = 0; $i -lt 8; $i++) {
            if ($walk -eq $fgPid) { return $true }
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$walk" -ErrorAction Stop
            if (-not $proc -or -not $proc.ParentProcessId) { break }
            $walk = [int]$proc.ParentProcessId
            if ($walk -le 4) { break }
        }
        return $false
    } catch { return $false }
}

if (-not $always -and $opt['SUPPRESS_WHEN_FOCUSED'] -eq '1' -and (Test-Focused)) {
    Write-Decision "kind=$Kind suppressed=focused"
    exit 0
}

# --- debounce -----------------------------------------------------------------
# Several of these events can fire inside the same second. Without this you get
# a stutter of overlapping audio.
$stamp = Join-Path $env:TEMP 'claude-notify.last'
if (Test-Path $stamp) {
    if (((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalSeconds -lt $debounce) {
        Write-Decision "kind=$Kind suppressed=debounced"
        exit 0
    }
}
Set-Content -Path $stamp -Value $Kind -Encoding ascii

# --- pick sound and text ------------------------------------------------------
# 'limit' and 'error' must not share a first choice, or splitting rate_limit out
# of StopFailure buys nothing audible.
switch ($Kind) {
    'blocked' {
        $wavs     = @('Windows Exclamation.wav','Windows Notify Messaging.wav','chord.wav')
        $title    = 'Claude needs you'
        $fallback = 'Waiting on your input or a permission prompt'
        $icon     = 'Warning'; $freq = 740
    }
    'limit' {
        $wavs     = @('Windows Critical Stop.wav','Windows Battery Critical.wav','chord.wav')
        $title    = 'Claude hit the usage limit'
        $fallback = 'Rate limited. The turn ended early.'
        $icon     = 'Error'; $freq = 440
    }
    'error' {
        $wavs     = @('Windows Hardware Fail.wav','Windows Foreground.wav','Windows Error.wav','chimes.wav')
        $title    = 'Claude stopped'
        $fallback = 'The turn ended on an API error'
        $icon     = 'Error'; $freq = 494
    }
    default {
        # Several interchangeable chimes, so PROJECT_PITCH has something to
        # choose between. The first is the default when that option is off.
        $wavs     = @('Windows Notify System Generic.wav','notify.wav','Windows Ding.wav','chimes.wav','Windows Balloon.wav','Windows Notify.wav')
        $title    = 'Claude is done'
        $fallback = 'Turn finished'
        $icon     = 'Info'; $freq = 988
    }
}
if (-not $detail) { $detail = $fallback }
if ($detail.Length -gt 180) { $detail = $detail.Substring(0,177) + '...' }

# Turn the project directory into a stable index, so the same project always
# gets the same chime.
if ($opt['PROJECT_PITCH'] -eq '1' -and $Kind -eq 'done' -and $cwd) {
    $hash = 0
    foreach ($ch in $cwd.ToCharArray()) { $hash = ($hash * 31 + [int]$ch) % 100000 }
    $shift = $hash % $wavs.Count
    if ($shift -gt 0) { $wavs = $wavs[$shift..($wavs.Count-1)] + $wavs[0..($shift-1)] }
}

# --- play ---------------------------------------------------------------------
$playerUsed = ''
$soundPath  = ''
$dryRun     = ($env:CLAUDE_NOTIFY_DRYRUN -eq '1')

if ($opt['SPEAK'] -eq '1' -and -not $dryRun) {
    try {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $synth.Speak("$title. $detail")
        $synth.Dispose()
        $playerUsed = 'speech'
    } catch { }
}

if (-not $playerUsed) {
    # An explicit per-event file wins over the candidate list, so a kind can be
    # pointed at your own sound without editing this script.
    if ($evSound -and (Test-Path $evSound)) {
        $soundPath = $evSound
    } else {
        foreach ($w in $wavs) {
            $p = Join-Path $env:SystemRoot "Media\$w"
            if (Test-Path $p) { $soundPath = $p; break }
        }
    }
}

# SoundPlayer has no volume control at all, so anything other than full volume
# has to go through MediaPlayer. MediaPlayer is asynchronous and needs the file
# opened before its duration is known, hence the bounded waits: a notifier must
# never hang a hook.
function Invoke-PlayOnce {
    param([string]$Path, [int]$VolumePercent)

    if ($VolumePercent -ge 100) {
        $sp = New-Object System.Media.SoundPlayer $Path
        $sp.PlaySync()
        return 'SoundPlayer'
    }

    Add-Type -AssemblyName PresentationCore
    $mp = New-Object System.Windows.Media.MediaPlayer
    try {
        $mp.Open([uri]$Path)
        $mp.Volume = [double]$VolumePercent / 100.0
        $waited = 0
        while (-not $mp.NaturalDuration.HasTimeSpan -and $waited -lt 2000) {
            Start-Sleep -Milliseconds 25; $waited += 25
        }
        $mp.Play()
        $ms = 400
        if ($mp.NaturalDuration.HasTimeSpan) {
            $ms = [int]$mp.NaturalDuration.TimeSpan.TotalMilliseconds
        }
        if ($ms -gt 10000) { $ms = 10000 }
        Start-Sleep -Milliseconds $ms
        return 'MediaPlayer'
    } finally {
        $mp.Close()
    }
}

if ($dryRun) {
    # Resolve everything and report it, but make no sound and raise no popup.
    # Used by the tests, and by anything that wants to know what would happen
    # without actually interrupting the user.
    $playerUsed = 'dryrun'
} elseif ($soundPath) {
    for ($i = 0; $i -lt $repeatCount; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds $repeatGap }
        try { $playerUsed = Invoke-PlayOnce -Path $soundPath -VolumePercent $evVolume }
        catch { $playerUsed = ''; break }
    }
}

if (-not $playerUsed) {
    $soundPath = ''
    for ($i = 0; $i -lt $repeatCount; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds $repeatGap }
        [Console]::Beep($freq, 220)
    }
    $playerUsed = 'beep'
}

# --- tray balloon -------------------------------------------------------------
# A balloon tip, not a message box. It does not steal keyboard focus.
$notified = 'no'
if (-not $dryRun -and ($Kind -ne 'done' -or $opt['TOAST_ON_DONE'] -eq '1')) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $tray = New-Object System.Windows.Forms.NotifyIcon
        $tray.Icon    = [System.Drawing.SystemIcons]::Information
        $tray.Visible = $true
        $tray.ShowBalloonTip(8000, $title, $detail, [System.Windows.Forms.ToolTipIcon]::$icon)
        Start-Sleep -Seconds 5
        $tray.Dispose()
        $notified = 'balloon'
    } catch { }
}

# --- report -------------------------------------------------------------------
# A zero exit alone cannot distinguish a played sound from a fallback beep, so
# this is what CI asserts on, and it is the first step in working out why
# nothing is audible.
$reportSound = if ($soundPath) { $soundPath } else { 'none' }
$reportElapsed = if ($null -ne $elapsed) { $elapsed } else { 'na' }
Write-Decision ("kind=$Kind sound=$reportSound player=$playerUsed volume=$evVolume " +
                "pattern=${repeatCount}x${repeatGap} notified=$notified " +
                "elapsed=$reportElapsed detail=$detail")

exit 0
'@

Set-Content -Path $notifyScript -Value $notifyBody -Encoding utf8
Write-Ok "wrote claude-notify.ps1"

# --------------------------------------------------------------------- test ---

Write-Host ""
# Set NO_TEST_TONE=1 to skip this, for unattended installs and CI.
if ($env:NO_TEST_TONE -eq '1') {
    Write-Step "test tone skipped (NO_TEST_TONE=1)"
} else {
    Write-Step "test tone..."
    Remove-Item (Join-Path $env:TEMP 'claude-notify.last') -Force -ErrorAction SilentlyContinue
    # 'blocked' rather than 'done' because it is in ALWAYS_ALERT by default, so
    # it bypasses the elapsed-time and focus checks and you actually hear it.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $notifyScript -Kind blocked
}

Write-Host ""
Write-Ok "Done. Restart Claude Code, then run /hooks to confirm all five are listed."
Write-Dim "Change options:      powershell -File .\install-claude-sound-alerts.ps1 -Configure"
Write-Dim "Or edit directly:    $confFile"
Write-Dim "Why was I not told?  `$env:CLAUDE_NOTIFY_DEBUG=1; & `"`$env:USERPROFILE\.claude\claude-notify.ps1`" -Kind done"
Write-Dim "Silence everything:  set `"disableAllHooks`": true in settings.json"
Write-Host ""
