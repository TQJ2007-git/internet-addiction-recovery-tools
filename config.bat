@echo off
rem ================= 配置区（改这里） =================
rem 每天几点关机，24 小时制，如 23:30 或 0:05
set "TARGET_TIME=23:30"

rem 提前几分钟排定（给取消留出时间），0 表示到点直接排
set "LEAD_MINUTES=10"

rem 1 = 强制关闭所有程序（未保存内容会丢）；0 = 走正常关闭流程
set "FORCE=1"
rem ===================================================

rem 计划任务名称（一般不用改）
set "TASK_NAME=AutoShutdownDaily"

rem ---- remote control ----
set "REMOTE_PORT=8765"
