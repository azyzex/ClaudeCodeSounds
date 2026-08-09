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
   ~/.claude/claude-sounds/        the bundled alert sounds
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
$soundDir     = Join-Path $claudeDir 'claude-sounds'
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
    MUTE_UNTIL            = ''
    NTFY_TOPIC            = ''
    NTFY_SERVER           = 'https://ntfy.sh'
    NTFY_ALERTS           = 'blocked,limit,error'
    SOUND_PACK            = 'default'
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

# Which sound pack to use. A pack is a folder under ~/.claude/claude-sounds/,
# so adding your own means dropping a folder of .wav files in beside "default"
# and naming it here.
SOUND_PACK=$($opt['SOUND_PACK'])

# Silence everything until this epoch second. The desktop app's "quiet for an
# hour" writes it; it expires by itself. Leave empty for no temporary mute.
MUTE_UNTIL=$($opt['MUTE_UNTIL'])

# Push alerts to your phone through ntfy.sh. Leave the topic empty to disable.
#
# Pick a long, random topic name, install the free ntfy app and subscribe to it.
# The topic name is the whole address AND the whole secret: anyone who knows it
# can read your notifications and send to them, so do not put anything sensitive
# in an alert message.
NTFY_TOPIC=$($opt['NTFY_TOPIC'])
NTFY_SERVER=$($opt['NTFY_SERVER'])

# Which kinds to push. Pushing every finished turn to a phone gets old fast.
NTFY_ALERTS=$($opt['NTFY_ALERTS'])

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
    [System.IO.File]::WriteAllText($confFile, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
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
    if (Test-Path $soundDir) { Remove-Item $soundDir -Recurse -Force }
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
$soundDir = Join-Path $env:USERPROFILE '.claude\claude-sounds'
$debug    = ($env:CLAUDE_NOTIFY_DEBUG -eq '1')
# CLAUDE_NOTIFY_FORCE=1 plays the alert regardless of every suppression rule
# below. The desktop app uses it for its preview button: you are tuning these
# settings, so the preview must not be silenced by them.
$force    = ($env:CLAUDE_NOTIFY_FORCE -eq '1')

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
    MUTE_UNTIL            = ''
    NTFY_TOPIC            = ''
    NTFY_SERVER           = 'https://ntfy.sh'
    NTFY_ALERTS           = 'blocked,limit,error'
    SOUND_PACK            = 'default'

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

# Record what was decided. Every exit path goes through this, so the log and the
# debug output can never disagree. It never fails the alert: a log that cannot be
# written is not worth losing a notification over.
function Write-Decision {
    param([string]$Text)
    if ($env:CLAUDE_NOTIFY_DRYRUN -ne '1') {
        try {
            $log = Join-Path $env:USERPROFILE '.claude\claude-notify.log'
            # Trim before appending so the file cannot grow without bound. 64KB
            # is a few thousand alerts, far more than anything ever displays.
            if ((Test-Path $log) -and (Get-Item $log).Length -gt 65536) {
                $keep = Get-Content $log -Tail 200
                [System.IO.File]::WriteAllLines($log, $keep)
            }
            $stamp = [int][double]::Parse((Get-Date -UFormat %s))
            Add-Content -Path $log -Value ("{0}|{1}" -f $stamp, $Text) -Encoding utf8
        } catch { }
    }
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
if (-not $force -and ((Test-InList $Kind $opt['MUTE']) -or $evEnabled -eq '0')) {
    Write-Decision "kind=$Kind suppressed=muted"
    exit 0
}

# --- temporarily muted? -------------------------------------------------------
# MUTE_UNTIL is an epoch second. The app's "quiet for an hour" writes one, and it
# expires by itself, so a mute you forget about cannot silence things
# permanently the way a plain flag would.
if (-not $force -and $opt['MUTE_UNTIL'] -match '^\d+$') {
    $nowEpoch = [int][double]::Parse((Get-Date -UFormat %s))
    if ($nowEpoch -lt [int64]$opt['MUTE_UNTIL']) {
        Write-Decision "kind=$Kind suppressed=quiet-until until=$($opt['MUTE_UNTIL'])"
        exit 0
    }
}

# --- quiet hours? -------------------------------------------------------------
# QUIET_HOURS=23:00-08:00, and windows that wrap past midnight are handled.
# This lives in the config rather than in a resident process, so it works
# whether or not anything else is running.
if (-not $force -and $opt['QUIET_HOURS'] -match '^\s*(\d{1,2}):?(\d{2})\s*-\s*(\d{1,2}):?(\d{2})\s*$') {
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
if (-not $force -and -not $always -and $minSeconds -gt 0 -and $null -ne $elapsed -and $elapsed -lt $minSeconds) {
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

if (-not $force -and -not $always -and $opt['SUPPRESS_WHEN_FOCUSED'] -eq '1' -and (Test-Focused)) {
    Write-Decision "kind=$Kind suppressed=focused"
    exit 0
}

# --- debounce -----------------------------------------------------------------
# Several of these events can fire inside the same second. Without this you get
# a stutter of overlapping audio.
$stamp = Join-Path $env:TEMP 'claude-notify.last'
if (-not $force -and (Test-Path $stamp)) {
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
        $bundled  = @('alert-attention')
        $wavs     = @('Windows Exclamation.wav','Windows Notify Messaging.wav','chord.wav')
        $title    = 'Claude needs you'
        $fallback = 'Waiting on your input or a permission prompt'
        $icon     = 'Warning'; $freq = 740
    }
    'limit' {
        $bundled  = @('alert-limit')
        $wavs     = @('Windows Critical Stop.wav','Windows Battery Critical.wav','chord.wav')
        $title    = 'Claude hit the usage limit'
        $fallback = 'Rate limited. The turn ended early.'
        $icon     = 'Error'; $freq = 440
    }
    'error' {
        $bundled  = @('alert-error')
        $wavs     = @('Windows Hardware Fail.wav','Windows Foreground.wav','Windows Error.wav','chimes.wav')
        $title    = 'Claude stopped'
        $fallback = 'The turn ended on an API error'
        $icon     = 'Error'; $freq = 494
    }
    default {
        # Several interchangeable chimes, so PROJECT_PITCH has something to
        # choose between. The first is the default when that option is off.
        $bundled  = @('chime-glass','chime-soft','chime-bright','chime-low','chime-warm','chime-mid')
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
    $bshift = $hash % $bundled.Count
    if ($bshift -gt 0) { $bundled = $bundled[$bshift..($bundled.Count-1)] + $bundled[0..($bshift-1)] }
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
        # Bundled sounds first. They are the same on every machine, which is
        # what makes the alerts consistent and PROJECT_PITCH meaningful. The
        # Windows Media set stays as a fallback for anyone who deletes them.
        # A pack name is a single directory component, never a path.
        $pack = $opt['SOUND_PACK']
        if (-not $pack -or $pack -match '[\\/:]' -or $pack.StartsWith('.')) { $pack = 'default' }
        # Selected pack, then default, then the flat layout used before packs.
        foreach ($d in @((Join-Path $soundDir $pack), (Join-Path $soundDir 'default'), $soundDir)) {
            foreach ($b in $bundled) {
                $p = Join-Path $d "$b.wav"
                if (Test-Path $p) { $soundPath = $p; break }
            }
            if ($soundPath) { break }
        }
    }
    if (-not $soundPath) {
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

# --- push to a phone ----------------------------------------------------------
# ntfy.sh needs no account or API key: the topic name is the whole address, and
# also the whole secret, so it is off unless someone sets one.
#
# Started without waiting, because a notification must never make Claude Code
# wait on the network, and an unreachable phone is not a reason to lose the
# local alert that already happened.
$pushed = 'no'
if ($opt['NTFY_TOPIC'] -and -not $dryRun -and (Test-InList $Kind $opt['NTFY_ALERTS'])) {
    $url = "$($opt['NTFY_SERVER'].TrimEnd('/'))/$($opt['NTFY_TOPIC'])"
    $prio = if ($Kind -eq 'done') { 'default' } else { 'high' }

    # Sent inline with a short timeout, rather than handed to a background job
    # or to curl.exe. Both of those were tried: a job needs its arguments
    # marshalled across a runspace boundary, and PowerShell 5.1's Start-Process
    # does not quote the elements of -ArgumentList, so a header containing a
    # space silently arrives as several arguments and the push is lost.
    #
    # Waiting here costs nothing that matters: the hook is async, so Claude Code
    # is not held up, and the sound has already played by this point.
    try {
        $headers = @{ Title = $title; Priority = $prio; Tags = 'bell' }
        Invoke-RestMethod -Uri $url -Method Post -Headers $headers `
            -Body $detail -TimeoutSec 8 | Out-Null
        $pushed = 'sent'
    } catch {
        $pushed = 'failed'
    }
}

# --- report -------------------------------------------------------------------
# A zero exit alone cannot distinguish a played sound from a fallback beep, so
# this is what CI asserts on, and it is the first step in working out why
# nothing is audible.
$reportSound = if ($soundPath) { $soundPath } else { 'none' }
$reportElapsed = if ($null -ne $elapsed) { $elapsed } else { 'na' }
Write-Decision ("kind=$Kind sound=$reportSound player=$playerUsed volume=$evVolume " +
                "pattern=${repeatCount}x${repeatGap} notified=$notified pushed=$pushed " +
                "elapsed=$reportElapsed detail=$detail")

exit 0
'@

Set-Content -Path $notifyScript -Value $notifyBody -Encoding utf8
Write-Ok "wrote claude-notify.ps1"

# ------------------------------------------------------------- the sounds ---
# Written out from the base64 block at the end of this file, so a machine with
# an unusual Windows image still gets real audio instead of a console beep.

$soundBlob = @'
default/alert-attention.wav|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
default/alert-error.wav|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
default/alert-limit.wav|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
default/chime-bright.wav|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
default/chime-glass.wav|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
default/chime-low.wav|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
default/chime-mid.wav|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
default/chime-soft.wav|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
default/chime-warm.wav|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
'@

New-Item -ItemType Directory -Path $soundDir -Force | Out-Null
$soundCount = 0
$packs = @{}
foreach ($line in ($soundBlob -split "`n")) {
    $line = $line.Trim()
    if (-not $line) { continue }
    $parts = $line -split '\|', 2
    if ($parts.Count -ne 2) { continue }
    # Each entry is "pack/name.wav". Refuse anything that tries to climb out.
    $rel = $parts[0]
    if ($rel -match '\.\.' -or $rel -match '^[\\/]' -or $rel -match ':') { continue }
    $packName = ($rel -split '/')[0]
    $packs[$packName] = $true
    try {
        New-Item -ItemType Directory -Path (Join-Path $soundDir $packName) -Force | Out-Null
        [System.IO.File]::WriteAllBytes(
            # String.Replace, not -replace: the latter treats the replacement
            # as regex syntax, where a lone backslash is an escape and vanishes.
            (Join-Path $soundDir $rel.Replace('/', '\')),
            [Convert]::FromBase64String($parts[1]))
        $soundCount++
    } catch { }
}

if ($soundCount -gt 0) {
    Write-Ok "wrote $soundCount sounds in $($packs.Count) pack(s)"
} else {
    Write-Step "could not write the bundled sounds, falling back to system sounds"
}

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
