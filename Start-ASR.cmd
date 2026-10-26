@echo off
setlocal
cd /d "%~dp0"

rem Prefer PowerShell 7 (tested); fall back to Windows PowerShell.
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"

set "NOPAUSE="
if /i "%~1"=="--no-pause" set "NOPAUSE=1"

echo ============================================
echo   asr-worker  -  start
echo ============================================
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "start.ps1"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo Done. This window can be closed.
) else (
  echo Failed with exit code %RC%.
  echo Check logs\asr.err.log for details.
)
if not defined NOPAUSE (
  echo.
  pause
)
exit /b %RC%