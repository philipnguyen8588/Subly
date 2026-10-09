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
