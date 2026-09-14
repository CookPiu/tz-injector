<#
.SYNOPSIS
  Install (or reconfigure) the TZ Injector watchdog as a hidden logon task for the current user.
  No administrator rights required.
.PARAMETER TimeZone
  IANA time zone to inject, e.g. America/Los_Angeles or Asia/Tokyo. Validated with the
  .NET/ICU time zone database. When given, config.json is updated before the watchdog starts.
.PARAMETER RestartAppsNow
  Also restart configured apps that are currently running with a different TZ. This kills
  their process trees, so save your work first. Without this switch running apps are left
  alone and only new launches are taken over.
.EXAMPLE
  .\install.ps1
  .\install.ps1 -TimeZone Asia/Tokyo
  .\install.ps1 -TimeZone Europe/Berlin -RestartAppsNow
#>
[CmdletBinding()]
param(
  [string]$TimeZone,
  [switch]$RestartAppsNow
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName = 'TZ Injector'
$configPath = Join-Path $here 'config.json'
$vbs = Join-Path $here 'run-hidden.vbs'
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { throw 'pwsh (PowerShell 7) not found. Install it from https://aka.ms/powershell' }

function Test-IanaTimeZone([string]$id) {
  $iana = $null
  if ([TimeZoneInfo]::TryConvertWindowsIdToIanaId($id, [ref]$iana)) {
    throw "'$id' is a Windows time zone id. Use the IANA name instead: $iana"
  }
  try { [TimeZoneInfo]::FindSystemTimeZoneById($id) | Out-Null }
  catch { throw "'$id' is not a known IANA time zone (examples: America/Los_Angeles, Europe/London, Asia/Tokyo, UTC)" }
}

$cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($TimeZone) {
  Test-IanaTimeZone $TimeZone
  $cfg.timeZone = $TimeZone
  ($cfg | ConvertTo-Json -Depth 5) + "`n" | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
  Write-Host "config.json: timeZone = $TimeZone"
} else {
  Test-IanaTimeZone $cfg.timeZone
}
foreach ($app in $cfg.apps) { if ($app.timeZone) { Test-IanaTimeZone $app.timeZone } }

# stop any running watchdog so the new one owns the mutex
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'tz-injector\.ps1' } | ForEach-Object {
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

# wscript launches pwsh without a console window
$vbsBody = @"
Option Explicit
Dim sh
Set sh = CreateObject("WScript.Shell")
sh.Run """$pwsh"" -NoProfile -ExecutionPolicy Bypass -File ""$(Join-Path $here 'tz-injector.ps1')""", 0, False
"@
Set-Content -LiteralPath $vbs -Value $vbsBody -Encoding ascii

$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wscript.exe" -Argument "//B //Nologo `"$vbs`"" -WorkingDirectory $here
# at logon, plus every 10 minutes as self-healing (the watchdog holds a mutex, duplicates exit at once)
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -Hidden
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
foreach ($old in @($taskName, 'TZ Injector (Claude, ChatGPT)')) {
  if (Get-ScheduledTask -TaskName $old -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $old -Confirm:$false }
}
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($triggerLogon, $triggerRepeat) -Settings $settings -Principal $principal -Description 'Keeps configured desktop apps running with a process-level TZ environment variable (per-app time zone without changing the system time zone).' | Out-Null
Start-ScheduledTask -TaskName $taskName
Start-Sleep 3
$running = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'tz-injector\.ps1' }
if ($running) { Write-Host "Installed. Task '$taskName' is registered and the watchdog is running (pid $($running.ProcessId))." }
else { Write-Warning "Task registered but no watchdog process found. See $(Join-Path $here 'watchdog.log')" }
Write-Host "Log: $(Join-Path $here 'watchdog.log')"

if ($RestartAppsNow) {
  foreach ($app in $cfg.apps) {
    $wanted = if ($app.timeZone) { $app.timeZone } else { $cfg.timeZone }
    $mains = Get-CimInstance Win32_Process -Filter "Name='$($app.name)'" | Where-Object { $_.CommandLine -notmatch '--type=' -and $_.ExecutablePath -like $app.pathLike }
    foreach ($m in $mains) {
      & "$([Environment]::SystemDirectory)\taskkill.exe" /PID $m.ProcessId /T /F 2>&1 | Out-Null
      Start-Sleep 1
      $si = New-Object System.Diagnostics.ProcessStartInfo
      $si.FileName = $m.ExecutablePath; $si.WorkingDirectory = Split-Path $m.ExecutablePath; $si.UseShellExecute = $false
      $si.EnvironmentVariables['TZ'] = $wanted
      [System.Diagnostics.Process]::Start($si) | Out-Null
      Write-Host "Restarted $($app.name) with TZ=$wanted"
    }
  }
}
