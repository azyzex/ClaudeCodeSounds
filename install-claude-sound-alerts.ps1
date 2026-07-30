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
   ~/.claude/settings.json         backed up, then four hook entries added

 SAFE TO RE-RUN. It replaces its own hook entries and leaves everything
 else in settings.json alone.

 UNINSTALL
   powershell -ExecutionPolicy Bypass -File .\install-claude-sound-alerts.ps1 -Uninstall
================================================================================
#>

[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'

$claudeDir    = Join-Path $env:USERPROFILE '.claude'
$notifyScript = Join-Path $claudeDir 'claude-notify.ps1'
$settingsPath = Join-Path $claudeDir 'settings.json'
$marker       = 'claude-notify.ps1'   # how we recognise our own hook entries

function Write-Step($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  $msg" -ForegroundColor Yellow }

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

# ----------------------------------------------------------------- settings ---

if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
    Write-Step "created $claudeDir"
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

# These are the four lifecycle events that matter. Matcher values come from
# the hooks reference: code.claude.com/docs/en/hooks
$wiring = @(
    @{ Event = 'Stop';         Kind = 'done';    Matcher = $null }
    @{ Event = 'Notification'; Kind = 'blocked'; Matcher = 'permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog' }
    @{ Event = 'StopFailure';  Kind = 'limit';   Matcher = 'rate_limit' }
    @{ Event = 'StopFailure';  Kind = 'error';   Matcher = 'overloaded|authentication_failed|oauth_org_not_allowed|billing_error|invalid_request|model_not_found|server_error|max_output_tokens|unknown' }
)

# Clear our old entries first, so re-running never stacks duplicates.
# Elicitation is in the list only to clean up: earlier setups wired it directly,
# but Notification already covers it via the elicitation_dialog matcher.
$ourEvents = @('Stop', 'Notification', 'StopFailure', 'Elicitation')

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
Write-Ok "wired 4 hooks into settings.json"

# ------------------------------------------------------- the notifier script ---

$notifyBody = @'
#requires -version 5
<#
  Claude Code notifier. Called by the hooks in ~/.claude/settings.json.

    -Kind done     turn finished                    sound only
    -Kind blocked  waiting on you                   sound + tray popup
    -Kind limit    usage limit hit                  sound + tray popup
    -Kind error    other API error                  sound + tray popup

  Set $ToastOnDone to $true if you want a popup on every finish too.
#>
param([ValidateSet('done','blocked','limit','error')][string]$Kind = 'done')

$ErrorActionPreference = 'SilentlyContinue'
$ToastOnDone = $false

# --- debounce -----------------------------------------------------------------
# Several of these events can fire inside the same second. Without this you get
# a stutter of overlapping audio.
$stamp = Join-Path $env:TEMP 'claude-notify.last'
if (Test-Path $stamp) {
    if (((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalSeconds -lt 2.5) { exit 0 }
}
Set-Content -Path $stamp -Value $Kind -Encoding ascii

# --- read the hook payload ----------------------------------------------------
# Claude Code sends the event JSON on stdin. Notification events carry .message
$detail = ''
try {
    if ([Console]::IsInputRedirected) {
        $stdin = [Console]::In.ReadToEnd()
        if ($stdin -and $stdin.Trim()) {
            $obj = ConvertFrom-Json $stdin
            foreach ($f in 'message','reason','error_type','last_assistant_message') {
                if (-not $detail -and $obj.$f) { $detail = [string]$obj.$f }
            }
        }
    }
} catch { }

# --- pick sound and text ------------------------------------------------------
switch ($Kind) {
    'blocked' {
        $wavs     = @('Windows Exclamation.wav','Windows Notify Messaging.wav','chord.wav')
        $title    = 'Claude needs you'
        $fallback = 'Waiting on your input or a permission prompt'
        $icon     = 'Warning'; $freq = 740
    }
    'limit' {
        $wavs     = @('Windows Critical Stop.wav','Windows Foreground.wav','chord.wav')
        $title    = 'Claude hit the usage limit'
        $fallback = 'Rate limited. The turn ended early.'
        $icon     = 'Error'; $freq = 440
    }
    'error' {
        $wavs     = @('Windows Critical Stop.wav','Windows Hardware Fail.wav','chord.wav')
        $title    = 'Claude stopped'
        $fallback = 'The turn ended on an API error'
        $icon     = 'Error'; $freq = 494
    }
    default {
        $wavs     = @('Windows Notify System Generic.wav','notify.wav','Windows Ding.wav','chimes.wav')
        $title    = 'Claude is done'
        $fallback = 'Turn finished'
        $icon     = 'Info'; $freq = 988
    }
}
if (-not $detail) { $detail = $fallback }
if ($detail.Length -gt 180) { $detail = $detail.Substring(0,177) + '...' }

# --- play ---------------------------------------------------------------------
$played = $false
foreach ($w in $wavs) {
    $p = Join-Path $env:SystemRoot "Media\$w"
    if (Test-Path $p) {
        try {
            $player = New-Object System.Media.SoundPlayer $p
            $player.PlaySync()
            if ($Kind -ne 'done') { Start-Sleep -Milliseconds 220; $player.PlaySync() }
            $played = $true
        } catch { }
        break
    }
}
if (-not $played) {
    [Console]::Beep($freq, 220)
    if ($Kind -ne 'done') { Start-Sleep -Milliseconds 120; [Console]::Beep($freq, 220) }
}

if ($Kind -eq 'done' -and -not $ToastOnDone) { exit 0 }

# --- tray balloon -------------------------------------------------------------
# A balloon tip, not a message box. It does not steal keyboard focus.
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon    = [System.Drawing.SystemIcons]::Information
    $tray.Visible = $true
    $tray.ShowBalloonTip(8000, $title, $detail, [System.Windows.Forms.ToolTipIcon]::$icon)
    Start-Sleep -Seconds 5
    $tray.Dispose()
} catch { }
'@

Set-Content -Path $notifyScript -Value $notifyBody -Encoding utf8
Write-Ok "wrote $notifyScript"

# --------------------------------------------------------------------- test ---

Write-Host ""
# Set NO_TEST_TONE=1 to skip this, for unattended installs and CI.
if ($env:NO_TEST_TONE -eq '1') {
    Write-Step "test tone skipped (NO_TEST_TONE=1)"
} else {
    Write-Step "test tone..."
    Remove-Item (Join-Path $env:TEMP 'claude-notify.last') -Force -ErrorAction SilentlyContinue
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $notifyScript -Kind done
}

Write-Host ""
Write-Ok "Done. Restart Claude Code, then run /hooks to confirm all four are listed."
Write-Host "  Silence everything:  set `"disableAllHooks`": true in settings.json" -ForegroundColor DarkGray
Write-Host "  Nothing firing?      run claude --debug and watch the hook lines"    -ForegroundColor DarkGray
Write-Host ""
