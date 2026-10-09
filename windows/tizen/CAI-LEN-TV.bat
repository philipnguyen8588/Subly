@echo off
rem Cài Subtitle TV lên TV Samsung (TV phải bật Developer Mode, Host PC IP = IP máy này).
rem Dùng: bấm đúp, hoặc CAI-LEN-TV.bat <IP-TV>
chcp 65001 >nul
cd /d "%~dp0"
set "TV=%~1"
if "%TV%"=="" set /p "TV=Nhập IP của TV: "
set "SERIAL=%TV%:26101"
set "REMOTE=/home/owner/share/tmp/sdk_tools/tmp/SubtitleTV.wgt"

sdb.exe connect %TV%
sdb.exe -s %SERIAL% push SubtitleTV.wgt %REMOTE% >nul
sdb.exe -s %SERIAL% shell 0 vd_appinstall StSubTV001 %REMOTE% > "%TEMP%\subtv-install.log"
type "%TEMP%\subtv-install.log"
findstr /c:"install completed" "%TEMP%\subtv-install.log" >nul
if errorlevel 1 (
    echo.
    echo CÀI THẤT BẠI. Kiểm tra: TV đã bật Developer Mode với IP máy này chưa,
    echo và chứng chỉ dùng để đóng gói đã có DUID của TV này chưa.
    pause
    exit /b 1
)
sdb.exe -s %SERIAL% shell 0 was_kill StSubTV001.SubtitleTV >nul
sdb.exe -s %SERIAL% shell 0 execute StSubTV001.SubtitleTV
echo.
echo Đã cài xong, app đang mở trên TV.
pause
