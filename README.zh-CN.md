# tz-injector

让 Windows 上的 Claude Desktop 和 ChatGPT 以你选择的时区运行，不修改系统时区。

这是一个 Windows 10/11 上的 PowerShell 看门狗。它保证这两个应用无论从哪里启动（开始菜单、任务栏、Store 磁贴、`claude://` 之类的协议链接、登录后自动恢复的应用）都带着进程级 `TZ` 环境变量。两者都是 Electron 应用，Electron 会把 `TZ` 应用到主进程和全部渲染进程，页面里的 `Intl.DateTimeFormat`、`Date` 读到的就是你指定的时区，而 Windows 其余部分保持真实时区。其他 Electron 应用也可以加进配置。

## 原理

看门狗每 700 ms 轮询一次各应用的主进程（命令行不含 `--type=` 的那个），直接从该进程的环境块读取 `TZ`（`NtQueryInformationProcess` → PEB → `RTL_USER_PROCESS_PARAMETERS.Environment`），然后：

| 发现的主进程 | 处理 |
| --- | --- |
| 已带正确的 `TZ` | 不动 |
| `TZ` 缺失或不符，且启动不到 20 秒 | 结束整棵进程树，用原始命令行参数加 `TZ` 重新启动 |
| `TZ` 缺失或不符，但已运行超过 20 秒 | 只写日志，绝不结束已经在用的应用 |

同一应用每分钟最多接管 3 次，超过则暂停 5 分钟。唯一可见的影响是从其他入口首次启动时窗口闪一下，约一秒。`config.json` 改动后自动重新加载。

Windows“登录后自动恢复上次打开的应用”拉起的应用比看门狗先启动，到看门狗第一次轮询时可能已经一分钟。它们没有未保存的工作，所以看门狗启动后的前 15 秒内年龄上限放宽为 `startupGraceSeconds`（180 秒）而不是 `maxAgeSeconds`。

已在 Windows 11 上用 Microsoft Store 版 Claude Desktop（Electron 44）和 ChatGPT 验证。纯 Chromium 浏览器（Edge、Chrome）不认 `TZ`，那种场景要用 `chrome.debugger` 扩展。

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

`install.ps1` 会用 IANA 时区库校验名称，写入 `config.json`，为当前用户注册一个隐藏的计划任务并立即启动看门狗。已经在运行的应用不会被动；加 `-RestartAppsNow` 才会用新时区重启它们（会结束进程树，先保存工作）。

选项：

| 开关 | 作用 |
| --- | --- |
| `-TimeZone <IANA 名>` | 设置时区；传 `Pacific Standard Time` 这类 Windows ID 会被拒绝并提示对应的 IANA 名 |
| `-StartAtLogon:$false` | 只注册任务不加触发器，看门狗仅在你运行 `start.ps1` 时启动（默认：登录时启动，每 10 分钟自检一次） |
| `-LaunchAppsAtLogon` | 登录时顺带打开 Claude Desktop 和 ChatGPT，启动时就带着 `TZ`（默认：关） |
| `-RestartAppsNow` | 把正在运行但 `TZ` 不符的应用立即重启 |

随时可以重新运行 `install.ps1` 改这些选项，会替换之前的注册。

日常命令：

```powershell
.\status.ps1      # 任务、看门狗状态，各应用期望与实际的 TZ
.\start.ps1       # 立即启动看门狗
.\stop.ps1        # 停到下次登录（或再次 start.ps1）
.\uninstall.ps1   # 删除任务并停止看门狗
```

## 配置

`config.json`：

```json
{
  "timeZone": "America/Los_Angeles",
  "pollMs": 700,
  "maxAgeSeconds": 20,
  "apps": [
    { "name": "claude.exe",  "package": "Claude",       "pathLike": "*\\WindowsApps\\Claude_*\\app\\claude.exe" },
    { "name": "ChatGPT.exe", "package": "OpenAI.Codex", "pathLike": "*\\WindowsApps\\OpenAI.Codex_*\\app\\ChatGPT.exe", "timeZone": "Europe/London" }
  ]
}
```

- `timeZone`：所有应用的默认 IANA 时区。
- `apps[].name`：进程映像名。
- `apps[].pathLike`：可执行文件路径通配，避免误伤同名进程（Claude Desktop 自带的 CLI 也叫 `claude.exe`），包升级后路径变化也不受影响。
- `apps[].timeZone`：可选，按应用单独指定。
- `apps[].package`：Store/MSIX 包名，`-LaunchAppsAtLogon` 用它定位可执行文件。非 Store 应用改为给 `apps[].exe`（完整路径）。
- `maxAgeSeconds`：运行超过这个秒数的进程绝不重启。

其他 Electron 应用同样适用。非 Electron 应用只有自己读 `TZ` 的才有效（Node.js 认，Python、.NET、Win32 不认）。

## 边界

`TZ` 改变的是 JavaScript 和 Node.js 看到的时区，不改变 Windows 时区，所以凡是向 Win32 或 .NET 询问本地时区的东西（`Get-Date`、`tzutil`、`%TIME%`）仍是真实值。在 Claude Code 这类 agent 里，模型自己的日期和 JavaScript 世界用注入的时区，而它执行的 shell 命令报告系统时区。Python 的 CRT 会把 `TZ` 里的 IANA 名称解析成错误的偏移，不要对 Python 应用注入。

网页服务到底用不用客户端时区，由服务方决定。

## 文件

| 文件 | 用途 |
| --- | --- |
| `tz-injector.ps1` | 看门狗本体，含读取其他进程环境块的 C# 辅助类 |
| `install.ps1` | 校验时区、写配置、注册并启动任务 |
| `status.ps1` | 显示任务状态、各应用期望与实际的 `TZ` |
| `start.ps1` / `stop.ps1` | 启动或停止看门狗，不改注册 |
| `launch-apps.ps1` | 带 `TZ` 打开配置里的应用，供 `-LaunchAppsAtLogon` 使用 |
| `uninstall.ps1` | 删任务、停看门狗 |
| `config.json` | 时区与应用列表 |
| `watchdog.log` | 与脚本同目录，超过 512 KB 自动截断 |

## 许可证

MIT
