@echo off
setlocal EnableExtensions EnableDelayedExpansion

call "%~dp0config.bat"

rem ---------- 参数 ----------
set "DRY_RUN=0"
if not "%~1"=="" (
  if /i "%~1"=="--dry-run" (
    set "DRY_RUN=1"
  ) else (
    set "TARGET_TIME=%~1"
  )
)
if /i "%~2"=="--dry-run" set "DRY_RUN=1"

rem ---------- 校验时间 + 计算剩余秒数 ----------
set "RESULT="
for /f "delims=" %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0helper.ps1" sec "!TARGET_TIME!"') do set "RESULT=%%r"

if not defined RESULT goto :bad_time
if /i "%RESULT%"=="ERR" goto :bad_time

for /f "tokens=1,2" %%a in ("%RESULT%") do (
  set "SEC=%%a"
  set "WHEN=%%b"
)

if %SEC% LSS 1 set "SEC=1"
set /a "MIN=%SEC%/60"
if /i "%WHEN%"=="today" set "WHEN=今天"
if /i "%WHEN%"=="tomorrow" set "WHEN=明天"

echo 目标时刻 %TARGET_TIME%（%WHEN%，约 %MIN% 分钟后）

rem ---------- 下发关机 ----------
set "ARGS=/s /t %SEC%"
if "%FORCE%"=="1" set "ARGS=/f %ARGS%"

if "%DRY_RUN%"=="1" (
  echo [dry-run] 将执行: shutdown %ARGS%
  exit /b 0
)

shutdown %ARGS%
if errorlevel 1 goto :failed

echo 已排定，到点系统会自动关机。取消请双击 cancel-shutdown.bat
exit /b 0

:bad_time
echo 时间格式错误: "%TARGET_TIME%"
echo 用法: shutdown-at.bat [HH:MM] [--dry-run]
exit /b 2

:failed
echo 关机命令被拒绝，可能被组策略禁用。
echo 可尝试右键"以管理员身份运行"。
exit /b 3
