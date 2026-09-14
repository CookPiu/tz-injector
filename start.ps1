# Start the watchdog now (for installs made with -StartAtLogon:$false, or after stop.ps1).
$ErrorActionPreference = 'Stop'
if (-not (Get-ScheduledTask -TaskName 'TZ Injector' -ErrorAction SilentlyContinue)) { throw "Task 'TZ Injector' is not registered. Run install.ps1 first." }
Start-ScheduledTask -TaskName 'TZ Injector'
Start-Sleep 3
$wd = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'tz-injector\.ps1' } | Select-Object -First 1
if ($wd) { Write-Host "Watchdog running (pid $($wd.ProcessId))." } else { Write-Warning 'Watchdog did not start; see watchdog.log' }
