@echo off
setlocal
cd /d "%~dp0"
title Alina AI Teammate - PLAYABLE
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-AlinaPlayable.ps1"
if errorlevel 1 (
  echo.
  echo Alina Playable launch failed. See the error above and .alina-runtime\logs\bridge.stderr.log.
  pause
)
endlocal
