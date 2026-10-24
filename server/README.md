# Server duyệt máy

App ScreenTranslator (Mac và Windows) chỉ chạy trên máy đã được duyệt ở đây.

- Máy mới mở app lần đầu được **duyệt ngay** và dùng được luôn; nó hiện trong mục **Đã duyệt** của trang quản trị, kèm
  tên máy, tài khoản, model, hệ điều hành, IP và mã phần cứng. Cần chặn máy nào thì bấm **Thu hồi**; phía người dùng chỉ
  thấy một lỗi chung chung, không có chữ nào về duyệt hay giấy phép.
- Máy bị thu hồi rồi bấm **Duyệt** lại thì trong khoảng 30 giây app trên máy đó tự mở.
- Máy đã duyệt nhận một vé có chữ ký, hạn 7 ngày (đổi bằng `TICKET_DAYS`), nên vẫn chạy được khi tạm mất mạng hoặc
  server tạm hỏng. App tự gia hạn vé khi có mạng.
- Bấm **Thu hồi** thì máy bị khoá ở lần kết nối tới, tức là trong vài giờ nếu máy có mạng, chậm nhất là khi vé hết hạn.

## Cài trên VPS (đứng sau nginx sẵn có, HTTPS qua Cloudflare)

Server này chạy như một container nối vào network của nginx sẵn có; nginx (cổng 80) route tên miền sang nó, HTTPS do
Cloudflare lo phía trước. Trên EbayServer: nginx = `ebay-manager-nginx-1`, network `ebay-manager_ebay-network`,
site config ở `/app/ebay-manager/docker/nginx/sites-enabled/`, mã server ở `/app/translate-screen`.

```sh
cd /app/translate-screen
cp .env.example .env
nano .env                        # điền ADMIN_PASSWORD, PUBLIC_HOST=translate.helioapple.com
mkdir -p data
docker compose run --rm subly keygen    # tạo data/server.key, in public key để nhúng vào app
docker compose up -d --build
```

Thêm site nginx `translate.helioapple.com` → `http://translate-screen:8080` (một file trong `sites-enabled/`, theo
mẫu `signnet.conf`), rồi `docker exec ebay-manager-nginx-1 nginx -t && ... -s reload`.

AI share chuyển request tới OpenAI / Anthropic / Gemini, có lúc lâu hơn 60 s mặc định của nginx, nên site cần thêm một
`location` riêng (đặt cạnh `location /`, cùng các dòng `proxy_*`):

```nginx
location /v1/ai/ {
    client_max_body_size 2m;
    proxy_read_timeout 150s;
    proxy_send_timeout 150s;
    # … proxy_pass và proxy_set_header giống location /
}
```

Cloudflare (gói miễn phí) vẫn cắt request quá 100 s, nên thực tế giới hạn là 100 s.

Sao lưu dữ liệu app tải lên file zip vài chục MB, nên cần thêm một `location` nữa (mặc định nginx chỉ nhận body 1 MB):

```nginx
location /v1/backups {
    client_max_body_size 100m;
    proxy_request_buffering off;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    # … proxy_pass và proxy_set_header giống location /
}
```

Cloudflare gói miễn phí nhận request tối đa 100 MB, nên server mặc định chặn bản sao lưu lớn hơn 90 MB (đổi bằng
`BACKUP_MAX_MB` trong `.env`).

## App Subtitle TV

App Mac / Windows tải mã nguồn app TV từ `GET /v1/tv/app` (zip chưa ký, ETag = SHA-256) khi bấm "Cài app lên TV",
rồi ký bằng chứng chỉ của TV đó và cài. Cập nhật app TV chỉ cần nạp zip mới, không build lại server hay app máy tính:

```sh
make tv-zip                                  # ở máy: tạo build/SubtitleTV.zip từ windows/tizen/SubtitleTV
# chép zip lên VPS vào /app/translate-screen/import-tv/, rồi:
docker compose run --rm -v /app/translate-screen/import-tv:/seed:ro subly import-tv /seed/SubtitleTV.zip
```

File nằm ở `data/tv/SubtitleTV.zip` (bản trước ở `SubtitleTV.prev.zip`). Server chưa có file → 404, app dùng bản đóng kèm.

## Sao lưu

Toàn bộ dữ liệu nằm trong `data/`: `devices.db` là danh sách máy (kèm tài khoản, AI share, game mẫu), `server.key` là
khoá ký, `tv/SubtitleTV.zip` là app TV, `backups/<id tài khoản>/<mã máy>.zip` là bản sao lưu dữ liệu app của người dùng. Chỉ cần sao lưu thư mục này. Mất `server.key` thì mọi vé cũ vô hiệu: phải tạo khoá mới, build lại app với public key mới, và các máy phải tải
bản app mới.

## Báo qua Telegram (tuỳ chọn)

Tạo bot bằng @BotFather để lấy token, nhắn cho bot một câu, rồi lấy `chat_id` ở
`https://api.telegram.org/bot<TOKEN>/getUpdates`. Điền `TELEGRAM_TOKEN` và `TELEGRAM_CHAT_ID` trong `.env`, sau đó
chạy `docker compose up -d`.

## Trang quản trị

- **Duyệt / Thu hồi / Xoá**: xoá một máy thì lần mở app tới, máy đó đăng ký lại và được duyệt lại ngay.
- **Ghi chú**: để nhớ máy của ai, ví dụ "laptop của Minh".
- **⚠ khoá khác**: có máy gửi đúng mã phần cứng này nhưng với khoá thiết bị khác. Thường là do máy đã cài lại hệ điều
  hành hoặc xoá dữ liệu app, nhưng cũng có thể là có người giả mạo mã máy. Nếu chắc là máy thật thì bấm **Ghi khoá
  mới**; lần kết nối tới, khoá mới được ghi nhận.

## AI share

Trang quản trị có thêm tab **AI share**. Ở đó bạn cho người khác dùng API key AI mà họ không thấy key:

1. Bấm **Thêm AI share**: chọn nhà cung cấp (OpenAI, Anthropic, Gemini hoặc Custom tương thích OpenAI), dán API key,
   bấm **Tải model** rồi tick các model cho phép dùng (hoặc gõ tên model vào ô "Model khác"), đặt tên gợi nhớ, bấm
   **Tạo token**.
2. Bấm **Copy** để lấy token (`sts_…`) và gửi cho người được share. Họ dán token vào app ở Cài đặt → AI → AI share,
   rồi chọn "AI share" cho từng việc ở Cài đặt → Dịch.
3. Các nút trên mỗi share:
   - **Sửa**: đổi tên, model hoặc key. Để trống ô key thì giữ key cũ. App tự nhận thay đổi ở lần mở hoặc lần bấm
     Kiểm tra kế tiếp.
   - **Token mới**: token cũ hết hiệu lực ngay.
   - **Thu hồi / Bật lại**, **Xoá**.

Cách hoạt động:
- Key và token được mã hoá AES-GCM trong `devices.db`. Khoá mã hoá suy ra từ `server.key`, nên chỉ cần sao lưu `data/`
  như trước; mất `server.key` thì các share cũ không giải mã được nữa.
- App gửi token thay cho key tới `/v1/ai/<nhà cung cấp>/…`. Server kiểm tra model trong request có nằm trong danh sách
  được share không, gắn key thật rồi chuyển tiếp tới nhà cung cấp. Key không bao giờ rời server.
- Mỗi share tối đa 120 request/phút. Địa chỉ Custom phải là `https` và không được trỏ vào IP nội bộ.
- Mọi request AI của người được share đi qua server này. Nếu Cloudflare đang chạy chế độ SSL "Flexible" (Cloudflare →
  nginx bằng HTTP thường), hãy chuyển sang **"Full (strict)"** với origin certificate để key và nội dung không đi
  qua mạng ở dạng chữ thường.

## Tài khoản sao lưu

Tab **Tài khoản** trên trang quản trị. Người dùng dùng tài khoản này trong app (Cài đặt → Sao lưu) để đẩy toàn bộ dữ
liệu app lên server, rồi khôi phục sang máy khác (kể cả Mac ↔ Windows) khi đổi máy.

- **Tạo tài khoản**: tên đăng nhập (3–64 ký tự: chữ thường, số, `. _ @ -`, ví dụ email) và mật khẩu. Để trống mật khẩu
  thì server tự tạo 12 ký tự và hiện **một lần** trên trang; gửi cho người dùng.
- **Đổi mật khẩu**: các máy đang đăng nhập phải đăng nhập lại. **Khoá**: tài khoản không đăng nhập, sao lưu hay tải
  được nữa cho tới khi **Mở khoá**. **Xoá**: xoá luôn mọi bản sao lưu của tài khoản.
- Mỗi máy giữ đúng một bản (bản mới ghi đè). Trang hiện tên máy, nền tảng, IP, ngày giờ và dung lượng từng bản; có
  nút xoá từng bản.
- Bản sao lưu có kèm API key và thông tin PS5 của người dùng, **không mã hoá** (theo yêu cầu). Ai đọc được `data/` trên
  VPS thì đọc được các key đó.
- Mật khẩu lưu dạng PBKDF2-SHA256; token đăng nhập (`sbu_…`) chỉ lưu sha256. Đăng nhập sai bị giới hạn 20 lần / 15 phút
  mỗi IP.

## Giới hạn cần biết

- Khoá chạy ở phía máy người dùng nên không tuyệt đối: người rành có thể sửa file chạy để bỏ bước kiểm tra. Server
  làm việc đó khó hơn nhiều chứ không làm nó không thể.
- Phần PS5 Remote Play của app dùng thư viện chiaki-ng, giấy phép AGPL-3.0: ai nhận app đều có quyền xin mã nguồn.

## API (cho app)

`POST /v1/session` với JSON `{h, k, n, u, m, p, o, v, ts, s}`:
- `h`: SHA-256 (hex) của mã phần cứng.
- `k`: public key Ed25519 của máy (base64url).
- `n`, `u`, `m`, `p`, `o`, `v`: tên máy, tài khoản, model, nền tảng, hệ điều hành, phiên bản app.
- `ts`: thời điểm gửi (unix giây).
- `s`: chữ ký Ed25519 của chuỗi `s1|h|k|ts`.

Trả về `{"c":0,"t":"<vé>"}` khi máy đã duyệt. Mọi trường hợp khác (chờ duyệt, thu hồi, sai chữ ký, lệch giờ quá 5
phút) đều trả `{"c":1}`.

Vé có dạng `base64url(payload) + "." + base64url(chữ ký)`, với `payload = "v1|h|k|iat|exp"`.

`POST /v1/account/login` với JSON `{username, password, device}` → `{"token":"sbu_…","username":"…"}`; sai trả 401,
tài khoản bị khoá trả 403. `POST /v1/account/logout` thu hồi token đang gửi. Các API sau gửi `Authorization: Bearer
sbu_…`, lỗi trả dạng `{"error":"…"}` (401 = phải đăng nhập lại):

- `GET /v1/backups` → `{"username", "backups": [{machine, name, platform, appVersion, ip, size, sha256, created}]}`,
  mới nhất trước.
- `PUT /v1/backups/{mã máy}?name=&platform=mac|win&v=` với body là file zip: ghi đè bản của máy đó (413 khi quá lớn).
- `GET /v1/backups/{mã máy}` tải file zip (header `X-Backup-SHA256`). `DELETE /v1/backups/{mã máy}` xoá.

Định dạng file zip (cùng cho Mac và Windows): `manifest.json`, `settings.json`, `secrets/<tên>.txt`,
`history.sqlite`, `shots/*.jpg` (xem `BackupArchive.swift` / `BackupArchive.cs`).

`GET /v1/share/info` với `Authorization: Bearer <token>` trả `{"label","provider","models"}` của AI share.

`POST /v1/ai/{openai|custom}/chat/completions`, `/v1/ai/anthropic/messages`, `/v1/ai/gemini/interactions`: proxy tới
nhà cung cấp. Token gửi ở header mà API đó vốn dùng cho key: `Authorization: Bearer`, `x-api-key` hoặc
`x-goog-api-key`. Lỗi trả dạng `{"error":{"message":"…"}}`: 403 khi token sai, share đã thu hồi hoặc model không được
share; 429 khi vượt giới hạn; 502 khi không gọi được nhà cung cấp.
