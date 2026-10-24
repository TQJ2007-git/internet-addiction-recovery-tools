@echo off
setlocal EnableExtensions EnableDelayedExpansion

call "%~dp0config.bat"

rem 读取任务当前状态：MISSING / ENABLE（当前禁用，需恢复）/ DISABLE（当前启用，需暂停）
set "STATE="
for /f "delims=" %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0helper.ps1" state "!TASK_NAME!"') do set "STATE=%%r"

if /i "%STATE%"=="MISSING" (
  echo 计划任务 %TASK_NAME% 不存在，请先双击 install-task.bat。
  exit /b 2
)

if /i "%STATE%"=="ENABLE" (
  schtasks /change /tn "%TASK_NAME%" /enable >nul
  if errorlevel 1 goto :fail
  echo 已恢复自动关机（每天 %TARGET_TIME%）。
) else (
  schtasks /change /tn "%TASK_NAME%" /disable >nul
  if errorlevel 1 goto :fail
  echo 已暂停自动关机，再双击一次可恢复。
  shutdown /a >nul 2>&1
)
exit /b 0

:fail
echo 操作失败，请右键"以管理员身份运行"再试。
exit /b 1
