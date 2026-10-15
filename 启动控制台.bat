@echo off
cd /d "%~dp0"
title Android Console

echo.
echo   ================================
echo    Android Console (scrcpy based)
echo   ================================
echo.
echo    Web UI      : http://127.0.0.1:8000
echo    Dependency : none (Windows PowerShell built-in)
echo    Stop       : close this window or press Ctrl+C
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scrcpy\server.ps1"

echo.
echo   Service stopped.
pause
