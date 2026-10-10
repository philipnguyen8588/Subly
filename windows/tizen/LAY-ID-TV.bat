@echo off
rem Lay ma thiet bi (DUID) cua TV Samsung de gui cho nguoi dong goi app.
rem TV phai bat Developer Mode, Host PC IP = IP cua may nay (xem huong dan).
rem Dung: bam dup, hoac LAY-ID-TV.bat <IP-TV>
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

echo.
echo === Dang ket noi toi TV %TV% ...
"%SDB%" connect %TV%
"%SDB%" devices

echo.
echo === MA THIET BI (DUID) CUA TV ===
"%SDB%" -s %SERIAL% shell 0 getduid
echo =================================
echo.
echo COPY dong ma o tren (vi du dang: BDCLTHZVX36DA) va GUI cho nguoi dong goi app.
echo Neu khong thay ma: kiem tra TV da bat Developer Mode va Host PC IP = IP may nay chua,
echo va may nay cung mang voi TV.
echo.
pause
