# =============================================================================
#  claude-sounds - a small command for the sound alerts
# =============================================================================
#
#    claude-sounds status     is any of this actually working
#    claude-sounds limits     how much of your limit is left, and when it resets
#    claude-sounds log        recent alerts, and why some were skipped
#    claude-sounds test KIND  play one alert now (done, blocked, limit, error)
#    claude-sounds mute 1h    silence everything for a while (30m, 2h, off)
#
#  The Windows half of the Unix `claude-sounds`. Same files, same names, same
#  output, so a habit learned on one machine carries to the other.
#
#  Everything here reads or writes the files the notifier already uses. It keeps
#  no state of its own, so it can never disagree with what actually happens.
# =============================================================================

param(
    [ValidateSet('status', 'limits', 'log', 'test', 'mute', 'help')]
    [string]$Command = 'status',
    [string]$Arg = ''
)

$ErrorActionPreference = 'Stop'

$ClaudeDir = Join-Path $env:USERPROFILE '.claude'
$Conf      = Join-Path $ClaudeDir 'claude-notify.conf'
$Notifier  = Join-Path $ClaudeDir 'claude-notify.ps1'
$LogFile   = Join-Path $ClaudeDir 'claude-notify.log'
$Limits    = Join-Path $ClaudeDir 'claude-limits.json'
# One file per other surface, kept apart on purpose. See Show-Limits.
$LimitsD   = Join-Path $ClaudeDir 'claude-limits.d'
$Settings  = Join-Path $ClaudeDir 'settings.json'

function Write-Title($t) { Write-Host $t -ForegroundColor White }
function Write-Ok($m)    { Write-Host "  ok    $m" -ForegroundColor Green }
function Write-Warn($m)  { Write-Host "  warn  $m" -ForegroundColor Yellow }
function Write-Bad($m)   { Write-Host "  no    $m" -ForegroundColor Red }
function Write-Dim($m)   { Write-Host "        $m" -ForegroundColor DarkGray }

function Get-Field($Path, $Key) {
    if (-not (Test-Path $Path)) { return '' }
    $found = ''
    foreach ($line in (Get-Content $Path -ErrorAction SilentlyContinue)) {
        if ($line -match "^$Key=(.*)$") { $found = $matches[1].Trim() }
    }
    return $found
}

function ConvertFrom-Epoch($Value) {
    if ($Value -notmatch '^\d+$') { return $null }
    return [DateTimeOffset]::FromUnixTimeSeconds([int64]$Value).ToLocalTime()
}

# "01:35 (in 2h 0m)". The clock time matters more than the gap when you are
# deciding whether to wait, and the gap matters more when you are not.
function Format-When($Value) {
    $when = ConvertFrom-Epoch $Value
    if (-not $when) { return 'unknown' }
    $left = $when - [DateTimeOffset]::Now
    if ($left.TotalSeconds -le 0) { return "$($when.ToString('HH:mm')) (passed)" }
    # Floor, never [int]. A cast to int in PowerShell rounds to nearest rather
    # than truncating, so 1h59m40s became "2h 59m": the hours rounded up while
    # the minutes stayed put, and the countdown read an hour late.
    $gap = if ($left.TotalHours -ge 1) {
        '{0}h {1}m' -f [Math]::Floor($left.TotalHours), $left.Minutes
    } else {
        '{0}m' -f [Math]::Floor($left.TotalMinutes)
    }
    return "$($when.ToString('HH:mm')) (in $gap)"
}

function Format-Ago($Value) {
    $when = ConvertFrom-Epoch $Value
    if (-not $when) { return 'never' }
    $gone = [DateTimeOffset]::Now - $when
    if ($gone.TotalSeconds -lt 60)  { return 'just now' }
    if ($gone.TotalMinutes -lt 60)  { return '{0}m ago' -f [Math]::Floor($gone.TotalMinutes) }
    if ($gone.TotalHours -lt 24)    { return '{0}h ago' -f [Math]::Floor($gone.TotalHours) }
    return $when.ToString('d MMM HH:mm')
}

function Get-LimitFiles {
    $found = @()
    if (Test-Path $Limits) { $found += $Limits }
    if (Test-Path $LimitsD) {
        $found += (Get-ChildItem $LimitsD -Filter '*.conf' -File -ErrorAction SilentlyContinue |
                   ForEach-Object { $_.FullName })
    }
    return $found
}

function Show-Limits {
    # Every source, not just the one Claude Code writes. Other surfaces drop
    # their own file in claude-limits.d, tagged with the account they saw, and
    # those are deliberately not merged: the window is per account, so combining
    # two would report one account's reset time under the other's name.
    $files = @(Get-LimitFiles)
    if ($files.Count -eq 0) {
        Write-Host 'No limit figures yet.'
        Write-Host 'Open Claude Code once so its status line runs, or a claude.ai tab with'
        Write-Host 'the browser extension installed.'
        return
    }

    Write-Title 'Usage limits'
    $several = $files.Count -gt 1

    foreach ($f in $files) {
        # Only says where a figure came from when there is more than one, so the
        # ordinary single-source case stays as quiet as it was.
        if ($several) {
            Write-Host ''
            $src  = Get-Field $f 'source'
            $acct = Get-Field $f 'account'
            if (-not $src) { $src = 'claude code' }
            $label = if ($acct) { "from $src, account $acct" } else { "from $src" }
            Write-Dim $label
        }
        foreach ($w in @(@('5 hour', 'five_hour'), @('7 day', 'seven_day'))) {
            $used = Get-Field $f "$($w[1])_used"
            $at   = Get-Field $f "$($w[1])_resets_at"
            if (-not $used) { $used = '?' }
            Write-Host ('  {0,-8} {1,5}%  resets {2}' -f $w[0], $used, (Format-When $at))
        }
        $upd = Get-Field $f 'updated'
        if ($upd) { Write-Dim "last seen $(Format-Ago $upd)" }
    }
}

function Show-Status {
    Write-Title 'Claude Code Sounds'
    if (Test-Path $Notifier) { Write-Ok 'notifier installed' } else { Write-Bad 'notifier missing' }
    if (Test-Path $Conf)     { Write-Ok 'config present' }     else { Write-Warn 'no config, defaults apply' }

    if (Test-Path $Settings) {
        $raw = Get-Content $Settings -Raw -Encoding UTF8
        if ($raw -match 'claude-notify') { Write-Ok 'hooks registered' } else { Write-Bad 'hooks not registered' }
        if ($raw -match 'statusLine')    { Write-Ok 'status line set' }  else { Write-Warn 'no status line, so no reset alerts from Claude Code' }
    } else {
        Write-Bad 'no settings.json'
    }

    $mute = Get-Field $Conf 'MUTE_UNTIL'
    if ($mute -match '^\d+$' -and [int64]$mute -gt [DateTimeOffset]::Now.ToUnixTimeSeconds()) {
        Write-Warn "muted until $((ConvertFrom-Epoch $mute).ToString('HH:mm'))"
    } else {
        Write-Ok 'not muted'
    }

    if (@(Get-LimitFiles).Count -gt 0) {
        Write-Host ''
        Show-Limits
    }
}

function Show-Log($Count) {
    if (-not (Test-Path $LogFile)) { Write-Host 'Nothing logged yet.'; return }
    $n = 15
    if ($Count -match '^\d+$') { $n = [int]$Count }
    Write-Title "Last $n alerts"
    Get-Content $LogFile -Tail $n | ForEach-Object { Write-Host "  $_" }
}

function Invoke-Test($Kind) {
    if (-not $Kind) { $Kind = 'blocked' }
    if ($Kind -notin @('done', 'blocked', 'limit', 'error')) {
        Write-Host "Unknown kind: $Kind"
        Write-Host 'Try one of: done, blocked, limit, error'
        exit 2
    }
    if (-not (Test-Path $Notifier)) { Write-Bad 'notifier missing'; exit 1 }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Notifier -Kind $Kind
    Write-Ok "played $Kind"
}

function Set-Mute($Span) {
    if (-not $Span) { $Span = '60m' }
    $lines = @()
    if (Test-Path $Conf) {
        $lines = @(Get-Content $Conf | Where-Object { $_ -notmatch '^MUTE_UNTIL=' })
    }
    if ($Span -eq 'off') {
        Set-Content -Path $Conf -Value $lines -Encoding ascii
        Write-Ok 'unmuted'
        return
    }
    if ($Span -notmatch '^(\d+)([mh])$') {
        Write-Host "Cannot read '$Span'. Try 30m, 2h, or off."
        exit 2
    }
    $amount = [int]$matches[1]
    $secs = if ($matches[2] -eq 'h') { $amount * 3600 } else { $amount * 60 }
    # Stored as an expiry rather than a flag, so a mute you forget about turns
    # itself back on.
    $until = [DateTimeOffset]::Now.ToUnixTimeSeconds() + $secs
    Set-Content -Path $Conf -Value ($lines + "MUTE_UNTIL=$until") -Encoding ascii
    Write-Ok "muted until $((ConvertFrom-Epoch $until).ToString('HH:mm'))"
}

function Show-Usage {
    Get-Content $PSCommandPath | Select-Object -Skip 2 -First 13 |
        ForEach-Object { $_ -replace '^#\s{0,2}', '' }
}

switch ($Command) {
    'status' { Show-Status }
    'limits' { Show-Limits }
    'log'    { Show-Log $Arg }
    'test'   { Invoke-Test $Arg }
    'mute'   { Set-Mute $Arg }
    'help'   { Show-Usage }
}
