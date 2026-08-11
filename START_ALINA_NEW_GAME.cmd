@echo off
setlocal
cd /d "%~dp0"
title Alina AI Teammate - NEW GAME
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-AlinaPlayable.ps1" -NewGame
if errorlevel 1 (
  echo.
  echo Alina new-game launch failed. See the error above and .alina-runtime\logs\bridge.stderr.log.
  pause
)
endlocal
