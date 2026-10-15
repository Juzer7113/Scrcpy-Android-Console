@echo off
cd /d "%~dp0"
echo ================================
echo  scrcpy remote control (default encoder)
echo ================================
set /p STBIP=Enter device IP [e.g. 192.168.1.253]:
if "%STBIP%"=="" goto END

echo [1/2] adb connect %STBIP%:5555 ...
adb connect %STBIP%:5555
if errorlevel 1 goto FAIL

echo [2/2] starting scrcpy ...
scrcpy.exe -s %STBIP%:5555 --max-size 1280 --no-audio
if errorlevel 1 echo scrcpy exited with an error - see the output above.
goto END

:FAIL
echo.
echo FAILED to connect %STBIP%:5555
echo Check: same LAN / network ADB enabled on the device

:END
pause
