<#
.SYNOPSIS
  Start an app with TZ in its environment. Used by tz-injector.ps1, launch-apps.ps1 and install.ps1.
.DESCRIPTION
  With -AppUserModelId ("PackageFamilyName!AppId") the app is started inside its MSIX package container
  through Invoke-CommandInDesktopPackage (Windows PowerShell 5.1 Appx module), so it keeps its package
  identity. Starting a packaged exe by path gives an unpackaged process, and ChatGPT 26.924 and later
  refuse to start without package identity ("The process has no package identity").
  Invoke-CommandInDesktopPackage does not pass the caller's environment on, so it runs
  launch-with-tz.vbs, which sets TZ and starts the exe; -PreventBreakaway keeps that child inside the
  container. Without -AppUserModelId the exe is started directly with TZ.
  Returns "pid <n>" for a direct start and "package <AUMID>" for a packaged start.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Exe,
  [string]$Arguments = '',
  [Parameter(Mandatory)][string]$TimeZone,
  [string]$AppUserModelId
)
$ErrorActionPreference = 'Stop'

if ($AppUserModelId -and $AppUserModelId.Contains('!')) {
  $pfn, $appId = $AppUserModelId.Split('!', 2)
  $sys = [Environment]::SystemDirectory
  $inner = ('"{0}" {1} "{2}" {3}' -f (Join-Path $PSScriptRoot 'launch-with-tz.vbs'), $TimeZone, $Exe, $Arguments).TrimEnd()
  $cmd = "Invoke-CommandInDesktopPackage -PackageFamilyName '{0}' -AppId '{1}' -Command '{2}' -Args '{3}' -PreventBreakaway" -f $pfn, $appId, (Join-Path $sys 'wscript.exe'), ($inner -replace "'", "''")
  $out = & (Join-Path $sys 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -Command $cmd 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Invoke-CommandInDesktopPackage failed ($LASTEXITCODE): $($out -join ' ')" }
  return "package $AppUserModelId"
}

$si = New-Object System.Diagnostics.ProcessStartInfo
$si.FileName = $Exe
$si.WorkingDirectory = Split-Path -Parent $Exe
$si.UseShellExecute = $false
$si.Arguments = $Arguments
$si.EnvironmentVariables['TZ'] = $TimeZone
$np = [System.Diagnostics.Process]::Start($si)
return "pid $($np.Id)"
