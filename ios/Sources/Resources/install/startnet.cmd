@echo off
rem SPDX-License-Identifier: GPL-2.0-or-later
rem WindowsiOS Universal: Windows PE installer, run on the iPhone inside the VM.
rem Same steps as scripts/provision_windows_arm64.py (DISM + bcdboot), plus drivers and the
rem optional "lite" tuning, then a reboot into Windows' own unattended first setup.
rem The app fills in {{DISK_GB}} and {{LITE}}.
setlocal EnableDelayedExpansion
wpeinit
title WindowsiOS - Installing Windows 11
echo.
echo  ==========================================================
echo    WindowsiOS - Installing Windows 11 on this iPhone
echo    Keep the app open and the iPhone plugged in.
echo  ==========================================================
echo.

rem --- Find the installer's two volumes: WINPE (\winios\) and WINESD (\winios.tag) ---
set "PE="
set "SRC="
for %%L in (C D E F G H I J K L M N O P Q R T U V Y Z) do (
    if exist "%%L:\winios\unattend.xml" set "PE=%%L:"
    if exist "%%L:\winios.tag" set "SRC=%%L:"
)
if "%SRC%"=="" goto :fail_nosrc
if "%PE%"=="" goto :fail_nosrc
set /p IDX=<"%SRC%\winios.tag"
set "LOG=X:\winios-install.log"
echo [1/7] Installer found: Windows PE on %PE%, image on %SRC% (index %IDX%)

rem --- Already installed? (the firmware booted the installer again instead of Windows) ---
for %%L in (C D E F G H I J K L M N O P Q R T U V Y Z) do (
    if exist "%%L:\winios-installed.txt" (
        echo Windows is already installed on %%L:. Shutting down so WindowsiOS can start it.
        ping -n 4 127.0.0.1 >nul
        wpeutil shutdown
        exit /b 0
    )
)

rem --- The system disk: the empty {{DISK_GB}} GB NVMe disk ---
echo list disk > X:\list.txt
diskpart /s X:\list.txt > X:\disks.log
set "DISK="
for /f "tokens=1,2,3,4,5" %%a in (X:\disks.log) do (
    if /i "%%a"=="Disk" if /i "%%d %%e"=="{{DISK_GB}} GB" set "DISK=%%b"
)
if "%DISK%"=="" set "DISK=0"
echo [2/7] Partitioning disk %DISK% (GPT: EFI + MSR + Windows)...
(
    echo select disk %DISK%
    echo clean
    echo convert gpt
    echo create partition efi size=100
    echo format quick fs=fat32 label="System"
    echo assign letter=S
    echo create partition msr size=16
    echo create partition primary
    echo format quick fs=ntfs label="Windows"
    echo assign letter=W
) > X:\part.txt
diskpart /s X:\part.txt > "%LOG%" 2>&1
if not exist W:\ goto :fail_disk

echo [3/7] Applying Windows 11 Pro (this is the long step: 20-60 minutes on an iPhone)...
dism /Apply-Image /ImageFile:"%SRC%\sources\install.esd" /Index:%IDX% /ApplyDir:W:\
if errorlevel 1 goto :fail_dism

echo [4/7] Adding drivers (VirtIO network)...
if exist "%PE%\winios\drivers" dism /Image:W:\ /Add-Driver /Driver:"%PE%\winios\drivers" /Recurse /ForceUnsigned >> "%LOG%" 2>&1

echo [5/7] Setup answers, TPM / Secure Boot checks off, no BitLocker...
mkdir W:\Windows\Panther >nul 2>&1
copy /y "%PE%\winios\unattend.xml" W:\Windows\Panther\unattend.xml >nul
reg load HKLM\OFFSYS W:\Windows\System32\config\SYSTEM >> "%LOG%" 2>&1
reg add HKLM\OFFSYS\ControlSet001\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
reg add HKLM\OFFSYS\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
reg add HKLM\OFFSYS\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
reg add HKLM\OFFSYS\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
reg add HKLM\OFFSYS\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
reg load HKLM\OFFSOFT W:\Windows\System32\config\SOFTWARE >> "%LOG%" 2>&1
reg add HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1

if "{{LITE}}"=="1" (
    echo [6/7] Lite: services, background apps and visual effects for a phone...
    if exist "%PE%\winios\opt_hive_arm64.exe" "%PE%\winios\opt_hive_arm64.exe" >> "%LOG%" 2>&1
    reg import "%PE%\winios\lite_soft.reg" >> "%LOG%" 2>&1
) else (
    echo [6/7] Standard install: no lite tuning.
)
reg unload HKLM\OFFSOFT >> "%LOG%" 2>&1
reg unload HKLM\OFFSYS >> "%LOG%" 2>&1

if "{{LITE}}"=="1" (
    reg load HKLM\OFFDEF W:\Users\Default\NTUSER.DAT >> "%LOG%" 2>&1
    reg import "%PE%\winios\lite_user.reg" >> "%LOG%" 2>&1
    reg unload HKLM\OFFDEF >> "%LOG%" 2>&1
    dism /Image:W:\ /Get-ProvisionedAppxPackages > X:\appx.txt 2>nul
    for /f "tokens=3" %%P in ('findstr /b /c:"PackageName" X:\appx.txt') do (
        echo %%P| findstr /i /b /g:"%PE%\winios\lite_appx.txt" >nul && (
            echo     removing %%P
            dism /Image:W:\ /Remove-ProvisionedAppxPackage /PackageName:%%P /Quiet /NoRestart >> "%LOG%" 2>&1
        )
    )
)

echo [7/7] Making Windows bootable...
bcdboot W:\Windows /s S: /f UEFI >> "%LOG%" 2>&1
if errorlevel 1 goto :fail_boot
bcdedit /store S:\EFI\Microsoft\Boot\BCD /set {default} recoveryenabled no >> "%LOG%" 2>&1
bcdedit /store S:\EFI\Microsoft\Boot\BCD /set {default} bootmenupolicy standard >> "%LOG%" 2>&1
echo installed by WindowsiOS > W:\winios-installed.txt
copy /y "%LOG%" W:\Windows\Panther\winios-install.log >nul 2>&1
echo.
echo Done. Restarting into Windows setup (it finishes on its own, then turns off).
ping -n 4 127.0.0.1 >nul
wpeutil reboot
exit /b 0

:fail_nosrc
echo ERROR: the installer volumes were not found. Delete the install in WindowsiOS and try again.
goto :stop
:fail_disk
echo ERROR: could not partition the system disk.
type "%LOG%"
goto :stop
:fail_dism
echo ERROR: DISM could not apply Windows. The download may be damaged: delete it in WindowsiOS and try again.
goto :stop
:fail_boot
echo ERROR: bcdboot failed.
type "%LOG%"
goto :stop
:stop
echo.
echo WindowsiOS: installation stopped. This window stays open; close WindowsiOS to leave.
cmd /k
