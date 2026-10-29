@echo off
if not exist "%~dp0bl-slim.ps1" (echo bl-slim.ps1 is missing. Unzip the whole folder first, then run bl-slim.cmd again.& pause & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bl-slim.ps1" %*
set rc=%errorlevel%
pause
exit /b %rc%
