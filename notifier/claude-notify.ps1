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
}
if (Test-Path $confFile) {
    foreach ($line in (Get-Content $confFile)) {
        if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') {
            if ($opt.ContainsKey($matches[1])) { $opt[$matches[1]] = $matches[2] }
        }
    }
}

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
if (Test-InList $Kind $opt['MUTE']) {
    Write-Decision "kind=$Kind suppressed=muted"
    exit 0
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

if ($opt['SPEAK'] -eq '1') {
    try {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $synth.Speak("$title. $detail")
        $synth.Dispose()
        $playerUsed = 'speech'
    } catch { }
}

if (-not $playerUsed) {
    foreach ($w in $wavs) {
        $p = Join-Path $env:SystemRoot "Media\$w"
        if (Test-Path $p) {
            try {
                $player = New-Object System.Media.SoundPlayer $p
                $player.PlaySync()
                if ($Kind -ne 'done') { Start-Sleep -Milliseconds 220; $player.PlaySync() }
                $soundPath  = $p
                $playerUsed = 'SoundPlayer'
            } catch { }
            break
        }
    }
}

if (-not $playerUsed) {
    [Console]::Beep($freq, 220)
    if ($Kind -ne 'done') { Start-Sleep -Milliseconds 120; [Console]::Beep($freq, 220) }
    $playerUsed = 'beep'
}

# --- tray balloon -------------------------------------------------------------
# A balloon tip, not a message box. It does not steal keyboard focus.
$notified = 'no'
if ($Kind -ne 'done' -or $opt['TOAST_ON_DONE'] -eq '1') {
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
Write-Decision "kind=$Kind sound=$reportSound player=$playerUsed notified=$notified elapsed=$reportElapsed detail=$detail"

exit 0
