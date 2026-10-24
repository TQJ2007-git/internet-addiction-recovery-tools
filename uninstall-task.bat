@echo off
setlocal

call "%~dp0config.bat"

schtasks /delete /tn "%TASK_NAME%" /f >nul 2>&1
if errorlevel 1 (
  echo 没有找到计划任务 %TASK_NAME%。
) else (
  echo 已删除计划任务 %TASK_NAME%。
)

shutdown /a >nul 2>&1
echo 已尝试取消当前排定的关机。
exit /b 0
