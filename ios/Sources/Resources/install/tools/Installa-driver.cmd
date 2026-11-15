@echo off
rem WindowsiOS Tools: installs the drivers on this drive (VirtIO network, NetKVM).
rem Double-click it; Windows asks for administrator permission.
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
echo Installing the WindowsiOS drivers from %~dp0drivers ...
pnputil /add-driver "%~dp0drivers\*.inf" /subdirs /install
echo.
echo Done. The network ("Ethernet") should appear in a few seconds; if not, restart Windows.
pause
