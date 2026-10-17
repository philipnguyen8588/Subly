@echo off
rem Cai Subtitle TV len TV Samsung bat ky: tu lay DUID, tu xin chung chi Samsung (dang nhap tren trinh duyet) roi cai.
rem Them -Reinstall vao cuoi dong powershell neu TV da cai app bang chung chi khac.
set /p TVIP=IP cua TV: 
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto-install.ps1" -Tv %TVIP%
pause
