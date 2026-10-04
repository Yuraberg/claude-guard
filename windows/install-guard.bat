@echo off
chcp 65001 >nul
echo.
echo  Installing Claude VPN guard...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
echo  DONE. If a report path is shown above, send that file back.
echo.
pause
exit /b
