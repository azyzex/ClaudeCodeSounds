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
Check (Get-OurHookCounts $s) "Notification=1; Stop=1; StopFailure=2" "four hook groups across three events"
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
Check (Get-OurHookCounts $s) "Notification=1; PostToolUse=0; Stop=1; StopFailure=2" "still exactly four groups after three runs"
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
foreach ($kind in @('done', 'blocked', 'limit', 'error')) {
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
Write-Host "passed $script:Pass, failed $script:Fail"
if ($script:Fail -gt 0) { exit 1 }
exit 0
