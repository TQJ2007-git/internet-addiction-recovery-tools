# 远程关机控制 — 验收记录

**验收时间：** 2026-10-24 01:41（本地时区 +08:00）
**目标机：** <目标机主机名>（<目标机IP>）
**端口：** 8765
**令牌文件：** `remote/token.txt`（32 位十六进制）

## 通过的步骤

| 步骤 | 结果 | 证据 |
| --- | --- | --- |
| 安装（install-remote.bat，UAC 提权） | 通过 | `remote/install-state.json` 写入时间 01:41:40 |
| 计划任务 AutoShutdownRemote | 通过 | State = Running；触发器 AtLogOn；RunLevel Limited；LogonType Interactive；ExecutionTimeLimit = PT0S；禁止电池启动 = False |
| 监听端口 8765 | 通过 | `Get-NetTCPConnection -LocalPort 8765` 处于 Listen |
| URL ACL `http://+:8765/` | 通过 | `netsh http show urlacl` 可见保留项 |
| 防火墙规则 | 通过 | AutoShutdownRemote，入站允许，TCP 8765，RemoteAddress = LocalSubnet，Profile = Any |
| 令牌认证 | 通过 | 无令牌 `/api/status` → 401；带正确令牌 → 200 |
| 状态接口 | 通过 | 返回 hostname=<目标机主机名>、now、daily、pending、lastAction |
| 本机页面 | 通过 | `http://127.0.0.1:8765/` 已在浏览器打开 |
| 日志 | 通过 | `remote/server.log` 记录启动、来源 IP、方法、路径、状态码 |
| 自动化测试 | 通过 | `remote/test-remote.ps1`：29 项断言全部通过（DryRun 模式，未触发真实关机） |

## 未执行 / 需人工完成的步骤

| 步骤 | 原因 |
| --- | --- |
| 网页排定 30 分钟后关机并取消 | 真实服务会执行 `shutdown /s /t 1800`，自动化工具的安全策略禁止在此代发关机命令，需人工在页面点击 |
| 立即关机（60 秒后）+ 取消 | 同上；且会真实倒计时，需人工确认 |
| 另一台电脑访问 `http://<目标机IP>:8765/` | 需要第二台设备 |
| 重启后自动恢复 | 需要重启目标机并登录 |

## 已知状态

- `AutoShutdownDaily` 每日关机任务当前**未安装**（`Get-ScheduledTask` 查不到），因此状态卡显示「未安装 / MISSING」。这是原有脚本的问题，与远程模块无关；需要时在项目根目录运行 `install-task.bat` 重新注册。
- 远程服务随登录启动：锁屏可控制，注销或停留在登录界面时不可用。

## 后续人工验收命令

```powershell
# 本机确认
Get-ScheduledTask -TaskName AutoShutdownRemote | Select-Object TaskName, State
Get-NetTCPConnection -LocalPort 8765 -State Listen

# 令牌
Get-Content .\remote\token.txt
```
