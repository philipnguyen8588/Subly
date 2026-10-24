---
name: day-app-tivi
description: >-
  Đẩy (nạp) app Subtitle TV mới lên server translate.helioapple.com để app Mac / Windows lấy bản mới nhất khi bấm
  "Cài app lên TV" — không cần build lại Subly. Dùng khi người dùng nói "đẩy app tivi lên server", "cập nhật app TV",
  "up app tivi", "nạp app TV mới", hoặc vừa sửa windows/tizen/SubtitleTV và muốn các máy cài bản mới.
  Publish the updated Samsung Tizen TV app (SubtitleTV) to the Subly server.
---

# Đẩy app Subtitle TV lên server

App TV là thư mục `windows/tizen/SubtitleTV` (config.xml, index.html, main.js, style.css, icon.png — danh sách ở
`TV_FILES` trong `Makefile`). Server phát zip **chưa ký** của thư mục này ở `GET /v1/tv/app` (`server/tvapp.go`). Khi bấm
"Cài app lên TV", app Mac (`Sources/ScreenTranslator/TV/TvAppSource.swift`) / Windows (`windows/ScreenTranslator/TV/TvAppSource.cs`)
tải bản đó (ETag, không đổi thì không tải lại), ký bằng chứng chỉ của TV rồi cài. Mất mạng → bản đã tải lần trước →
bản đóng kèm app.

Làm hết các bước **không cần hỏi lại**.

## 1. Kiểm tra mã nguồn

- `git status windows/tizen/SubtitleTV` — xem đúng là bản cần đẩy. Có file mới trong app TV thì thêm vào `TV_FILES`
  trong `Makefile` (và danh sách `<None Include=…>` trong `windows/ScreenTranslator/ScreenTranslator.csproj`).
- Nên tăng `version="…"` trong `windows/tizen/SubtitleTV/config.xml` (log cài trên app hiện version → dễ biết TV đang
  bản nào). Không bắt buộc: TV vẫn nhận cài đè cùng version.
- `node --check windows/tizen/SubtitleTV/main.js` nếu có node (bắt lỗi cú pháp trước khi lên TV).

## 2. Đóng gói

```sh
make tv-zip                      # → build/SubtitleTV.zip, in danh sách file
shasum -a 256 build/SubtitleTV.zip
```

## 3. Nạp lên server

Server: DeployTool project **`Translate-screen-server`** (local `server/` → `/app/translate-screen` trên VPS EbayServer).

1. `mkdir -p server/import-tv && cp build/SubtitleTV.zip server/import-tv/` (thư mục đã nằm trong `server/.gitignore`).
2. `mcp__DeployTool__connect_project` → `Translate-screen-server`, rồi `mcp__DeployTool__upload_files` với
   `files: ["import-tv/SubtitleTV.zip"]`.
3. `mcp__DeployTool__run_command`:
   ```sh
   cd /app/translate-screen && docker compose run --rm -v /app/translate-screen/import-tv:/seed:ro subly import-tv /seed/SubtitleTV.zip && mv import-tv ../translate-screen-backup/import-tv-<YYYYMMDD-HHMMSS>
   ```
   Phải in `đã nạp app TV StSubTV001.SubtitleTV (version …, N file)`. Lỗi `lệnh không rõ: import-tv` = server trên VPS
   còn bản cũ → deploy server trước (upload các file .go đã đổi rồi `docker compose up -d --build`; hỏi người dùng
   trước vì server khởi động lại). Guard của DeployTool chặn `rm`, nên dọn bằng `mv` sang thư mục backup.
4. `rm -rf server/import-tv`
5. Xác minh qua domain thật — ETag phải trùng SHA-256 ở bước 2:
   ```sh
   curl -sI https://translate.helioapple.com/v1/tv/app | grep -iE "^HTTP|etag|x-tv-version"
   ```

Không dùng `sync`/`sync_and_delete` của DeployTool cho việc này. Bản trước vẫn còn ở `data/tv/SubtitleTV.prev.zip` trên
VPS; muốn quay lại thì nạp lại file đó bằng cùng lệnh `import-tv`.

## 4. Commit

Commit thay đổi trong `windows/tizen/SubtitleTV` (message kiểu "SubtitleTV: …" kèm dòng Co-Authored-By) nếu chưa
commit. **Push** chỉ khi người dùng bảo. Không cần build lại app Mac / Windows (bản đóng kèm chỉ là dự phòng).

## 5. Báo lại người dùng

Ngắn gọn: version đã nạp, xác minh OK (ETag khớp). Nhắc: TV **không tự cập nhật** — mở Subly → "Cài app lên TV" cho
từng TV, log sẽ ghi "App TV: đã tải bản mới nhất từ server (version …)".
