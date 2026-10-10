@echo off
rem Bam dup de mo app Subtitle TV tren TV o che do DEBUG + mo Chrome DevTools.
rem Moi lan chay se hoi IP cua TV. TV phai bat Developer Mode (TV xa thi bat Tailscale truoc).
cd /d "%~dp0"
set "TV=%~1"
if "%TV%"=="" set /p "TV=Nhap IP cua TV (vi du 192.168.2.245): "
if "%TV%"=="" (
    echo Chua nhap IP TV.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DEBUG-TV.ps1" -Tv %TV%
pause
