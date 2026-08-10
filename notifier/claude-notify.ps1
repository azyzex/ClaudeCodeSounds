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
param([ValidateSet('mark','done','blocked','limit','error','limit-reset','weekly-reset','watch')]
      [string]$Kind = 'done')

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
    ALWAYS_ALERT          = 'blocked,limit,error,limit-reset,weekly-reset'
    MUTE                  = ''
    QUIET_HOURS           = ''
    MUTE_UNTIL            = ''
    NTFY_TOPIC            = ''
    NTFY_SERVER           = 'https://ntfy.sh'
    NTFY_ALERTS           = 'blocked,limit,error'
    RESPECT_DND           = '1'
    WINDOW_HOURS          = '5'
    LIMIT_RESET_ENABLED   = '1'; LIMIT_RESET_VOLUME  = '100'; LIMIT_RESET_PATTERN  = '2x180'; LIMIT_RESET_SOUND  = ''
    WEEKLY_RESET_ENABLED  = '1'; WEEKLY_RESET_VOLUME = '70';  WEEKLY_RESET_PATTERN = '1';     WEEKLY_RESET_SOUND = ''
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
$ev        = $Kind.ToUpperInvariant().Replace('-', '_')
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

# --- waiting for a reset ------------------------------------------------------
# Claude Code hands the status line the real figures, straight from Anthropic.
# The status line script saves them; this watches the clock and alerts when a
# reset time passes. A hook cannot do that itself, because it exits as soon as
# it finishes, so the notifier starts a copy of itself in the background.
$limitsFile = Join-Path $env:USERPROFILE '.claude\claude-limits.json'
# Other surfaces drop their own file in here rather than writing the shared one.
# Keeping them apart is the point: Claude Code and the browser may be signed
# into different accounts, and the window is per account, so a merged reset time
# would be confidently wrong for one of them.
$limitsDir  = Join-Path $env:USERPROFILE '.claude\claude-limits.d'
$firedFile  = Join-Path $env:USERPROFILE '.claude\claude-reset-fired'
$aliveFile  = Join-Path $env:USERPROFILE '.claude\claude-watch-alive'
$estFile    = Join-Path $env:USERPROFILE '.claude\claude-limit-reset'

function Get-Limit {
    param([string]$Key)
    if (-not (Test-Path $limitsFile)) { return '' }
    foreach ($line in (Get-Content $limitsFile)) {
        if ($line -match "^$Key=(.*)$") { return $matches[1].Trim() }
    }
    return ''
}

function Get-FileValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path $Path)) { return '' }
    foreach ($line in (Get-Content $Path)) {
        if ($line -match "^$Key=(.*)$") { return $matches[1].Trim() }
    }
    return ''
}

# Every file that might hold a reset time: the one Claude Code writes, plus one
# per other surface that has reported in. Both a missing file and an empty
# directory are the normal case.
function Get-LimitSources {
    $found = @()
    if (Test-Path $limitsFile) { $found += $limitsFile }
    if (Test-Path $limitsDir) {
        $found += (Get-ChildItem -Path $limitsDir -Filter '*.conf' -File `
                   -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    return $found
}

function Test-AlreadyFired {
    param([string]$Window, [string]$Stamp)
    if (-not (Test-Path $firedFile)) { return $false }
    return ((Get-Content $firedFile) -contains "$Window=$Stamp")
}

function Set-Fired {
    param([string]$Window, [string]$Stamp)
    $keep = @()
    if (Test-Path $firedFile) {
        $keep = @(Get-Content $firedFile | Where-Object { $_ -notmatch "^$Window=" })
    }
    $keep += "$Window=$Stamp"
    [System.IO.File]::WriteAllLines($firedFile, $keep)
}

function Start-Watcher {
    if ($env:CLAUDE_NOTIFY_DRYRUN -eq '1') { return }
    if (Test-Path $aliveFile) {
        $last = (Get-Content $aliveFile -Raw).Trim()
        if ($last -match '^\d+$') {
            $now = [int][double]::Parse((Get-Date -UFormat %s))
            if (($now - [int]$last) -lt 150) { return }
        }
    }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Kind', 'watch'
    )
}

if ($Kind -eq 'watch') {
    # Wakes once a minute rather than sleeping until the target: a machine that
    # suspends would make a long sleep fire late by however long it was asleep,
    # whereas comparing against an absolute time self-corrects on wake.
    while ($true) {
        [System.IO.File]::WriteAllText($aliveFile, [string][int][double]::Parse((Get-Date -UFormat %s)))
        $now = [int][double]::Parse((Get-Date -UFormat %s))
        $pending = $false
        $firedThisTick = $false

        # Every source, every window. Two accounts each get their own alert, and
        # an alert already given is never repeated: the reset timestamp is its
        # identity, and the account is part of the key so one account cannot
        # silence another.
        #
        # Both windows can come due in the same tick. The debounce exists to
        # stop a stutter of identical alerts rather than to hide a different
        # one, so each is given room.
        $five = ''
        foreach ($src in (Get-LimitSources)) {
            $account = Get-FileValue $src 'account'
            if (-not $account) { $account = 'local' }

            foreach ($window in @('five_hour', 'seven_day')) {
                $at = Get-FileValue $src "${window}_resets_at"
                if ($at -notmatch '^\d+$') { continue }

                # Remembered only so the estimate below knows a real figure exists.
                if ($window -eq 'five_hour') { $five = $at }

                if ($now -ge [int64]$at) {
                    if (-not (Test-AlreadyFired "$window@$account" $at)) {
                        Set-Fired "$window@$account" $at
                        if ($firedThisTick) {
                            Start-Sleep -Seconds ((Get-IntOpt 'DEBOUNCE_SECONDS' 2) + 1)
                        }
                        $reset = if ($window -eq 'five_hour') { 'limit-reset' } else { 'weekly-reset' }
                        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Kind $reset *> $null
                        $firedThisTick = $true
                    }
                } else { $pending = $true }
            }
        }

        # The estimate, used only when hitting the limit produced no real
        # figure. Dropped as soon as the status line supplies one.
        if (Test-Path $estFile) {
            if ($five) {
                Remove-Item $estFile -Force -ErrorAction SilentlyContinue
            } else {
                $target = ((Get-Content $estFile -Raw) -split '\|')[0].Trim()
                if ($target -match '^\d+$' -and $now -ge [int64]$target) {
                    Remove-Item $estFile -Force -ErrorAction SilentlyContinue
                    $env:CLAUDE_NOTIFY_ESTIMATED = 'estimated'
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Kind limit-reset *> $null
                    $env:CLAUDE_NOTIFY_ESTIMATED = $null
                } elseif ($target -match '^\d+$') { $pending = $true }
                else { Remove-Item $estFile -Force -ErrorAction SilentlyContinue }
            }
        }

        if (-not $pending) { break }
        Start-Sleep -Seconds 60
    }
    Remove-Item $aliveFile -Force -ErrorAction SilentlyContinue
    exit 0
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

            # The reset time is somewhere in a rate limit message, but its exact
            # shape has never been seen rather than guessed at. Saving the next
            # real one means the parser can be written against fact instead of
            # assumption. One file, overwritten each time, so it cannot grow.
            if ($Kind -eq 'limit' -and $env:CLAUDE_NOTIFY_DRYRUN -ne '1') {
                try {
                    $dump = Join-Path $env:USERPROFILE '.claude\claude-limit-payload.json'
                    [System.IO.File]::WriteAllText($dump, $stdin)
                } catch { }
            }
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
    # Nothing to schedule: the status line records the real reset times. This
    # only makes sure something is watching them, since the watcher exits once
    # nothing is pending.
    if ((Get-LimitSources).Count -gt 0) { Start-Watcher }
    Write-Decision "kind=mark session=$session"
    exit 0
}

# --- schedule the limit reset -------------------------------------------------
# Only a fallback, for hitting the limit before the status line has ever run. A
# real reset time always wins over this guess, and the wording says which it is.
if ($Kind -eq 'limit' -and $env:CLAUDE_NOTIFY_DRYRUN -ne '1') {
    try {
        if (-not (Get-Limit 'five_hour_resets_at')) {
            $already = $false
            if (Test-Path $estFile) {
                $t = ((Get-Content $estFile -Raw) -split '\|')[0].Trim()
                $now = [int][double]::Parse((Get-Date -UFormat %s))
                if ($t -match '^\d+$' -and $now -lt [int64]$t) { $already = $true }
            }
            if (-not $already) {
                $hours = Get-IntOpt 'WINDOW_HOURS' 5
                $at = [int][double]::Parse((Get-Date -UFormat %s)) + $hours * 3600
                [System.IO.File]::WriteAllText($estFile, "$at|estimated")
            }
        }
        Start-Watcher
    } catch { }
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

# --- is the desktop already in do not disturb? ---------------------------------
# Focus Assist has no supported API. This reads the value the shell writes, at a
# path that has moved between Windows releases, so it fails open: if the answer
# cannot be determined the alert happens. Being wrongly silent is worse than
# being wrongly noisy, because a missed prompt is the problem this exists for.
function Test-DoNotDisturb {
    if ($opt['RESPECT_DND'] -ne '1') { return $false }
    try {
        $base = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'
        $v = Get-ItemProperty -Path $base -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -ErrorAction Stop
        # 0 means notifications are switched off globally.
        return ($v.NOC_GLOBAL_SETTING_TOASTS_ENABLED -eq 0)
    } catch { return $false }
}

if (-not $force -and (Test-DoNotDisturb)) {
    Write-Decision "kind=$Kind suppressed=do-not-disturb"
    exit 0
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
    'limit-reset' {
        $bundled  = @('chime-bright','chime-high')
        $wavs     = @('Windows Notify System Generic.wav','Windows Ding.wav','chimes.wav')
        $title    = 'Claude is available again'
        $fallback = if ($env:CLAUDE_NOTIFY_ESTIMATED -eq 'estimated') {
            'About five hours have passed. Your limit has probably reset.'
        } else { 'Your usage limit has reset.' }
        $icon     = 'Info'; $freq = 1046
    }
    'weekly-reset' {
        $bundled  = @('chime-mid','chime-soft')
        $wavs     = @('Windows Notify.wav','Windows Ding.wav','chimes.wav')
        $title    = 'Weekly limit reset'
        $fallback = 'Your seven day limit has reset.'
        $icon     = 'Info'; $freq = 880
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

# Where it came from. With alerts arriving from several terminals and a browser
# at once, "Claude is done" answers the wrong question. The title says which,
# using the project folder for a terminal because that is how sessions are
# thought of.
$sourceLabel = ''
switch ($env:CLAUDE_NOTIFY_SOURCE) {
    'web'   { $sourceLabel = 'browser' }
    ''      { if ($cwd) { $sourceLabel = Split-Path $cwd -Leaf } }
    $null   { if ($cwd) { $sourceLabel = Split-Path $cwd -Leaf } }
    default { $sourceLabel = $env:CLAUDE_NOTIFY_SOURCE }
}
if ($sourceLabel) { $title = "$title - $sourceLabel" }

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

# --- leave a marker for escalation --------------------------------------------
# A hook exits at once, so it cannot wait to see whether you responded. It just
# records that a prompt is outstanding; the tray app decides whether to nag.
# Anything that is not "blocked" means the session moved on, so the marker goes.
if (-not $dryRun) {
    try {
        $pending = Join-Path $env:USERPROFILE '.claude\claude-notify-pending'
        if ($Kind -eq 'blocked') {
            $stamp = [int][double]::Parse((Get-Date -UFormat %s))
            [System.IO.File]::WriteAllText($pending, "$stamp|$detail")
        } elseif (Test-Path $pending) {
            Remove-Item $pending -Force -ErrorAction SilentlyContinue
        }
    } catch { }
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
