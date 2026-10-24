@echo off
setlocal EnableExtensions EnableDelayedExpansion

call "%~dp0config.bat"

set "SELF_DIR=%~dp0"
set "SELF_DIR=%SELF_DIR:~0,-1%"

rem 触发时刻 = 关机时刻 - LEAD_MINUTES
set "RUN_AT="
for /f "delims=" %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0helper.ps1" runat "!TARGET_TIME!" !LEAD_MINUTES!') do set "RUN_AT=%%r"

if not defined RUN_AT goto :fail
if /i "%RUN_AT%"=="ERR" goto :bad_config

set "TR=\"%SELF_DIR%\shutdown-at.bat\" %TARGET_TIME%"

echo 正在创建计划任务 %TASK_NAME% ...
schtasks /create /tn "%TASK_NAME%" /tr "%TR%" /sc daily /st "%RUN_AT%" /f
if errorlevel 1 goto :fail

echo.
echo 已安装: 每天 %RUN_AT% 自动排定, %TARGET_TIME% 关机。
echo 以后改了 config.bat 请重新双击本文件一次。
echo 暂停/恢复: 双击 toggle-task.bat
echo 彻底删除: 双击 uninstall-task.bat
exit /b 0

:bad_config
echo config.bat 里的 TARGET_TIME 或 LEAD_MINUTES 不合法。
exit /b 2

:fail
echo 创建计划任务失败。请右键"以管理员身份运行"本文件再试。
exit /b 1
