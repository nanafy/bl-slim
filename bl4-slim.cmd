@echo off
if not exist "%~dp0bl4-slim.ps1" (echo bl4-slim.ps1 is missing. Unzip the whole folder first, then run bl4-slim.cmd again.& pause & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bl4-slim.ps1" %*
set rc=%errorlevel%
pause
exit /b %rc%
