# Stop the watchdog until the next logon (or start.ps1). The task stays registered; running apps are not touched.
$ErrorActionPreference = 'Continue'
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'tz-injector\.ps1' } | ForEach-Object {
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  Write-Host "Stopped watchdog pid $($_.ProcessId)"
}
Write-Host 'Note: with the default install the 10-minute self-heal trigger starts it again. Use uninstall.ps1 or install.ps1 -StartAtLogon:$false to keep it off.'
