<#
.SYNOPSIS
  Watchdog that makes selected Windows desktop apps (Electron-based, e.g. Claude Desktop and
  ChatGPT) always run with a process-level TZ environment variable, without changing the
  system time zone.
.DESCRIPTION
  Every pollMs milliseconds the main process of each configured app is inspected (the one whose
  command line has no --type= switch). The TZ variable is read straight from the target
  process's environment block (PEB -> RTL_USER_PROCESS_PARAMETERS -> Environment):
    - TZ already equals the wanted zone: leave it alone.
    - TZ missing or different and the process is younger than maxAgeSeconds: kill the whole
      process tree and start the app again with the original command-line arguments plus TZ.
    - TZ missing but the process is older (it was running before the watchdog started): log
      only, never kill work in progress.
  Per app at most 3 relaunches per 60 s; above that the app is left alone for 5 minutes.
  config.json is re-read whenever its modification time changes, so a time zone change takes
  effect without restarting the watchdog.
  Registered as a hidden logon task by install.ps1.
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)
$ErrorActionPreference = 'Continue'

# single instance
$mutex = New-Object System.Threading.Mutex($false, 'Local\tz-injector-watchdog')
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

$logFile = Join-Path $PSScriptRoot 'watchdog.log'
$taskkill = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'

function Log([string]$msg) {
  try {
    $line = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg
    [IO.File]::AppendAllText($logFile, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    if ((Get-Item -LiteralPath $logFile).Length -gt 524288) {
      $tail = Get-Content -LiteralPath $logFile -Tail 200
      [IO.File]::WriteAllLines($logFile, $tail, [Text.UTF8Encoding]::new($false))
    }
  } catch {}
}

function Read-Config {
  $c = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
  if (-not $c.timeZone) { throw 'config.json: "timeZone" is required' }
  if (-not $c.apps -or $c.apps.Count -eq 0) { throw 'config.json: "apps" must list at least one app' }
  if (-not $c.pollMs) { $c | Add-Member -NotePropertyName pollMs -NotePropertyValue 700 }
  if (-not $c.maxAgeSeconds) { $c | Add-Member -NotePropertyName maxAgeSeconds -NotePropertyValue 20 }
  return $c
}

# Read an environment variable of another process of the same user (64-bit processes only).
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ProcEnv {
  [StructLayout(LayoutKind.Sequential)]
  struct PBI { public IntPtr Reserved1; public IntPtr PebBaseAddress; public IntPtr R2a; public IntPtr R2b; public IntPtr UniqueProcessId; public IntPtr R3; }
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PBI pbi, int len, out int ret);
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  static IntPtr ReadPtr(IntPtr h, IntPtr addr) {
    var b = new byte[8]; IntPtr r;
    if (!ReadProcessMemory(h, addr, b, (IntPtr)8, out r) || (long)r != 8) throw new Exception("ReadProcessMemory " + Marshal.GetLastWin32Error());
    return (IntPtr)BitConverter.ToInt64(b, 0);
  }
  // Returns the value, null when the variable is absent; throws when the block cannot be read.
  public static string GetVar(int pid, string name) {
    IntPtr h = OpenProcess(0x0400 | 0x0010, false, pid);
    if (h == IntPtr.Zero) throw new Exception("OpenProcess " + Marshal.GetLastWin32Error());
    try {
      PBI pbi = new PBI(); int ret;
      int st = NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(typeof(PBI)), out ret);
      if (st != 0) throw new Exception("NtQueryInformationProcess 0x" + st.ToString("X"));
      IntPtr pp = ReadPtr(h, (IntPtr)((long)pbi.PebBaseAddress + 0x20));   // PEB.ProcessParameters
      IntPtr env = ReadPtr(h, (IntPtr)((long)pp + 0x80));                  // RTL_USER_PROCESS_PARAMETERS.Environment
      var szb = new byte[8]; IntPtr rr;
      long size = 0;
      if (ReadProcessMemory(h, (IntPtr)((long)pp + 0x3F0), szb, (IntPtr)8, out rr)) size = BitConverter.ToInt64(szb, 0); // EnvironmentSize
      if (size <= 0 || size > 8 * 1024 * 1024) size = 256 * 1024;
      var buf = new byte[size];
      if (!ReadProcessMemory(h, env, buf, (IntPtr)size, out rr) && (long)rr == 0) throw new Exception("ReadProcessMemory(env) " + Marshal.GetLastWin32Error());
      string block = Encoding.Unicode.GetString(buf, 0, (int)rr);
      foreach (var e in block.Split('\0')) {
        if (e.Length > name.Length && e.StartsWith(name + "=", StringComparison.OrdinalIgnoreCase)) return e.Substring(name.Length + 1);
      }
      return null;
    } finally { CloseHandle(h); }
  }
}
'@

function Get-ArgsFromCommandLine([string]$cl) {
  if ([string]::IsNullOrWhiteSpace($cl)) { return '' }
  $cl = $cl.TrimStart()
  if ($cl.StartsWith('"')) {
    $end = $cl.IndexOf('"', 1)
    if ($end -lt 0) { return '' }
    return $cl.Substring($end + 1).Trim()
  }
  $sp = $cl.IndexOf(' ')
  if ($sp -lt 0) { return '' }
  return $cl.Substring($sp + 1).Trim()
}

function Get-AppConfig($cfg, [string]$procName) {
  $cfg.apps | Where-Object { $_.name -ieq $procName } | Select-Object -First 1
}

function Get-WantedTz($cfg, $app) {
  if ($app.timeZone) { return [string]$app.timeZone }
  return [string]$cfg.timeZone
}

function Get-MainProcesses($cfg) {
  $names = ($cfg.apps | ForEach-Object { "Name='$($_.name)'" }) -join ' OR '
  Get-CimInstance Win32_Process -Filter $names | Where-Object {
    $p = $_
    if ($p.CommandLine -match '--type=') { return $false }
    $app = Get-AppConfig $cfg $p.Name
    return ($null -ne $app) -and ($p.ExecutablePath -like $app.pathLike)
  }
}

function Relaunch($proc, [string]$tz) {
  $args = Get-ArgsFromCommandLine $proc.CommandLine
  $exe = $proc.ExecutablePath
  & $taskkill /PID $proc.ProcessId /T /F 2>&1 | Out-Null
  Start-Sleep -Milliseconds 800
  $si = New-Object System.Diagnostics.ProcessStartInfo
  $si.FileName = $exe
  $si.WorkingDirectory = Split-Path -Parent $exe
  $si.UseShellExecute = $false
  $si.Arguments = $args
  $si.EnvironmentVariables['TZ'] = $tz
  $np = [System.Diagnostics.Process]::Start($si)
  Log ("relaunched {0}: pid {1} -> {2}, args [{3}], TZ={4}" -f $proc.Name, $proc.ProcessId, $np.Id, $args, $tz)
}

$cfg = Read-Config
$cfgStamp = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
$seen = @{}          # pid -> 'ok' | 'skip' | 'relaunched'
$relaunches = @{}    # app name -> datetime[]
$pausedUntil = @{}   # app name -> datetime
Log ("watchdog started: TZ={0}, apps={1}" -f $cfg.timeZone, (($cfg.apps | ForEach-Object { $_.name + $(if ($_.timeZone) { "($($_.timeZone))" }) }) -join ', '))

while ($true) {
  try {
    # hot reload
    $stamp = (Get-Item -LiteralPath $ConfigPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
    if ($stamp -and $stamp -ne $cfgStamp) {
      try {
        $cfg = Read-Config; $cfgStamp = $stamp
        $seen.Clear()   # re-evaluate running processes against the new zone
        Log ("config reloaded: TZ={0}" -f $cfg.timeZone)
      } catch { Log ("config reload failed, keeping previous: {0}" -f $_.Exception.Message) }
    }

    $now = Get-Date
    $procs = @(Get-MainProcesses $cfg)
    $alive = @{}
    foreach ($p in $procs) {
      $alive[$p.ProcessId] = $true
      if ($seen.ContainsKey($p.ProcessId)) { continue }
      $app = Get-AppConfig $cfg $p.Name
      $wanted = Get-WantedTz $cfg $app
      $age = ($now - $p.CreationDate).TotalSeconds
      $tz = $null
      try { $tz = [ProcEnv]::GetVar([int]$p.ProcessId, 'TZ') }
      catch {
        # a process that has just been created may not be readable yet; give it 3 s
        if ($age -lt 3) { continue }
        Log ("cannot read environment of {0} pid {1}: {2}; skipped" -f $p.Name, $p.ProcessId, $_.Exception.Message)
        $seen[$p.ProcessId] = 'skip'; continue
      }
      if ($tz -eq $wanted) { $seen[$p.ProcessId] = 'ok'; continue }
      if ($age -gt $cfg.maxAgeSeconds) {
        Log ("{0} pid {1} has TZ=[{2}] but is {3:N0} s old; left alone to protect unsaved work" -f $p.Name, $p.ProcessId, $tz, $age)
        $seen[$p.ProcessId] = 'skip'; continue
      }
      if ($pausedUntil.ContainsKey($p.Name) -and $now -lt $pausedUntil[$p.Name]) {
        $seen[$p.ProcessId] = 'skip'; continue
      }
      $hist = @($relaunches[$p.Name] | Where-Object { $_ -gt $now.AddSeconds(-60) })
      if ($hist.Count -ge 3) {
        $pausedUntil[$p.Name] = $now.AddMinutes(5)
        Log ("{0}: 3 relaunches within 60 s, pausing for 5 minutes" -f $p.Name)
        $seen[$p.ProcessId] = 'skip'; continue
      }
      $seen[$p.ProcessId] = 'relaunched'
      $relaunches[$p.Name] = $hist + $now
      try { Relaunch $p $wanted } catch { Log ("relaunch of {0} failed: {1}" -f $p.Name, $_.Exception.Message) }
    }
    foreach ($k in @($seen.Keys)) { if (-not $alive.ContainsKey($k)) { $seen.Remove($k) } }
  } catch {
    Log ("poll error: {0}" -f $_.Exception.Message)
  }
  Start-Sleep -Milliseconds $cfg.pollMs
}
