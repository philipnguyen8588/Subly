---
name: them-tivi
description: >-
  Thêm một TV Samsung (Tizen) mới để cài app SubtitleTV: lấy DUID của TV, thêm DUID vào
  Samsung distributor certificate, đóng gói lại file .wgt đã ký và cài lên TV. Dùng khi
  người dùng muốn thêm/đăng ký TV mới, khi cài lên TV báo lỗi chứng chỉ
  "install failed [118, -12] ... Check certificate error : Invalid format of certificate in
  signature" (vd_appinstall), hoặc khi cần build lại windows/dist/SubtitleTV-Samsung.zip.
  Add a new Samsung Tizen TV, register its DUID, fix certificate install errors, rebuild the
  signed Tizen .wgt kit.
---

# Thêm TV Samsung mới cho app SubtitleTV

App TV `SubtitleTV` (Tizen, trong `windows/tizen/`) phải ký bằng **chứng chỉ Samsung** và chứng chỉ
đó **nhúng danh sách DUID** của những TV được phép cài. Cài lên TV có DUID chưa đăng ký → lỗi:

```
app_id[StSubTV001] install failed[118, -12], reason: Check certificate error : Invalid format of certificate in signature.:<-2>
```

**Cách sửa = thêm DUID của TV mới vào distributor certificate rồi đóng gói lại.** Chứng chỉ còn hạn
thì không phải lỗi hết hạn; gần như luôn là DUID chưa có trong cert.

## Đường dẫn & công cụ cố định

| Thứ | Đường dẫn |
|---|---|
| sdb (giao tiếp TV) | `C:\tizen-studio\tools\sdb.exe` |
| Certificate Manager | `C:\tizen-studio\tools\certificate-manager\certificate-manager.exe` |
| Tizen Studio IDE | `C:\tizen-studio\ide\TizenStudio.exe` |
| tizen CLI (đóng gói) | `C:\tizen-studio\tools\ide\bin\tizen.bat` |
| Danh sách profile ký | `C:\tizen-studio-data\profile\profiles.xml` |
| Chứng chỉ Samsung | `C:\Users\LipNguyen\SamsungCertificate\<tên-profile>\` |
| DUID đã đăng ký của 1 profile | `…\<tên-profile>\device-profile.xml` (thẻ `<TestDevice>`) |
| Script đóng gói + cài | `windows\tizen\deploy.ps1` |
| Bộ cài zip xuất ra | `windows\dist\SubtitleTV-Samsung.zip` |
| app id / package id | `StSubTV001.SubtitleTV` / `StSubTV001` |

## Cách nhanh nhất: nút TV trong app Windows (Subly.exe)

Nút **TV** (glyph E7F4) trên header cửa sổ chính và màn Bắt đầu mở `UI\TvInstallWindow.cs` → `TV\TvInstaller.cs`
(port C# của auto-install.ps1), `TV\WgtSigner.cs` (port sign-wgt.ps1), `TV\SamsungCert.cs` (port samsung-cert.ps1).
Bản build đóng kèm `tv\sdb.exe` (build.ps1 chép từ Tizen Studio vào `windows\Vendor\tizen`), `tv\SubtitleTV\`, `tv\ca\`.
Chứng chỉ do app xin lưu ở `%APPDATA%\ScreenTranslator\tv-certs\Subly-Auto`; app cũng dùng bộ ở
`%USERPROFILE%\SamsungCertificate` (mật khẩu *.pwd = DPAPI). Subly.exe phát hành KHÔNG kèm khoá của chủ app.
Biến môi trường kiểm thử: `SUBLY_TV_CERT_API` (máy chủ ký giả), `SUBLY_TV_CERT_NOBROWSER`, `SUBLY_TV_NO_SHARED_CERTS`.

## Cách nhanh: script tự động

`windows\tizen\auto-install.ps1 -Tv <IP-TV>` (hoặc bấm đúp `windows\tizen\TU-DONG-CAI-TV.bat`) làm hết bước 4–6,
**không cần Tizen Studio, không cần Python** (chỉ PowerShell + .NET có sẵn của Windows):
lấy DUID (sdb.exe) → DUID đã có trong bộ chứng chỉ nào (`certs\` cạnh script, hoặc `%USERPROFILE%\SamsungCertificate`)
thì dùng → chưa có thì mở trang đăng nhập Samsung (người dùng tự đăng nhập), `samsung-cert.ps1` xin Samsung ký chứng chỉ
có DUID (gọi thẳng API svdca.samsungqbe.com như Certificate Manager, theo tool MIT Apps2Samsung) vào thư mục
**`Subly-Auto`** (cộng dồn DUID, tối đa 10, giữ nguyên author) → `sign-wgt.ps1` tự ký .wgt (định dạng giống hệt
`tizen package`, đã đối chiếu bằng cách xác minh chữ ký thật; 18/10/2026 đã cài thành công lên TV thật S95B
192.168.8.31 bằng bộ cài standalone) → cài + mở app. Phần đăng nhập Samsung thật (`samsung-cert.ps1`) chưa chạy thật lần nào.
- Mật khẩu .p12: `password.txt` / `<author|distributor>.password.txt`, hoặc `*.pwd` của Certificate Manager = DPAPI
  (bỏ 4 byte đầu là độ dài, `ProtectedData.Unprotect` CurrentUser; chỉ giải được trên máy đã tạo).
- **Bộ cài cho máy khác:** `windows\tizen\make-installer.ps1` → `windows\dist\SubtitleTV-Installer\` (+ .zip): sdb.exe,
  app, script, CA, và các bộ chứng chỉ đang có (mật khẩu đã giải ra chữ — chỉ đưa người tin tưởng; `-NoCerts` để bỏ).
- Cần cổng 4794 trống (đóng Certificate Manager trước). CA của Samsung để ghép .p12 nằm ở `windows\tizen\ca\`.
- `-NewCert`: luôn xin chứng chỉ mới. `-Reinstall`: gỡ app cũ trước khi cài (TV đã cài app bằng chứng chỉ khác).
- TV vẫn phải bật Developer Mode + Host PC IP bằng tay (bước 2) — không tự động được.
- Chỉ khi script lỗi mới làm tay theo các bước dưới.

## Quy trình (làm theo thứ tự)

### 1. Xem IP máy tính này (để khai vào TV)
```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } | Select IPAddress,InterfaceAlias
```
Lấy IP LAN thật (card Ethernet/Wi-Fi), bỏ qua `vEthernet`/`172.*` của Hyper-V.

### 2. Bật Developer Mode trên TV
1. Mở màn hình **Apps** (Smart Hub).
2. Bấm remote dãy số **1 2 3 4 5**.
3. Gạt **Developer mode = ON**.
4. **Host PC IP** = IP máy tính ở bước 1.
5. **Tắt TV rồi mở lại** cho có hiệu lực.

### 3. Lấy IP của TV
Trên TV: Settings → General → **Network** → **Network Status** (dạng `192.168.x.x`).

### 4. Lấy DUID của TV (cần IP TV)
```powershell
C:\tizen-studio\tools\sdb.exe connect <IP-TV>
C:\tizen-studio\tools\sdb.exe -s <IP-TV>:26101 shell 0 getduid
```
DUID là chuỗi chữ+số (ví dụ `BDCLTHZVX36DA`). **Lưu ý:** mã model (ví dụ `QA65S95BAKXXV`) KHÔNG phải DUID.
Nếu `sdb connect` fail → kiểm tra lại Developer Mode + Host PC IP + cùng mạng.

Xem các DUID đã đăng ký sẵn trong từng profile:
```bash
for d in "/c/Users/LipNguyen/SamsungCertificate/"*/; do echo "[$d]"; grep -o '<TestDevice>[^<]*</TestDevice>' "$d/device-profile.xml"; done
```

### 5. Thêm DUID vào chứng chỉ (bước này người dùng TỰ bấm — cần đăng nhập Samsung account)
Mở Certificate Manager (`certificate-manager.exe`). **Nút bút chì dưới ô Distributor chỉ để trỏ file .p12
có sẵn — KHÔNG thêm được DUID.** Phải tạo profile mới qua wizard:
1. Khung **Certificate Profile** → bấm **"+"**.
2. Đặt tên profile (ví dụ `HVM-TV`) → Next. *(tên không nên có dấu cách)*
3. Chọn **Samsung** (không chọn Tizen) → Next.
4. Device type → **TV** → Next.
5. **Author Certificate**:
   - Nhớ mật khẩu author cũ → *Use an existing author certificate* → Browse `…\author.p12` + nhập pass.
   - **Quên mật khẩu** → *Create a new author certificate* → đặt name + password mới (ghi lại). App chưa cài
     lần nào thì dùng author mới hoàn toàn bình thường.
6. **Đăng nhập Samsung Account**.
7. **Distributor Certificate**: Privilege = **Public**; ô **DUID** dán DUID TV mới, giữ cả DUID cũ (mỗi dòng
   một DUID, tối đa 10) → Next → **Finish**.
8. Profile mới có dấu ✓ (active).

Xác nhận DUID đã vào cert (chạy lại lệnh grep ở bước 4 cho thư mục profile mới).

### 6. Đóng gói lại + cài
`deploy.ps1` tự `tizen package` ký lại rồi push/cài. Truyền `-Profile` đúng tên profile vừa tạo.

**Chỉ build bộ cài zip** (máy khác cài không cần Tizen Studio) → `windows\dist\SubtitleTV-Samsung.zip`:
```powershell
cd windows\tizen
.\deploy.ps1 -Profile "HVM-TV" -Kit
```
Zip gồm `SubtitleTV.wgt` (đã ký) + `sdb.exe` + `CAI-LEN-TV.bat`. Giải nén → bấm đúp `CAI-LEN-TV.bat` → nhập IP TV.

**Hoặc cài thẳng lên TV luôn** từ máy này:
```powershell
cd windows\tizen
.\deploy.ps1 -Profile "HVM-TV" -Tv <IP-TV>
```
Thêm `-Debug` để in cổng DevTools soi lỗi JS.

## Lưu ý
- Nếu đã đổi DUID/cert thì **phải đóng gói lại .wgt** — cài lại file .wgt cũ vẫn lỗi certificate y hệt, vì
  .wgt cũ ký bằng cert chưa có DUID mới.
- `deploy.ps1` đổi tên gói về `SubtitleTV.wgt` vì tên có dấu cách làm trình cài trên TV báo lỗi.
- Phần đăng nhập Samsung account (bước 5) là tương tác GUI, Claude không làm hộ được — chỉ hướng dẫn và lo
  phần lấy DUID (bước 4) + đóng gói/cài (bước 6).
- TV LG (webOS) nằm ở `windows/webos/` dùng cơ chế khác (không DUID kiểu này) — skill này chỉ cho Samsung.
