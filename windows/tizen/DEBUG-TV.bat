@echo off
rem Bam dup de mo app Subtitle TV tren TV o che do DEBUG + mo Chrome DevTools.
rem Sua IP TV o dong duoi neu khac. TV phai bat Developer Mode (TV xa thi bat Tailscale truoc).
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DEBUG-TV.ps1" -Tv 192.168.2.245
pause
