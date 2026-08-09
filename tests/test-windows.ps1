<#
  Integration tests for install-claude-sound-alerts.ps1.

  Runs the real installer against a throwaway USERPROFILE, so nothing here
  touches the machine's actual ~/.claude. Usage:

    powershell -ExecutionPolicy Bypass -File tests\test-windows.ps1
#>
[CmdletBinding()]
param([string]$Installer)

$ErrorActionPreference = 'Continue'

if (-not $Installer) {
    $Installer = Join-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) 'install-claude-sound-alerts.ps1'
}

$script:Pass = 0
$script:Fail = 0

function Ok($msg)  { $script:Pass++; Write-Host "  ok    $msg" -ForegroundColor Green }
function Bad($msg) { $script:Fail++; Write-Host "  FAIL  $msg" -ForegroundColor Red }
function Check($actual, $expected, $msg) {
    if ("$actual" -eq "$expected") { Ok $msg } else { Bad "$msg (expected '$expected', got '$actual')" }
}
function Assert($cond, $msg) { if ($cond) { Ok $msg } else { Bad $msg } }

function New-TempHome {
    $h = Join-Path ([System.IO.Path]::GetTempPath()) ("cchome-" + [guid]::NewGuid().ToString('N').Substring(0,12))
    New-Item -ItemType Directory -Path (Join-Path $h '.claude') -Force | Out-Null
    return $h
}

# Run the installer with USERPROFILE pointed at a sandbox. Returns the exit code.
function Invoke-Installer {
    param([string]$Home_, [switch]$Uninstall, [switch]$WithTone)
    # Not $args: that is an automatic PowerShell variable (PSScriptAnalyzer
    # PSAvoidAssignmentToAutomaticVariable).
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Installer)
    if ($Uninstall) { $psArgs += '-Uninstall' }
    $prevProfile = $env:USERPROFILE
    $prevTone    = $env:NO_TEST_TONE
    $env:USERPROFILE = $Home_
    if (-not $WithTone) { $env:NO_TEST_TONE = '1' }
    try {
        & powershell.exe @psArgs *> $null
        return $LASTEXITCODE
    } finally {
        $env:USERPROFILE = $prevProfile
        $env:NO_TEST_TONE = $prevTone
    }
}

# Count hook groups belonging to us, per event. Returns "Event=count; ..." sorted.
function Get-OurHookCounts {
    param([string]$SettingsPath)
    $json = Get-Content $SettingsPath -Raw | ConvertFrom-Json
    if (-not $json.hooks) { return "" }
    $parts = @()
    foreach ($p in ($json.hooks.PSObject.Properties.Name | Sort-Object)) {
        $groups = @($json.hooks.$p)
        $n = 0
        foreach ($g in $groups) {
            if (($g | ConvertTo-Json -Depth 20 -Compress) -like '*claude-notify.ps1*') { $n++ }
        }
        $parts += "$p=$n"
    }
    return ($parts -join '; ')
}

Write-Host "installer: $Installer"
Write-Host "psversion: $($PSVersionTable.PSVersion)"
Write-Host ""

# --------------------------------------------------------------------------
Write-Host "case 1: fresh install into an empty profile"
# --------------------------------------------------------------------------
$h = New-TempHome
Check (Invoke-Installer -Home_ $h) 0 "installer exits 0"
$s = Join-Path $h '.claude\settings.json'
Assert (Test-Path $s) "settings.json created"
Assert (Test-Path (Join-Path $h '.claude\claude-notify.ps1')) "notifier created"
Check (Get-OurHookCounts $s) "Notification=1; Stop=1; StopFailure=2; UserPromptSubmit=1" "five hook groups across four events"
try { Get-Content $s -Raw | ConvertFrom-Json | Out-Null; Ok "settings.json parses as JSON" }
catch { Bad "settings.json parses as JSON" }
# A BOM would break strict parsers, so assert the first byte is '{'.
$firstByte = [System.IO.File]::ReadAllBytes($s)[0]
Check $firstByte 123 "written without a UTF-8 BOM"
$parsed = Get-Content $s -Raw | ConvertFrom-Json
Check $parsed.hooks.Stop[0].hooks[0].async "True" "async is set on the Stop hook"
Check $parsed.hooks.StopFailure[0].matcher "rate_limit" "rate_limit has its own StopFailure group"
Remove-Item $h -Recurse -Force
Write-Host ""

# --------------------------------------------------------------------------
Write-Host "case 2: merge into existing settings, leaving them intact"
# --------------------------------------------------------------------------
$h = New-TempHome
$s = Join-Path $h '.claude\settings.json'
@'
{
  "model": "opus",
  "theme": "dark",
  "hooks": {
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "echo somebody-elses-hook" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "echo pre-existing-stop-hook" } ] }
    ]
  }
}
'@ | Set-Content $s -Encoding utf8
Check (Invoke-Installer -Home_ $h) 0 "installer exits 0 over existing settings"
$parsed = Get-Content $s -Raw | ConvertFrom-Json
Check $parsed.model "opus" "unrelated key 'model' preserved"
Check $parsed.theme "dark" "unrelated key 'theme' preserved"
$raw = Get-Content $s -Raw
Assert ($raw -like '*somebody-elses-hook*')    "unrelated PostToolUse hook preserved"
Assert ($raw -like '*pre-existing-stop-hook*') "pre-existing Stop hook preserved"
Check (@($parsed.hooks.Stop).Count) 2 "our Stop group added alongside the existing one"
Assert (@(Get-ChildItem (Join-Path $h '.claude') -Filter 'settings.json.bak-*').Count -ge 1) "timestamped backup written"
Write-Host ""

# --------------------------------------------------------------------------
Write-Host "case 3: re-running is idempotent"
# --------------------------------------------------------------------------
Invoke-Installer -Home_ $h | Out-Null
Invoke-Installer -Home_ $h | Out-Null
Check (Get-OurHookCounts $s) "Notification=1; PostToolUse=0; Stop=1; StopFailure=2; UserPromptSubmit=1" "still exactly five groups after three runs"
Assert ((Get-Content $s -Raw) -like '*somebody-elses-hook*') "other hooks still intact"
Write-Host ""

# --------------------------------------------------------------------------
Write-Host "case 4: uninstall removes only our entries"
# --------------------------------------------------------------------------
Check (Invoke-Installer -Home_ $h -Uninstall) 0 "uninstall exits 0"
$parsed = Get-Content $s -Raw | ConvertFrom-Json
$raw = Get-Content $s -Raw
Check (Get-OurHookCounts $s) "PostToolUse=0; Stop=0" "none of our groups remain"
Check $parsed.model "opus" "unrelated key survived uninstall"
Assert ($raw -like '*somebody-elses-hook*')    "unrelated hook survived uninstall"
Assert ($raw -like '*pre-existing-stop-hook*') "pre-existing Stop hook survived"
Assert (-not (Test-Path (Join-Path $h '.claude\claude-notify.ps1'))) "notifier removed"
Remove-Item $h -Recurse -Force
Write-Host ""

# --------------------------------------------------------------------------
Write-Host "case 5: refuses to clobber invalid JSON"
# --------------------------------------------------------------------------
$h = New-TempHome
$s = Join-Path $h '.claude\settings.json'
'{ this is not json' | Set-Content $s -Encoding utf8
Assert ((Invoke-Installer -Home_ $h) -ne 0) "exits non-zero on malformed settings.json"
Assert ((Get-Content $s -Raw) -like '*this is not json*') "malformed file left untouched"
Remove-Item $h -Recurse -Force
Write-Host ""

# --------------------------------------------------------------------------
Write-Host "case 6: the notifier survives every alert kind"
# --------------------------------------------------------------------------
$h = New-TempHome
Invoke-Installer -Home_ $h | Out-Null
$n = Join-Path $h '.claude\claude-notify.ps1'
$payload = '{"message":"test payload","session_id":"s1","cwd":"C:\\tmp\\proj"}'
foreach ($kind in @('mark', 'done', 'blocked', 'limit', 'error')) {
    Remove-Item (Join-Path $env:TEMP 'claude-notify.last') -Force -ErrorAction SilentlyContinue
    $errFile = Join-Path $env:TEMP "cc-err-$kind.txt"
    $payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $n -Kind $kind 1>$null 2>$errFile
    Check $LASTEXITCODE 0 "kind '$kind' exits 0"
    $errText = if (Test-Path $errFile) { (Get-Content $errFile -Raw) } else { "" }
    if ([string]::IsNullOrWhiteSpace($errText)) { Ok "kind '$kind' writes nothing to stderr" }
    else { Bad "kind '$kind' stderr: $($errText.Trim())" }
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
}

Write-Host "  (no stdin at all)"
Remove-Item (Join-Path $env:TEMP 'claude-notify.last') -Force -ErrorAction SilentlyContinue
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $n -Kind done *> $null
Check $LASTEXITCODE 0 "runs with no stdin"

Write-Host "  (rejects an unknown kind, per ValidateSet)"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $n -Kind bogus-kind *> $null
Assert ($LASTEXITCODE -ne 0) "unknown kind is rejected"
Remove-Item $h -Recurse -Force
Write-Host ""

# --------------------------------------------------------------------------
Write-Host "case 7: the config file drives behaviour"
# --------------------------------------------------------------------------
$h = New-TempHome
Invoke-Installer -Home_ $h | Out-Null
$n = Join-Path $h '.claude\claude-notify.ps1'
$c = Join-Path $h '.claude\claude-notify.conf'
Assert (Test-Path $c) "config file created"

# Ask the notifier what it decided rather than inferring from a zero exit.
function Get-Decision {
    param([string]$Kind, [string]$Payload = '{}')
    Remove-Item (Join-Path $env:TEMP 'claude-notify.last') -Force -ErrorAction SilentlyContinue
    $prev = $env:USERPROFILE
    $env:USERPROFILE = $h
    $env:CLAUDE_NOTIFY_DEBUG = '1'
    try {
        $out = $Payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $n -Kind $Kind 2>$null
        return ($out | Out-String).Trim()
    } finally {
        $env:USERPROFILE = $prev
        $env:CLAUDE_NOTIFY_DEBUG = $null
    }
}

function Set-Conf {
    param([string]$Key, [string]$Value)
    # A plain loop rather than ForEach-Object: the analyser cannot follow a
    # variable assigned inside a pipeline scriptblock and read after it.
    $out = @()
    $seen = $false
    foreach ($line in (Get-Content $c)) {
        if ($line -match "^$Key=") {
            $out += "$Key=$Value"
            $seen = $true
        } else {
            $out += $line
        }
    }
    # Append when the key is not already there. Without this the helper silently
    # does nothing for any key the installer does not write by default.
    if (-not $seen) { $out += "$Key=$Value" }
    [System.IO.File]::WriteAllLines($c, $out)
}

Write-Host "  (mute)"
Set-Conf 'MUTE' 'done'
$r = Get-Decision 'done'
Assert ($r -like '*suppressed=muted*') "MUTE=done silences the finish alert"
$r = Get-Decision 'blocked'
Assert ($r -notlike '*suppressed=muted*') "MUTE=done leaves blocked alone"
Set-Conf 'MUTE' ''

Write-Host "  (elapsed-time threshold)"
Set-Conf 'MIN_SECONDS' '30'
Set-Conf 'SUPPRESS_WHEN_FOCUSED' '0'
$payload = '{"session_id":"t7"}'
Get-Decision 'mark' $payload | Out-Null
$r = Get-Decision 'done' $payload
Assert ($r -like '*suppressed=too-quick*') "a turn under MIN_SECONDS stays silent"
# blocked is in ALWAYS_ALERT, so the same short turn must still alert.
Get-Decision 'mark' $payload | Out-Null
$r = Get-Decision 'blocked' $payload
Assert ($r -notlike '*suppressed=*') "ALWAYS_ALERT bypasses the threshold"
Set-Conf 'MIN_SECONDS' '0'
Get-Decision 'mark' $payload | Out-Null
$r = Get-Decision 'done' $payload
Assert ($r -notlike '*too-quick*') "MIN_SECONDS=0 disables the check"

Write-Host "  (mark plays nothing)"
$r = Get-Decision 'mark'
Assert ($r -like '*kind=mark*')  "mark reports itself and exits"
Assert ($r -notlike '*player=*') "mark chooses no player"

Write-Host "  (debounce is configurable)"
# Dry run, so the elapsed time between the two calls is process startup rather
# than two sound clips plus a five second balloon, which would otherwise creep
# up on the debounce window and make this flaky.
$env:CLAUDE_NOTIFY_DRYRUN = '1'
Set-Conf 'DEBOUNCE_SECONDS' '9'
Get-Decision 'blocked' | Out-Null
# Deliberately not via Get-Decision, which clears the stamp first.
$env:USERPROFILE = $h; $env:CLAUDE_NOTIFY_DEBUG = '1'
$r = ('{}' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $n -Kind blocked 2>$null | Out-String).Trim()
$env:CLAUDE_NOTIFY_DEBUG = $null
$env:CLAUDE_NOTIFY_DRYRUN = $null
Assert ($r -like '*suppressed=debounced*') "DEBOUNCE_SECONDS suppresses a repeat"
Set-Conf 'DEBOUNCE_SECONDS' '2'

Write-Host "  (speak instead of chime)"
# Headless Windows Server has no audio device, so Speak() throws there and the
# notifier is supposed to fall back to a chime. Probe the capability first and
# assert whichever behaviour is actually correct for this machine.
$speechWorks = $false
try {
    Add-Type -AssemblyName System.Speech
    $probe = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $probe.Speak(' ')
    $probe.Dispose()
    $speechWorks = $true
} catch { $speechWorks = $false }

Set-Conf 'SPEAK' '1'
$r = Get-Decision 'blocked'
if ($speechWorks) {
    Assert ($r -like '*player=speech*') "SPEAK=1 routes through the speech synthesiser"
} else {
    Write-Host "        no working synthesiser on this machine, checking the fallback"
    Assert ($r -like '*player=SoundPlayer*' -or $r -like '*player=beep*') `
        "SPEAK=1 falls back to a sound when speech is unavailable"
}
Set-Conf 'SPEAK' '0'

Write-Host "  (each kind resolves to a distinct sound)"
Set-Conf 'PROJECT_PITCH' '0'
$sounds = @()
foreach ($k in @('done','blocked','limit','error')) {
    $d = Get-Decision $k
    if ($d -match 'sound=(.+?) player=') { $sounds += $matches[1] }
}
Check $sounds.Count 4 "all four kinds reported a sound"
Check (($sounds | Sort-Object -Unique).Count) 4 "all four sounds are different"

Write-Host "  (a malicious config cannot execute anything)"
Add-Content $c "MUTE=`$(New-Item -ItemType File -Path '$h\pwned')"
Get-Decision 'blocked' | Out-Null
Assert (-not (Test-Path (Join-Path $h 'pwned'))) "config is parsed, never invoked"

Write-Host "  (config survives a reinstall)"
Invoke-Installer -Home_ $h | Out-Null
Assert ((Get-Content $c -Raw) -like '*pwned*') "existing config left untouched by reinstall"
Remove-Item $h -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""

# --------------------------------------------------------------------------
Write-Host "case 8: per-event options"
# --------------------------------------------------------------------------
$h = New-TempHome
Invoke-Installer -Home_ $h | Out-Null
$n = Join-Path $h '.claude\claude-notify.ps1'
$c = Join-Path $h '.claude\claude-notify.conf'

# These cases only care what the notifier decided, not about hearing it, and a
# tray balloon costs five seconds each time. Dry run resolves everything and
# reports it without playing or notifying.
$env:CLAUDE_NOTIFY_DRYRUN = '1'

# The focus check would otherwise suppress every 'done' when these tests run
# from a focused terminal, and not on CI, which has no foreground window. Off,
# so the results do not depend on where the test happens to run.
Set-Conf 'SUPPRESS_WHEN_FOCUSED' '0'

# Pull one "name=value" field out of a decision line.
function Get-Field {
    param([string]$Line, [string]$Name)
    if ($Line -match "\s$Name=([^\s]*)") { return $matches[1] }
    return ''
}

Write-Host "  (each kind gets its own defaults)"
Check (Get-Field (Get-Decision 'done')    'pattern') '1x220' "done defaults to a single pulse"
Check (Get-Field (Get-Decision 'blocked') 'pattern') '2x220' "blocked defaults to two"
Check (Get-Field (Get-Decision 'limit')   'pattern') '3x140' "limit defaults to three, tighter"
Check (Get-Field (Get-Decision 'done')    'volume')  '70'    "done is quieter than the alerts"
Check (Get-Field (Get-Decision 'blocked') 'volume')  '100'   "blocked is at full volume"

Write-Host "  (patterns are configurable)"
Set-Conf 'DONE_PATTERN' '4x90'
Check (Get-Field (Get-Decision 'done') 'pattern') '4x90'  "DONE_PATTERN is honoured"
Set-Conf 'DONE_PATTERN' 'nonsense'
Check (Get-Field (Get-Decision 'done') 'pattern') '1x220' "a malformed pattern falls back to one pulse"
Set-Conf 'DONE_PATTERN' '99'
Check (Get-Field (Get-Decision 'done') 'pattern') '6x220' "an absurd repeat count is capped"
Set-Conf 'DONE_PATTERN' '1'

Write-Host "  (volume is clamped)"
Set-Conf 'DONE_VOLUME' '500'
Check (Get-Field (Get-Decision 'done') 'volume') '100' "volume above 100 is clamped"
Set-Conf 'DONE_VOLUME' 'abc'
Check (Get-Field (Get-Decision 'done') 'volume') '100' "a non-numeric volume falls back"
Set-Conf 'DONE_VOLUME' '70'

Write-Host "  (per-event disable)"
Set-Conf 'DONE_ENABLED' '0'
Assert ((Get-Decision 'done') -like '*suppressed=muted*')    "DONE_ENABLED=0 silences just that kind"
Assert ((Get-Decision 'blocked') -notlike '*suppressed=*')   "other kinds unaffected"
Set-Conf 'DONE_ENABLED' '1'

Write-Host "  (quiet hours)"
Set-Conf 'QUIET_HOURS' '00:00-23:59'
Assert ((Get-Decision 'blocked') -like '*suppressed=quiet-hours*') "an all-day window silences even ALWAYS_ALERT kinds"
Set-Conf 'QUIET_HOURS' '00:00-00:01'
Assert ((Get-Decision 'blocked') -notlike '*suppressed=quiet-hours*') "outside the window it alerts normally"
Set-Conf 'QUIET_HOURS' 'not-a-window'
Assert ((Get-Decision 'blocked') -notlike '*suppressed=quiet-hours*') "an unparseable window is ignored"
Set-Conf 'QUIET_HOURS' ''

Write-Host "  (phone push is off unless a topic is set)"
# Not dry run: the push is deliberately skipped there. With no topic set,
# nothing leaves the machine.
function Get-PushField {
    param([string]$Kind)
    Remove-Item (Join-Path $env:TEMP 'claude-notify.last') -Force -ErrorAction SilentlyContinue
    $prev = $env:USERPROFILE
    # DRYRUN off: the push is deliberately skipped in a dry run and would
    # never be exercised otherwise.
    $prevDry = $env:CLAUDE_NOTIFY_DRYRUN
    $env:CLAUDE_NOTIFY_DRYRUN = $null
    $env:USERPROFILE = $h; $env:CLAUDE_NOTIFY_FORCE = '1'; $env:CLAUDE_NOTIFY_DEBUG = '1'
    try {
        $out = '{}' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $n -Kind $Kind 2>$null
        return (Get-Field ($out | Out-String).Trim() 'pushed')
    } finally {
        $env:USERPROFILE = $prev
        $env:CLAUDE_NOTIFY_DRYRUN = $prevDry
        $env:CLAUDE_NOTIFY_FORCE = $null; $env:CLAUDE_NOTIFY_DEBUG = $null
    }
}
Check (Get-PushField 'blocked') 'no' "no topic means no push"
Set-Conf 'NTFY_TOPIC' 'test-topic'
Set-Conf 'NTFY_SERVER' 'http://127.0.0.1:9'
# Nothing is listening on port 9, so this exercises the failure path: the
# push is reported as failed and the alert still completed.
Check (Get-PushField 'blocked') 'failed' "an unreachable server is reported, not fatal"
Check (Get-PushField 'done') 'no' "finished turns are not pushed by default"
Set-Conf 'NTFY_TOPIC' ''

Write-Host "  (a temporary mute expires by itself)"
$future = [int][double]::Parse((Get-Date -UFormat %s)) + 3600
Set-Conf 'MUTE_UNTIL' "$future"
Assert ((Get-Decision 'blocked') -like '*suppressed=quiet-until*') "a future MUTE_UNTIL silences everything"
Set-Conf 'MUTE_UNTIL' '1'
Assert ((Get-Decision 'blocked') -notlike '*suppressed=quiet-until*') "an expired MUTE_UNTIL is ignored"
Set-Conf 'MUTE_UNTIL' 'not-a-time'
Assert ((Get-Decision 'blocked') -notlike '*suppressed=quiet-until*') "an unparseable MUTE_UNTIL is ignored"
Set-Conf 'MUTE_UNTIL' ''

Write-Host "  (a per-event sound file overrides the built-in choice)"
$custom = Join-Path $h 'custom.wav'
Copy-Item (Join-Path $env:SystemRoot 'Media\Windows Ding.wav') $custom -ErrorAction SilentlyContinue
if (Test-Path $custom) {
    Set-Conf 'DONE_SOUND' $custom
    Assert ((Get-Field (Get-Decision 'done') 'sound') -like '*custom.wav') "DONE_SOUND takes precedence"
    Set-Conf 'DONE_SOUND' ''
} else {
    Write-Host "        no system wav to copy, skipping"
}
Write-Host "  (bundled sounds)"
Set-Conf 'DONE_SOUND' ''   # the previous case pointed this at a custom file
$sd = Join-Path $h '.claude\claude-sounds'
$wavs = @(Get-ChildItem $sd -Filter '*.wav' -Recurse -ErrorAction SilentlyContinue)
Assert ($wavs.Count -ge 9) "the installer wrote $($wavs.Count) sounds"

# Valid RIFF/WAVE headers, not just files of the right name.
$badWav = $false
foreach ($w in $wavs) {
    $bytes = [System.IO.File]::ReadAllBytes($w.FullName)
    if ($bytes.Length -lt 1000) { $badWav = $true; continue }
    if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'RIFF') { $badWav = $true }
    if ([Text.Encoding]::ASCII.GetString($bytes, 8, 4) -ne 'WAVE') { $badWav = $true }
}
Assert (-not $badWav) "every bundled sound is a valid WAV"

# The whole point of bundling: whatever this Windows image ships, every kind
# still gets a real sound rather than a console beep.
$picked = @()
foreach ($k in @('done','blocked','limit','error')) {
    $s = Get-Field (Get-Decision $k) 'sound'
    $picked += (Split-Path $s -Leaf)
    Assert ($s -like '*claude-sounds*') "$k resolves to a bundled sound"
}
Check (($picked | Sort-Object -Unique).Count) 4 "the four kinds resolve to four different sounds"

Write-Host "  (sound packs)"
Assert (Test-Path (Join-Path $sd 'default')) "the default pack is a folder"
Assert ((Get-Field (Get-Decision 'done') 'sound') -like '*\default\*') "sounds resolve from the default pack"

# A pack is just a folder, so one file is enough to override that one sound.
New-Item -ItemType Directory -Path (Join-Path $sd 'retro') -Force | Out-Null
Copy-Item (Join-Path $sd 'default\alert-limit.wav') (Join-Path $sd 'retro\chime-glass.wav')
Set-Conf 'SOUND_PACK' 'retro'
Assert ((Get-Field (Get-Decision 'done') 'sound') -like '*\retro\chime-glass.wav') "the selected pack takes precedence"
# The pack has no alert-attention, so that one must fall back rather than vanish.
Assert ((Get-Field (Get-Decision 'blocked') 'sound') -like '*\default\alert-attention.wav') "a partial pack falls back to default per sound"

# A pack name is a directory component, never a path.
Set-Conf 'SOUND_PACK' '..\..\..\Windows'
Assert ((Get-Field (Get-Decision 'done') 'sound') -like '*\default\*') "a traversal in the pack name is refused"
Set-Conf 'SOUND_PACK' 'default'

$env:CLAUDE_NOTIFY_DRYRUN = $null
Remove-Item $h -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""

# --------------------------------------------------------------------------
Write-Host "passed $script:Pass, failed $script:Fail"
if ($script:Fail -gt 0) { exit 1 }
exit 0
