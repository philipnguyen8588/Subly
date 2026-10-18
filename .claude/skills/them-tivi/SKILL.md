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

**Cách sửa = xin chứng chỉ có DUID của TV đó rồi ký lại.** Chứng chỉ còn hạn thì không phải lỗi hết hạn; gần như
luôn là DUID chưa có trong cert. Lỗi `install failed[118, -11] ... Author certificate not match` = TV đã có app ký
bằng chứng chỉ **tác giả** khác → dùng đúng bộ đó, hoặc gỡ app cũ (mất cài đặt trong app trên TV).

**Máy này KHÔNG còn Tizen Studio (đã gỡ 10/2026) và không cần nữa.** Mọi thứ thay bằng công cụ riêng bên dưới.

## Đường dẫn & công cụ

| Thứ | Đường dẫn |
|---|---|
| sdb (giao tiếp TV) | `windows\Vendor\tizen\sdb.exe` (bản riêng, gitignore; bộ cài + Subly.exe mang theo `tv\sdb.exe`) |
| Ký .wgt | `windows\tizen\sign-wgt.ps1` (C#: `windows\ScreenTranslator\TV\WgtSigner.cs`) |
| Xin chứng chỉ Samsung | `windows\tizen\samsung-cert.ps1` (C#: `TV\SamsungCert.cs`) — thay Certificate Manager |
| Chứng chỉ của chủ app | `C:\Users\LipNguyen\SamsungCertificate\<tên>\` (HVM-TV, LipNguyen-TV, OIOI, Subly-Auto) |
| Chứng chỉ do app Windows xin | `%APPDATA%\ScreenTranslator\tv-certs\<tên>\` |
| DUID của 1 bộ | `duids.txt` và/hoặc `device-profile.xml` (thẻ `<TestDevice>`) |
| Mật khẩu .p12 | `password.txt` / `<author|distributor>.password.txt`, hoặc `*.pwd` cũ của Certificate Manager = DPAPI (bỏ 4 byte đầu, `ProtectedData.Unprotect` CurrentUser; chỉ giải được trên máy này) |
| CA Samsung để ghép .p12 | `windows\tizen\ca\` |
| Script ký + cài | `windows\tizen\deploy.ps1` (`-Profile <tên>`, `-Kit`, `-Debug`, `-IdKit`) |
| app id / package id | `StSubTV001.SubtitleTV` / `StSubTV001` |
| Bản sao lưu từ Tizen Studio cũ | `C:\Users\LipNguyen\SamsungCertificate\_tizen-studio-backup\` (keystore + profiles.xml) |

## Cách 1 — nút trong app Windows (Subly.exe)
Nút **"Cài app lên TV"** trên header màn Bắt đầu và màn dịch → `UI\TvInstallWindow.cs` → `TV\TvInstaller.cs`:
lấy DUID → bộ chứng chỉ có DUID (tv-certs của app, rồi `SamsungCertificate`) → không có thì mở trang đăng nhập
Samsung, xin chứng chỉ vào `tv-certs\Subly-Auto` → ký → cài; lệch tác giả thì thử bộ kế, hết bộ thì hỏi gỡ app cũ.
Subly.exe phát hành KHÔNG kèm khoá của chủ app. Biến môi trường kiểm thử: `SUBLY_TV_CERT_API` (máy chủ ký giả),
`SUBLY_TV_CERT_NOBROWSER`, `SUBLY_TV_NO_SHARED_CERTS` (bỏ qua SamsungCertificate để thử luồng TV mới).
Đã cài thật lên S95B 192.168.8.31 bằng bản phát hành (18/10/2026).

## Cách 1b — nút trong app Mac (Subly.app)
Cùng luồng với Cách 1, port Swift trong `Sources/ScreenTranslator/TV/`: `SdbClient.swift` (tự nói giao thức sdb qua
TCP 26101 — sdb macOS của Samsung chỉ có x86_64, không chạy trên Apple Silicon thiếu Rosetta, nên KHÔNG đóng kèm sdb),
`WgtSigner.swift`, `SamsungCert.swift`, `TvKeys.swift` (.p12 đọc/ghi qua `/usr/bin/openssl` LibreSSL), `TvInstaller.swift`;
UI `UI/TvInstallView.swift` (nút trên header màn Bắt đầu + icon TV ở màn dịch; cờ test `--tv-install`). Makefile chép
`windows/tizen/SubtitleTV/*` và `windows/tizen/ca/*` vào `Subly.app/Contents/Resources/tv/`.
Chứng chỉ: `~/Library/Application Support/ScreenTranslator/tv-certs/<tên>` (app xin) và `~/SamsungCertificate/<tên>`
(chép từ máy Windows sang được, cần `password.txt`; `*.pwd` DPAPI không giải được trên Mac). Cùng biến môi trường test.
Đã kiểm offline (18/10/2026): xin chứng chỉ với máy chủ ký giả, CSR/SAN đúng, .wgt ký xong tự xác minh lại OK.
Chưa chạy thật với TV (TV chỉ nhận kết nối từ IP trong ô Host PC IP).

## Cách 2 — script tự động (máy không có Subly)
`windows\tizen\auto-install.ps1 -Tv <IP-TV>` (hoặc `TU-DONG-CAI-TV.bat`), cùng logic như Cách 1. Bộ cài cho máy khác:
`windows\tizen\make-installer.ps1` → `windows\dist\SubtitleTV-Installer\` (+ .zip): sdb.exe, app, script, CA, các bộ
chứng chỉ trong SamsungCertificate (mật khẩu giải ra chữ — chỉ đưa người tin tưởng; `-NoCerts` / `-Only <tên>`).
`-NewCert`: luôn xin chứng chỉ mới. `-Reinstall`: gỡ app cũ trước. Đăng nhập Samsung thật đã chạy thành công (18/10/2026).

## Cách 3 — làm tay từng bước
1. **IP máy tính:** `Get-NetIPAddress -AddressFamily IPv4` (lấy IP LAN thật, bỏ `vEthernet`/`172.*`).
2. **Developer Mode trên TV:** Apps → remote **1 2 3 4 5** → Developer mode ON → **Host PC IP** = IP máy tính →
   **tắt TV rồi mở lại**.
3. **IP TV:** Settings → General → Network → Network Status.
4. **DUID:** `windows\Vendor\tizen\sdb.exe connect <IP-TV>` rồi `… -s <IP-TV>:26101 shell 0 getduid`
   (mã model như `QA65S95BAKXXV` KHÔNG phải DUID). sdb connect fail → kiểm tra Developer Mode + Host PC IP + cùng mạng.
5. **Chứng chỉ có DUID:** `.\samsung-cert.ps1 -Out C:\Users\LipNguyen\SamsungCertificate\<tên> -Duid <DUID>`
   (người dùng tự đăng nhập Samsung trên trình duyệt; cần cổng 4794 trống). Thư mục có sẵn thì cộng thêm DUID,
   giữ nguyên author.
6. **Ký + cài:** `cd windows\tizen; .\deploy.ps1 -Profile <tên> -Tv <IP-TV>` (thêm `-Debug` để có DevTools).
   **Chỉ build zip** cho máy khác: `.\deploy.ps1 -Profile <tên> -Kit -KitName SubtitleTV-<tên>` → `windows\dist\`
   (wgt đã ký + sdb.exe + `CAI-LEN-TV.bat`; giải nén → bấm đúp → nhập IP TV).

## Lưu ý
- Đổi DUID/cert thì **phải ký lại .wgt** — cài lại .wgt cũ vẫn lỗi certificate y hệt.
- `deploy.ps1` đặt tên gói `SubtitleTV.wgt` (tên có dấu cách làm trình cài trên TV báo lỗi).
- Đăng nhập Samsung là bước tương tác trên trình duyệt, Claude không làm hộ được.
- TV LG (webOS) ở `windows/webos/` dùng cơ chế khác — skill này chỉ cho Samsung.
