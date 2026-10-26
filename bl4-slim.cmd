@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bl4-slim.ps1" %*
set rc=%errorlevel%
pause
exit /b %rc%
