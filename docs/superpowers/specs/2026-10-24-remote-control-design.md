# 远程关机控制模块 — 设计文档

- 日期：2026-10-24
- 状态：待实现
- 适用项目：`<项目目录>`
- 关联文档：无

## 1. 背景与目标

现有项目提供单机自动关机能力：`shutdown-at.bat` 排定关机，`install-task.bat` 注册每日计划任务，`toggle-task.bat` / `uninstall-task.bat` / `cancel-shutdown.bat` 管理任务与取消。

本次新增一个**局域网内的远程控制模块**，让用户在另一台电脑的浏览器上控制目标电脑的关机行为。目标电脑保持开机、已登录（锁屏可以）即可；不要求外网访问，不做远程唤醒。

成功标准：

1. 在另一台电脑浏览器打开 `http://<目标机IP>:8765`，输入一次令牌后即可操作。
2. 能定时关机（`HH:MM` 或 N 分钟后）、取消关机、立即关机、查看状态。
3. 日常操作不需要管理员权限；只有安装时需要一次。
4. 原有单机脚本和每日计划任务行为完全不变。
5. 局域网内除本地子网外的设备无法访问；所有 API 调用必须携带令牌。

## 2. 范围

### 包含

- 目标机上的常驻 HTTP 服务（Windows PowerShell 5.1）
- 单页网页控制台
- 一次性安装/卸载脚本（自动请求 UAC）
- 令牌认证、本地子网防火墙限制、操作日志
- Dry-run 模式与一个自动化验证脚本

### 不包含

- 外网访问 / 内网穿透（未来可加 Tailscale）
- 远程修改 `config.bat` 中的每日关机时间
- 远程桌面、屏幕查看、键鼠控制
- Wake-on-LAN / 远程开机
- 在未登录的登录界面提供控制（采用"随登录启动"，注销后服务停止）
- 多用户会话隔离（服务只服务当前登录用户）

## 3. 架构

### 3.1 文件布局

新增文件全部放在 `remote/`，原有文件只改 `config.bat`（加一行端口配置）。

```
nuclear_weapen/
├─ config.bat                  ← 新增 REMOTE_PORT=8765
├─ shutdown-at.bat             ← 不修改
├─ helper.ps1                  ← 不修改
├─ install-task.bat 等         ← 不修改
└─ remote/
   ├─ remote-server.ps1        常驻 HTTP 服务
   ├─ index.html               控制页面（原生 HTML/CSS/JS）
   ├─ install-remote.bat       安装入口（自提权，调用 install-remote.ps1）
   ├─ install-remote.ps1       安装逻辑
   ├─ uninstall-remote.bat     卸载入口（自提权）
   ├─ uninstall-remote.ps1     卸载逻辑
   ├─ test-remote.ps1          自动化验证（dry-run，不关机）
   ├─ token.txt                安装时生成，32 位十六进制
   ├─ install-state.json       安装状态（端口、用户、任务名），卸载用
   ├─ pending.json             最近一次由网页排定的关机（运行期）
   └─ server.log               运行日志
```

### 3.2 组件职责

| 组件 | 职责 | 不负责 |
|---|---|---|
| `remote-server.ps1` | HTTP 监听、令牌校验、调用现有脚本执行动作、写日志、返回 JSON | 页面渲染、时间算法 |
| `index.html` | 渲染 UI、调用 API、保存令牌到 localStorage | 权限判断、业务逻辑 |
| `install-remote.ps1` | 生成令牌、URL ACL、防火墙、注册登录自启任务、启动并自检 | 日常控制 |
| `uninstall-remote.ps1` | 停止并删除任务、清理防火墙和 URL ACL、结束残留进程 | 删除用户数据（日志/令牌） |
| `test-remote.ps1` | 在 8766 端口以 dry-run 模式启动实例并跑断言 | 真实关机 |

时间计算不重复实现：`HH:MM` 排定统一调用 `shutdown-at.bat`，状态与剩余秒数统一调用 `helper.ps1 sec`。

### 3.3 数据流

```
控制端浏览器
  │  GET /                （无令牌）
  │  GET/POST /api/*      （Authorization: Bearer <token>）
  ▼
remote-server.ps1
  ├─ 校验令牌 ──失败──> 401 + 日志
  ├─ GET  /api/status   ──> helper.ps1 / Get-ScheduledTask / pending.json
  ├─ POST /api/schedule ──> shutdown-at.bat <HH:MM>  或 shutdown.exe /t
  ├─ POST /api/cancel   ──> shutdown.exe /a
  └─ POST /api/shutdown-now ──> shutdown.exe /t <delay>
        │
        └─ 结果 JSON ← 页面刷新状态
```

### 3.4 启动方式

- 计划任务名：`AutoShutdownRemote`
- 触发：`AtLogOn`，当前用户，`InteractiveToken`，`RunLevel Limited`（普通权限）
- 动作：`powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<项目>\\remote\\remote-server.ps1"`
- 设置：
  - `ExecutionTimeLimit = 0`（永不因超时被结束）
  - `RestartCount = 3`，`RestartInterval = 1 分钟`
  - `AllowStartIfOnBatteries = true`
  - `DontStopIfGoingOnBatteries = true`
- 说明：锁屏不影响；注销或重启停在登录界面时服务不运行（已与用户确认）。

### 3.5 服务参数

`remote-server.ps1` 接受：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Port` | `config.bat` 的 `REMOTE_PORT`（8765） | 监听端口 |
| `-DryRun` | 关闭 | 只写日志，不调用 `shutdown` / `shutdown-at.bat`，供测试使用 |

测试脚本用 `-Port 8766 -DryRun`，与真实实例完全隔离。

## 4. 网络与端口

- 端口：`config.bat` 中 `REMOTE_PORT`，默认 `8765`
- 监听：`http://+:<PORT>/`
- 防火墙：入站 TCP 放行该端口，`remoteip=LocalSubnet`，适用于所有网络配置文件
- 不提供 HTTPS；明文风险在"安全模型"中说明
- 服务启动时若端口被占用：写日志并以非零码退出，安装脚本会提示修改端口

## 5. API 规范

### 5.1 通用约定

- 请求/响应均为 UTF-8
- 请求体上限 4096 字节，超过返回 413
- 除 `GET /` 外，所有 API 必须携带：
  `Authorization: Bearer <token>`
- 错误响应统一为：
  ```json
  {"ok": false, "error": "人类可读的错误信息"}
  ```
- 成功响应统一包含 `"ok": true`
- 方法不匹配返回 405；路径不存在返回 404
- 令牌比较使用大小写敏感比较；失败时延迟 750ms 再返回 401，并记录来源 IP

### 5.2 GET /

- 返回 `remote/index.html`
- `Content-Type: text/html; charset=utf-8`
- 不需要令牌；页面本身不含任何密钥
- 附带返回 `/favicon.ico` → 204

### 5.3 GET /api/status

响应示例：

```json
{
  "ok": true,
  "hostname": "DESKTOP-ABC",
  "now": "2026-10-24T01:30:00+08:00",
  "daily": {
    "targetTime": "23:30",
    "leadMinutes": 10,
    "taskName": "AutoShutdownDaily",
    "exists": true,
    "state": "Ready",
    "nextRunTime": "2026-10-24T23:20:00+08:00"
  },
  "pending": {
    "source": "web",
    "at": "2026-10-24T02:00:00+08:00",
    "secondsRemaining": 1800
  },
  "lastAction": {
    "action": "schedule",
    "at": "2026-10-24T01:30:00+08:00",
    "ok": true
  }
}
```

- `daily.targetTime` / `daily.leadMinutes`：从 `config.bat` 解析
- `daily.state`：`Ready` / `Running` / `Disabled` / `MISSING`（`Get-ScheduledTask`）
- `daily.nextRunTime`：`Get-ScheduledTaskInfo`；任务不存在时为 `null`
- `pending`：仅反映**由本服务排定**的关机；没有则 `null`。服务重启后从 `pending.json` 恢复；若时间已过则视为 `null` 并清理文件。由每日计划任务触发的关机不会显示在 `pending` 中（已知限制）
- `lastAction`：内存中的最近一次操作，服务重启后丢失

### 5.4 POST /api/schedule

请求体二选一：

```json
{"at": "23:30"}
```

或

```json
{"inMinutes": 30}
```

- `at`：严格正则 `^([01]?\d|2[0-3]):[0-5]\d$`
  - 调用 `shutdown-at.bat <at>`（沿用其 FORCE 设置与时间判断）
  - 退出码 0 → 成功；2 → 400；3 → 501（系统拒绝关机）
  - 响应中的 `seconds` 由 `helper.ps1 sec <at>` 计算，供页面显示
- `inMinutes`：整数 1–1440
  - 直接调用 `shutdown /s [/f] /t <秒数>`，`/f` 是否出现取决于 `config.bat` 的 `FORCE`
- 响应：

```json
{"ok": true, "mode": "at", "scheduledFor": "23:30", "seconds": 79620}
```

```json
{"ok": true, "mode": "inMinutes", "seconds": 1800}
```

- 若已有排定中的关机，Windows 会用新的计时器替换旧的；接口返回成功，页面刷新后显示新的时间
- 成功后写入 `pending.json` 并更新 `lastAction`

### 5.5 POST /api/cancel

- 执行 `shutdown /a`
- 退出码 0：
  ```json
  {"ok": true, "cancelled": true}
  ```
- 非 0（通常是没有关机在进行）：
  ```json
  {"ok": true, "cancelled": false, "reason": "no pending shutdown"}
  ```
- 无论结果如何都清除 `pending.json`

### 5.6 POST /api/shutdown-now

请求体：

```json
{"delaySeconds": 60}
```

- `delaySeconds` 可选，整数 10–600，默认 60
- 调用 `shutdown /s [/f] /t <delaySeconds>`
- 返回：

```json
{"ok": true, "seconds": 60}
```

- 成功后写入 `pending.json`

## 6. 网页界面

单页，中文，原生 HTML/CSS/JS，无任何外部依赖（不引用 CDN）。

布局：

1. **顶部**
   - 目标机主机名
   - 在线状态：正常 / 连接失败（5 秒轮询失败时显示）
   - 目标机当前时间
2. **状态卡**
   - 每日计划任务：名称、启用/暂停、下次运行时间
   - 本次排定：时间与剩余秒数；无则显示"当前没有由网页排定的关机"
   - 最近一次操作及结果
3. **定时关机**
   - 时间输入框，默认值取 `status.daily.targetTime`
   - 快捷按钮：10 / 30 / 60 分钟后
   - "排定关机"按钮
4. **危险操作**
   - "立即关机"：二次确认，默认 60 秒延迟，可在此期间取消
   - "取消关机"
5. **登录层**
   - 首次打开要求输入令牌，`type=password`
   - 保存到 `localStorage`，键名 `asr_token`
   - 提供"更换令牌"入口（清除 localStorage 并重新弹出）

交互：

- 每 5 秒 `GET /api/status`
- 所有请求使用相对路径，页面可从任意主机名/IP 打开
- 操作成功后立即刷新状态；失败显示顶部错误条
- 所有 API 请求失败（网络错误）时进入"连接失败"状态，保留最后一次数据并标注已过期

## 7. 安全模型

| 项 | 措施 |
|---|---|
| 认证 | 32 位随机令牌，`Authorization: Bearer`，失败延迟 + 日志 |
| 网络边界 | 防火墙仅放行 `LocalSubnet`；不依赖公网 |
| 权限 | 服务以普通用户运行，`RunLevel Limited`；最坏权限等于用户本人 |
| 命令注入 | 所有输入先严格校验；`at` 只允许 `HH:MM`；`inMinutes` / `delaySeconds` 强制转整数并限范围 |
| 任意命令 | 不存在执行任意命令的接口，只有固定四个动作 |
| 令牌泄露 | 令牌只存于目标机 `remote/token.txt` 和浏览器 localStorage；不写日志 |
| 传输 | 局域网 HTTP 明文；同一子网内可被嗅探。已告知用户，未来可用 Tailscale 加密 |
| 日志 | 记录时间、来源 IP、动作、结果；不记录令牌 |
| 服务身份 | 不注册为系统服务，不要求常驻管理员权限 |

已接受的残余风险：

- 同一局域网内知道令牌的人可以关机（令牌 32 位十六进制，无法暴力枚举）
- 令牌在浏览器 localStorage 中，若控制端电脑被入侵可被读取
- 若网络被标记为"公用"且路由器启用了 AP 隔离，可能无法访问（需排查网络设置）

## 8. 安装流程

入口：双击 `remote/install-remote.bat`。脚本检测到非管理员时，通过 `Start-Process -Verb RunAs` 重新以管理员启动 `install-remote.ps1`。

步骤：

1. 解析 `config.bat` 的 `REMOTE_PORT`（默认 8765）和 `TASK_NAME`
2. 确认 `remote-server.ps1`、`index.html` 存在
3. 检查端口是否被占用；被占用则中止并提示改端口
4. 若 `token.txt` 不存在，生成 32 位十六进制令牌
5. 确定 URL ACL 的目标用户：优先使用项目文件夹的所有者（`Get-Acl` 的 `Owner`），否则用 `$env:USERDOMAIN\$env:USERNAME`
6. 删除同名 URL ACL（忽略不存在），再添加：
   `netsh http add urlacl url=http://+:<PORT>/ user="<目标用户>"`
7. 删除同名防火墙规则（忽略不存在），再添加：
   `netsh advfirewall firewall add rule name="AutoShutdownRemote" dir=in action=allow protocol=TCP localport=<PORT> remoteip=LocalSubnet profile=any`
8. 注册计划任务 `AutoShutdownRemote`（见 3.4），`-Force` 覆盖旧任务
9. 写入 `remote/install-state.json`：
   ```json
   {"port": 8765, "user": "<计算机名>\\<用户名>", "taskName": "AutoShutdownRemote", "installedAt": "2026-10-24T01:30:00+08:00"}
   ```
10. 启动任务，等待最多 5 秒，用 `Get-NetTCPConnection -LocalPort <PORT> -State Listen` 自检
11. 输出：所有本机 IPv4 地址对应的访问 URL、令牌文件路径、下一步说明

幂等性：重复运行会覆盖任务、规则和 URL ACL，不重复生成令牌（除非手动删除 `token.txt`）。

失败处理：任何一步失败都输出具体原因并返回非零退出码；已完成的步骤不回滚（可先运行卸载）。

## 9. 卸载流程

入口：`remote/uninstall-remote.bat`（自提权，调用 `uninstall-remote.ps1`）。

1. 从 `install-state.json` 读取端口和任务名；文件不存在时回退到 `config.bat` 的 `REMOTE_PORT`
2. `Stop-ScheduledTask` + `Unregister-ScheduledTask`（不存在则忽略）
3. 结束命令行中包含 `remote-server.ps1` 的残留 PowerShell 进程
4. 删除防火墙规则 `AutoShutdownRemote`
5. 删除 URL ACL `http://+:<PORT>/`
6. 保留 `token.txt`、`server.log`、`pending.json`（不就业数据丢失）；输出提示
7. 可选参数 `-Purge`：同时删除令牌和日志

## 10. 日志

- 文件：`remote/server.log`
- 编码：UTF-8 无 BOM
- 格式：`[yyyy-MM-dd HH:mm:ss] <客户端IP> <动作> <结果>`
- 事件：服务启动/停止、认证失败、每次 API 调用及结果、周期任务调用失败
- 轮转：启动时若文件超过 1 MB，改名为 `server.log.old`（覆盖旧文件）

## 11. 错误处理

| 场景 | HTTP | 行为 |
|---|---|---|
| 缺少/错误令牌 | 401 | 延迟 750ms，日志记录 IP |
| JSON 格式错误 | 400 | `{"ok":false,"error":"请求格式错误"}` |
| 时间格式错误 | 400 | 使用 `shutdown-at.bat` 的退出码 2 |
| `inMinutes` 超范围 | 400 | 1–1440 |
| `delaySeconds` 超范围 | 400 | 10–600 |
| 请求体过大 | 413 | 超过 4096 字节 |
| 方法不支持 | 405 | 允许的方法见 5.x |
| 路径不存在 | 404 | |
| 系统拒绝关机（组策略） | 501 | 退出码 3，提示"关机被系统拒绝" |
| 端口被占用 | — | 服务启动失败，写日志并以退出码 2 退出 |
| 令牌文件缺失 | — | 服务启动失败，写日志并以退出码 3 退出 |
| 取消时没有待执行关机 | 200 | `cancelled:false`，不算错误 |
| 页面无法连接服务 | — | UI 显示"连接失败"，保留最后一次数据 |

## 12. 编码约定

- `remote-server.ps1`、`install-remote.ps1`、`uninstall-remote.ps1`、`test-remote.ps1`：**UTF-8 with BOM**（Windows PowerShell 5.1 才能正确读取中文）
- `index.html`：UTF-8（无 BOM），页面声明 `<meta charset="utf-8">`
- 新增 `.bat`：与现有脚本一致使用 ANSI/GBK，或仅使用 ASCII 文本
- 现有 `.bat` 文件保持 GBK + CRLF，不做转码

## 13. 测试计划

### 13.1 自动化（不关机）

`remote/test-remote.ps1`：

1. 以 `-Port 8766 -DryRun` 启动服务
2. 等待端口监听（最多 5 秒）
3. 断言：
   - 无令牌请求 `/api/status` → 401
   - 错误令牌 → 401
   - 正确令牌 + `{"at":"25:99"}` → 400
   - 正确令牌 + `{"inMinutes":0}` → 400
   - 正确令牌 + `{"at":"23:30"}` → 200，返回 `seconds > 0`
   - 正确令牌 + `{"inMinutes":30}` → 200，`seconds == 1800`
   - `POST /api/cancel` → 200，`cancelled` 为布尔值
   - `GET /nope` → 404
   - `GET /` → 200 且 `Content-Type` 为 HTML
4. 停止服务并输出通过/失败汇总，失败时退出码非零

Dry-run 语义：所有关机动作只写日志，不调用 `shutdown`；`/api/cancel` 不调用 `shutdown /a`。

### 13.2 手工验收（真实）

1. 在目标机安装并确认任务在运行
2. 在另一台电脑打开 `http://<目标机IP>:<PORT>`，输入令牌
3. 排定"2 分钟后关机"，确认目标机弹出关机提示
4. 点"取消关机"，确认取消成功
5. 查看 `server.log` 有对应记录
6. 重启目标机并登录，确认服务自动恢复

## 14. 已知限制

- 仅在用户已登录（含锁屏）时可用；注销或停在登录界面时不可用
- 目标机睡眠时无法访问
- 仅局域网；跨网段/外网不可用
- HTTP 明文，无传输加密
- 目标机 IP 变化后需重新确认地址；建议用主机名或 DHCP 保留
- 由每日计划任务触发的关机不会出现在 `pending` 中
- 若更换 Windows 账户或重命名项目文件夹，需要重新运行安装
- 第三方杀毒/EDR 可能拦截隐藏窗口的 PowerShell HTTP 服务，需要放行

## 15. 未来可扩展（本次不做）

- Tailscale / WireGuard 组网，实现加密的外网控制
- 远程修改 `config.bat` 的每日关机时间（需重装计划任务）
- Wake-on-LAN 远程开机
- 多目标机管理（一个控制页管理多台）
