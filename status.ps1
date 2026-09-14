# Show the watchdog state, the configured zones and the TZ each configured app is actually running with.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = Get-Content -LiteralPath (Join-Path $here 'config.json') -Raw | ConvertFrom-Json

$src = Get-Content -LiteralPath (Join-Path $here 'tz-injector.ps1') -Raw
$cs = [regex]::Match($src, "Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@", 'Singleline').Groups[1].Value
if (-not ('ProcEnv' -as [type])) { Add-Type -TypeDefinition $cs }

$task = Get-ScheduledTask -TaskName 'TZ Injector' -ErrorAction SilentlyContinue
$wd = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'tz-injector\.ps1' } | Select-Object -First 1
Write-Host ("Task      : {0}" -f $(if ($task) { 'registered' } else { 'not registered' }))
Write-Host ("Watchdog  : {0}" -f $(if ($wd) { "running (pid $($wd.ProcessId), since $($wd.CreationDate.ToString('yyyy-MM-dd HH:mm:ss')))" } else { 'not running' }))
Write-Host ("Default TZ: {0}" -f $cfg.timeZone)
Write-Host ''
Write-Host ('{0,-14} {1,-9} {2,-24} {3,-24} {4}' -f 'App', 'Pid', 'Wanted', 'Actual', 'State')
foreach ($app in $cfg.apps) {
  $wanted = if ($app.timeZone) { $app.timeZone } else { $cfg.timeZone }
  $mains = @(Get-CimInstance Win32_Process -Filter "Name='$($app.name)'" | Where-Object { $_.CommandLine -notmatch '--type=' -and $_.ExecutablePath -like $app.pathLike })
  if ($mains.Count -eq 0) { Write-Host ('{0,-14} {1,-9} {2,-24} {3,-24} {4}' -f $app.name, '-', $wanted, '-', 'not running'); continue }
  foreach ($m in $mains) {
    try { $actual = [ProcEnv]::GetVar([int]$m.ProcessId, 'TZ') } catch { $actual = "? ($($_.Exception.Message))" }
    $state = if ($actual -eq $wanted) { 'ok' } elseif ($null -eq $actual) { 'no TZ (started before install; restart it)' } else { 'mismatch' }
    Write-Host ('{0,-14} {1,-9} {2,-24} {3,-24} {4}' -f $app.name, $m.ProcessId, $wanted, ($actual ?? '(none)'), $state)
  }
}
$log = Join-Path $here 'watchdog.log'
if (Test-Path $log) { Write-Host ''; Write-Host 'Last log lines:'; Get-Content $log -Tail 5 | ForEach-Object { Write-Host "  $_" } }
