# Remove the logon task and stop the watchdog. Running apps are not touched.
$ErrorActionPreference = 'Continue'
foreach ($name in @('TZ Injector', 'TZ Injector (Claude, ChatGPT)')) {
  if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    Write-Host "Removed task '$name'"
  }
}
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'tz-injector\.ps1' } | ForEach-Object {
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  Write-Host "Stopped watchdog pid $($_.ProcessId)"
}
Write-Host 'Done. Apps started from now on get no TZ; running ones keep the TZ they were started with until restarted.'
