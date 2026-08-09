#requires -version 5
<#
  Claude Code sound alerts - status line (Windows)

  Claude Code runs this to draw the bar at the bottom of the terminal, handing
  it session data on stdin. That data includes the one thing this project could
  not otherwise know:

      "rate_limits": {
        "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
        "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
      }

  Those numbers come from Anthropic, so they already account for every surface
  you use: this terminal, the web, the phone, another machine. Reading them
  costs nothing, because Claude Code draws this bar regardless.

  So this script does two jobs:

    1. print a status line, which is what Claude Code asked for
    2. save the reset times, so the notifier can alert when they pass

  It must stay quick and it must never fail loudly: it runs constantly, and a
  broken status line is a broken looking editor.
#>

$ErrorActionPreference = 'SilentlyContinue'

$claudeDir = Join-Path $env:USERPROFILE '.claude'
$limits    = Join-Path $claudeDir 'claude-limits.json'
$notifier  = Join-Path $claudeDir 'claude-notify.ps1'

$payload = [Console]::In.ReadToEnd()
if (-not $payload) { exit 0 }

# Pulled out with a regex rather than ConvertFrom-Json on purpose. This runs on
# every redraw, and the shape here is flat and known, so the cheaper route is
# the right one. Anything unexpected simply yields nothing.
function Get-Field {
    param([string]$Window, [string]$Key)
    if ($payload -match "`"$Window`"\s*:\s*\{[^}]*`"$Key`"\s*:\s*([0-9.]+)") {
        return $matches[1]
    }
    return ''
}

$fivePct = Get-Field 'five_hour' 'used_percentage'
$fiveAt  = Get-Field 'five_hour' 'resets_at'
$weekPct = Get-Field 'seven_day' 'used_percentage'
$weekAt  = Get-Field 'seven_day' 'resets_at'

# --- save what was learned ----------------------------------------------------
# Written whenever a reset time is present, so the notifier has something to
# watch even after Claude Code closes. Plain key=value, for the same reason the
# config is: anything can read it without a parser.
if ($fiveAt -and (Test-Path $claudeDir)) {
    try {
        $lines = @(
            "updated=$([int][double]::Parse((Get-Date -UFormat %s)))",
            "five_hour_resets_at=$fiveAt"
        )
        if ($fivePct) { $lines += "five_hour_used=$fivePct" }
        if ($weekAt)  { $lines += "seven_day_resets_at=$weekAt" }
        if ($weekPct) { $lines += "seven_day_used=$weekPct" }
        [System.IO.File]::WriteAllLines($limits, $lines)
    } catch { }

    # Make sure something is watching the clock. The notifier's watcher exits
    # once nothing is pending, so it needs starting again when a reset appears.
    try {
        $alive = Join-Path $claudeDir 'claude-watch-alive'
        $running = $false
        if (Test-Path $alive) {
            $last = (Get-Content $alive -Raw).Trim()
            if ($last -match '^\d+$') {
                $now = [int][double]::Parse((Get-Date -UFormat %s))
                $running = ($now - [int]$last) -lt 150
            }
        }
        if (-not $running -and (Test-Path $notifier)) {
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $notifier, '-Kind', 'watch'
            )
        }
    } catch { }
}

# --- draw the bar -------------------------------------------------------------
# Only installed when there was no status line already, so it has to be useful
# on its own rather than assuming someone will style it.
$model = ''
if ($payload -match '"display_name"\s*:\s*"([^"]*)"') { $model = $matches[1] }
$dir = ''
if ($payload -match '"current_dir"\s*:\s*"([^"]*)"') { $dir = Split-Path $matches[1].Replace('\\', '\') -Leaf }

$parts = @()
if ($model) { $parts += $model }
if ($dir)   { $parts += $dir }

if ($fivePct -and $fiveAt) {
    $pct = [int][double]$fivePct
    $when = ''
    try {
        $when = [DateTimeOffset]::FromUnixTimeSeconds([int64]$fiveAt).LocalDateTime.ToString('HH:mm')
    } catch { }
    $parts += if ($when) { "$pct% used, resets $when" } else { "$pct% used" }
}

Write-Output ($parts -join ' - ')
