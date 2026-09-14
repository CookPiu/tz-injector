# tz-injector

Run selected Windows desktop apps in a time zone of your choice without changing the system time zone.

`tz-injector` is a small PowerShell watchdog for Windows 10/11. It makes sure that configured apps always start with a process-level `TZ` environment variable, no matter how they are launched: Start menu, taskbar, Store tile, protocol links (`claude://`, ...) or "restart apps after sign-in". Electron-based apps such as **Claude Desktop** and **ChatGPT** apply `TZ` to their main process and to every renderer, so the pages inside them see the chosen zone in `Intl.DateTimeFormat`, `Date` and everything built on them, while the rest of Windows keeps the real time zone.

[中文说明](README.zh-CN.md)

## How it works

The watchdog polls the main process of each configured app (the one without a `--type=` switch) every 700 ms and reads `TZ` directly from that process's environment block (`NtQueryInformationProcess` → PEB → `RTL_USER_PROCESS_PARAMETERS.Environment`). Then:

| Main process found | Action |
| --- | --- |
| already has the wanted `TZ` | nothing |
| wrong or missing `TZ`, younger than 20 s | kill the process tree, start the app again with the original command-line arguments plus `TZ` |
| wrong or missing `TZ`, older than 20 s | log only; an app that was already running is never killed |

At most 3 relaunches per app per minute; after that the app is left alone for 5 minutes. The only visible effect is a short flicker (about one second) the first time an app is launched by other means. `config.json` is reloaded automatically when it changes.

Verified on Windows 11 with the Microsoft Store builds of Claude Desktop (Electron 44) and ChatGPT, and with Obsidian. The mechanism is Electron's: on Windows it applies `TZ` to all of its processes. Plain Chromium browsers (Edge, Chrome) ignore `TZ`; for those use a `chrome.debugger` extension instead.

## Requirements

- Windows 10/11 x64
- [PowerShell 7](https://aka.ms/powershell) (`pwsh`)
- no administrator rights

## Install

```powershell
git clone https://github.com/CookPiu/tz-injector.git
cd tz-injector
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -TimeZone America/Los_Angeles
```

`install.ps1` validates the zone against the IANA database, writes it to `config.json`, registers a hidden scheduled task for the current user (runs at logon and re-checks every 10 minutes; a mutex keeps it single-instance) and starts the watchdog immediately. Apps that are already running are not touched; add `-RestartAppsNow` to restart them with the new zone (this kills their process trees, save your work first).

Change the zone later with the same command:

```powershell
.\install.ps1 -TimeZone Asia/Tokyo -RestartAppsNow
```

Check what is going on:

```powershell
.\status.ps1
```

Remove everything:

```powershell
.\uninstall.ps1
```

## Configuration

`config.json`:

```json
{
  "timeZone": "America/Los_Angeles",
  "pollMs": 700,
  "maxAgeSeconds": 20,
  "apps": [
    { "name": "claude.exe",  "pathLike": "*\\WindowsApps\\Claude_*\\app\\claude.exe" },
    { "name": "ChatGPT.exe", "pathLike": "*\\WindowsApps\\OpenAI.Codex_*\\app\\ChatGPT.exe", "timeZone": "Europe/London" }
  ]
}
```

- `timeZone` — default IANA zone for all apps.
- `apps[].name` — process image name.
- `apps[].pathLike` — wildcard on the executable path; keeps the watchdog away from unrelated processes with the same name (Claude Desktop, for example, also ships a `claude.exe` CLI) and survives package upgrades.
- `apps[].timeZone` — optional per-app override.
- `maxAgeSeconds` — a process older than this is never relaunched.

Any Electron app can be added. Non-Electron apps only benefit if they read `TZ` themselves (Node.js does; Python, .NET and Win32 do not).

## What it does not cover

`TZ` changes what JavaScript and Node.js see. It does not change the Windows time zone, so anything that asks Win32 or .NET for the local zone (`Get-Date`, `tzutil`, `%TIME%`) still reports the real one. Inside an agent such as Claude Code this means the model's own date and its JavaScript world use the injected zone, while shell commands it runs report the system zone. Python's CRT mis-parses IANA names in `TZ` and produces a wrong offset; avoid injecting into Python-based apps.

Whether a web service actually uses the client time zone is up to the service.

## Files

| File | Purpose |
| --- | --- |
| `tz-injector.ps1` | the watchdog, including a small C# helper that reads another process's environment |
| `install.ps1` | validate zone, write config, register and start the task |
| `status.ps1` | show task state, wanted vs. actual `TZ` of each app |
| `uninstall.ps1` | remove task, stop watchdog |
| `config.json` | zones and app list |
| `watchdog.log` | written next to the scripts, truncated at 512 KB |

## License

MIT
