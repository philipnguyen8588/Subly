# Server duyệt máy

App ScreenTranslator (Mac và Windows) chỉ chạy trên máy đã được duyệt ở đây.

- Máy mới mở app lần đầu sẽ tự hiện trong mục **Chờ duyệt** của trang quản trị, kèm tên máy, tài khoản, model, hệ điều
  hành, IP và mã phần cứng. Phía người dùng chỉ thấy một lỗi chung chung, không có chữ nào về duyệt hay giấy phép.
- Bấm **Duyệt** thì trong khoảng 30 giây app trên máy đó tự mở.
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

## Sao lưu

Toàn bộ dữ liệu nằm trong `data/`: `devices.db` là danh sách máy, `server.key` là khoá ký. Chỉ cần sao lưu thư mục
này. Mất `server.key` thì mọi vé cũ vô hiệu: phải tạo khoá mới, build lại app với public key mới, và các máy phải tải
bản app mới.

## Báo qua Telegram (tuỳ chọn)

Tạo bot bằng @BotFather để lấy token, nhắn cho bot một câu, rồi lấy `chat_id` ở
`https://api.telegram.org/bot<TOKEN>/getUpdates`. Điền `TELEGRAM_TOKEN` và `TELEGRAM_CHAT_ID` trong `.env`, sau đó
chạy `docker compose up -d`.

## Trang quản trị

- **Duyệt / Thu hồi / Xoá**: xoá một máy thì lần mở app tới, máy đó hiện lại trong mục Chờ duyệt.
- **Ghi chú**: để nhớ máy của ai, ví dụ "laptop của Minh".
- **⚠ khoá khác**: có máy gửi đúng mã phần cứng này nhưng với khoá thiết bị khác. Thường là do máy đã cài lại hệ điều
  hành hoặc xoá dữ liệu app, nhưng cũng có thể là có người giả mạo mã máy. Nếu chắc là máy thật thì bấm **Ghi khoá
  mới**; lần kết nối tới, khoá mới được ghi nhận.

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
