@echo off
setlocal
cd /d "%~dp0"
title Alina AI Teammate - RESET PLAYABLE COPY
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-AlinaPlayable.ps1" -ResetPlayableCopy
if errorlevel 1 (
  echo.
  echo Alina Playable reset/launch failed. See the error above and .alina-runtime\logs\bridge.stderr.log.
  pause
)
endlocal
