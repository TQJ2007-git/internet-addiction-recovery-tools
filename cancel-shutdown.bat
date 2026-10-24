@echo off
setlocal

shutdown /a
if errorlevel 1 (
  echo 当前没有可取消的关机计划。
  exit /b 1
)

echo 已取消尚未开始的关机。
exit /b 0
