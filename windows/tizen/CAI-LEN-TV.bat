@echo off
rem Cai Subtitle TV len TV Samsung (TV phai bat Developer Mode, Host PC IP = IP may nay).
rem Dung: bam dup, hoac CAI-LEN-TV.bat <IP-TV>
rem File nay chi dung chu khong dau + xuong dong CRLF: cmd doc sai file UTF-8 co dau.
cd /d "%~dp0"
set "SDB=%~dp0sdb.exe"
set "TV=%~1"
if "%TV%"=="" set /p "TV=Nhap IP cua TV: "
if "%TV%"=="" (
    echo Chua nhap IP TV.
    pause
    exit /b 1
)
set "SERIAL=%TV%:26101"
set "REMOTE=/home/owner/share/tmp/sdk_tools/tmp/SubtitleTV.wgt"

"%SDB%" connect %TV%
"%SDB%" -s %SERIAL% push "%~dp0SubtitleTV.wgt" %REMOTE% >nul
"%SDB%" -s %SERIAL% shell 0 vd_appinstall StSubTV001 %REMOTE% > "%TEMP%\subtv-install.log"
type "%TEMP%\subtv-install.log"
findstr /c:"install completed" "%TEMP%\subtv-install.log" >nul
if errorlevel 1 (
    echo.
    echo CAI THAT BAI. Kiem tra: TV da bat Developer Mode voi IP may nay chua,
    echo va chung chi dung de dong goi da co DUID cua TV nay chua.
    pause
    exit /b 1
)
"%SDB%" -s %SERIAL% shell 0 was_kill StSubTV001.SubtitleTV >nul
"%SDB%" -s %SERIAL% shell 0 execute StSubTV001.SubtitleTV
echo.
echo Da cai xong, app dang mo tren TV.
pause
