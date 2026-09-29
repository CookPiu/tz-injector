# Start every configured app that is not already running, with TZ set.
# Used by the optional "launch apps at logon" task; can also be run by hand.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = Get-Content -LiteralPath (Join-Path $here 'config.json') -Raw | ConvertFrom-Json

function Resolve-AppExe($app) {
  if ($app.exe -and (Test-Path -LiteralPath $app.exe)) { return $app.exe }          # explicit path for non-Store apps
  if ($app.package) {                                                                   # Store/MSIX package
    $pkg = Get-AppxPackage -Name $app.package -ErrorAction SilentlyContinue | Sort-Object { [Version]$_.Version } -Descending | Select-Object -First 1
    if ($pkg) {
      $tail = $app.pathLike.Substring($app.pathLike.LastIndexOf('*') + 1)             # e.g. \app\claude.exe
      $candidate = $pkg.InstallLocation + $tail
      if ((Test-Path -LiteralPath $candidate) -and ($candidate -like $app.pathLike)) { return $candidate }
    }
  }
  return $null
}

# "PackageFamilyName!AppId" of the Store/MSIX app whose entry point is $exe, $null for other apps
function Get-AppUserModelId($app, [string]$exe) {
  if (-not $app.package) { return $null }
  $pkg = Get-AppxPackage -Name $app.package -ErrorAction SilentlyContinue | Sort-Object { [Version]$_.Version } -Descending | Select-Object -First 1
  if (-not $pkg) { return $null }
  $entry = (Get-AppxPackageManifest $pkg).Package.Applications.Application |
    Where-Object { (Join-Path $pkg.InstallLocation ($_.Executable -replace '/', '\')) -ieq $exe } | Select-Object -First 1
  if ($entry) { return "$($pkg.PackageFamilyName)!$($entry.Id)" }
  return $null
}

foreach ($app in $cfg.apps) {
  $running = Get-CimInstance Win32_Process -Filter "Name='$($app.name)'" | Where-Object { $_.CommandLine -notmatch '--type=' -and $_.ExecutablePath -like $app.pathLike }
  if ($running) { Write-Host "$($app.name): already running"; continue }
  $exe = Resolve-AppExe $app
  if (-not $exe) { Write-Warning "$($app.name): executable not found (set 'package' or 'exe' in config.json)"; continue }
  $tz = if ($app.timeZone) { $app.timeZone } else { $cfg.timeZone }
  & (Join-Path $here 'start-app.ps1') -Exe $exe -TimeZone $tz -AppUserModelId (Get-AppUserModelId $app $exe) | Out-Null
  Write-Host "$($app.name): started with TZ=$tz"
}
