@echo off
rem Lấy mã thiết bị (DUID) của TV Samsung để gửi cho người đóng gói app.
rem TV phải bật Developer Mode, Host PC IP = IP của máy này (xem hướng dẫn).
rem Dùng: bấm đúp, hoặc LAY-ID-TV.bat <IP-TV>
chcp 65001 >nul
cd /d "%~dp0"
set "TV=%~1"
if "%TV%"=="" set /p "TV=Nhập IP của TV: "
set "SERIAL=%TV%:26101"

echo.
echo === Dang ket noi toi TV %TV% ...
sdb.exe connect %TV%
sdb.exe devices

echo.
echo === MA THIET BI (DUID) CUA TV ===
sdb.exe -s %SERIAL% shell 0 getduid
echo =================================
echo.
echo COPY dong ma o tren (vi du dang: BDCLTHZVX36DA) va GUI cho nguoi dong goi app.
echo Neu khong thay ma: kiem tra TV da bat Developer Mode va Host PC IP = IP may nay chua,
echo va may nay cung mang voi TV.
echo.
pause
