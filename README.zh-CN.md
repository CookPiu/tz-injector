# tz-injector

让指定的 Windows 桌面应用以你选择的时区运行，不修改系统时区。

这是一个 Windows 10/11 上的 PowerShell 看门狗。它保证配置里的应用无论从哪里启动（开始菜单、任务栏、Store 磁贴、`claude://` 之类的协议链接、登录后自动恢复的应用）都带着进程级 `TZ` 环境变量。**Claude Desktop**、**ChatGPT** 这类 Electron 应用会把 `TZ` 应用到主进程和全部渲染进程，页面里的 `Intl.DateTimeFormat`、`Date` 读到的就是你指定的时区，而 Windows 其余部分保持真实时区。

## 原理

看门狗每 700 ms 轮询一次各应用的主进程（命令行不含 `--type=` 的那个），直接从该进程的环境块读取 `TZ`（`NtQueryInformationProcess` → PEB → `RTL_USER_PROCESS_PARAMETERS.Environment`），然后：

| 发现的主进程 | 处理 |
| --- | --- |
| 已带正确的 `TZ` | 不动 |
| `TZ` 缺失或不符，且启动不到 20 秒 | 结束整棵进程树，用原始命令行参数加 `TZ` 重新启动 |
| `TZ` 缺失或不符，但已运行超过 20 秒 | 只写日志，绝不结束已经在用的应用 |

同一应用每分钟最多接管 3 次，超过则暂停 5 分钟。唯一可见的影响是从其他入口首次启动时窗口闪一下，约一秒。`config.json` 改动后自动重新加载。

已在 Windows 11 上用 Microsoft Store 版 Claude Desktop（Electron 44）、ChatGPT 和 Obsidian 验证。这是 Electron 的行为：Windows 上它会把 `TZ` 应用到自己的所有进程。纯 Chromium 浏览器（Edge、Chrome）不认 `TZ`，那种场景要用 `chrome.debugger` 扩展。

## 要求

- Windows 10/11 x64
- [PowerShell 7](https://aka.ms/powershell)（`pwsh`）
- 不需要管理员权限

## 安装

```powershell
git clone https://github.com/CookPiu/tz-injector.git
cd tz-injector
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -TimeZone America/Los_Angeles
```

`install.ps1` 会用 IANA 时区库校验名称，写入 `config.json`，为当前用户注册一个隐藏的计划任务（登录时启动，每 10 分钟自检一次，互斥体保证单实例），并立即启动看门狗。已经在运行的应用不会被动；加 `-RestartAppsNow` 才会用新时区重启它们（会结束进程树，先保存工作）。

之后改时区用同一条命令：

```powershell
.\install.ps1 -TimeZone Asia/Tokyo -RestartAppsNow
```

查看状态：

```powershell
.\status.ps1
```

卸载：

```powershell
.\uninstall.ps1
```

## 配置

`config.json`：

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

- `timeZone`：所有应用的默认 IANA 时区。
- `apps[].name`：进程映像名。
- `apps[].pathLike`：可执行文件路径通配，避免误伤同名进程（Claude Desktop 自带的 CLI 也叫 `claude.exe`），包升级后路径变化也不受影响。
- `apps[].timeZone`：可选，按应用单独指定。
- `maxAgeSeconds`：运行超过这个秒数的进程绝不重启。

任何 Electron 应用都可以加进来。非 Electron 应用只有自己读 `TZ` 的才有效（Node.js 认，Python、.NET、Win32 不认）。

## 边界

`TZ` 改变的是 JavaScript 和 Node.js 看到的时区，不改变 Windows 时区，所以凡是向 Win32 或 .NET 询问本地时区的东西（`Get-Date`、`tzutil`、`%TIME%`）仍是真实值。在 Claude Code 这类 agent 里，模型自己的日期和 JavaScript 世界用注入的时区，而它执行的 shell 命令报告系统时区。Python 的 CRT 会把 `TZ` 里的 IANA 名称解析成错误的偏移，不要对 Python 应用注入。

网页服务到底用不用客户端时区，由服务方决定。

## 文件

| 文件 | 用途 |
| --- | --- |
| `tz-injector.ps1` | 看门狗本体，含读取其他进程环境块的 C# 辅助类 |
| `install.ps1` | 校验时区、写配置、注册并启动任务 |
| `status.ps1` | 显示任务状态、各应用期望与实际的 `TZ` |
| `uninstall.ps1` | 删任务、停看门狗 |
| `config.json` | 时区与应用列表 |
| `watchdog.log` | 与脚本同目录，超过 512 KB 自动截断 |

## 许可证

MIT
