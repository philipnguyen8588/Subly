# ScreenTranslator

> Giấy phép: GNU AGPL-3.0 (xem [LICENSE](LICENSE)), vì app nhúng libchiaki của chiaki-ng (AGPL-3.0).

App macOS dịch text trên màn hình theo thời gian thực cho phim và game. Chọn vùng phụ đề, app **OCR → dịch → đọc bằng giọng hệ thống → hiện overlay → lưu nhật ký song ngữ**. Với cửa sổ game, vẽ một vùng lớn và bấm phím tắt để **dịch + tóm tắt toàn bộ chữ trên màn hình**.

Thiết kế ưu tiên nhẹ: một process Swift (~100 MB RAM), OCR bằng Vision trên Neural Engine (~10–50 ms), chỉ dịch khi text thực sự đổi, không thư viện ngoài.

## Giao diện

Header: Bắt đầu/Dừng, trạng thái engine dịch, chọn **game**, bật/tắt voice và overlay, nút tắt màn hình, Cài đặt.

**Game (profile)**: mỗi game giữ riêng nguồn hình, khung phụ đề, thuật ngữ và tên nhân vật. *Game mới…* trong menu game hỏi tên game và nguồn hình. Đổi tên/xoá ở Cài đặt → Game.

Ba tab:

- **Màn hình**: chọn nguồn hình của game bằng công tắc ở góc trái.
  - **App trên máy này**: chỉ có hai khung. *Chọn vùng game* để vẽ khung quanh toàn bộ khu vực hiển thị game trên màn hình; app chụp **một tấm ảnh** của vùng đó để hiện trong tab (bấm *Chụp màn hình game* để chụp lại). App không chụp toàn vùng liên tục vì đo thực tế việc đó làm WindowServer tăng từ ~13 % lên ~40 % CPU; chỉ khung phụ đề được chụp liên tục (4 fps). *Vẽ khung phụ đề* rồi kéo chuột ngay trên ảnh để đặt khung phụ đề. Cả hai khung bám theo cửa sổ của game (di chuyển, đổi cỡ).
  - **PS5**: kết nối Remote Play nhúng (xem mục Tab PS5 bên dưới), vẽ khung phụ đề trên hình PS5.
  - Cả hai chế độ: *Dịch màn hình* (⌥⌘T) chụp hình, dịch mọi khối chữ và đặt bản dịch đè đúng vị trí; dải dưới hình chỉ hiện bản dịch của phụ đề.
- **Nhật ký**: hai mục *Phụ đề* (hai cột Việt | gốc, mốc giờ theo đoạn hội thoại, tên người nói in đậm, rê chuột để xem giờ/engine và copy) và *Dịch màn hình* (tóm tắt + bảng dịch, không lưu ảnh chụp). Tìm kiếm, xuất TXT / SRT / JSON.
- **Nhân vật**: bật/tắt "game có hiện tên người nói", danh sách tên đã học.

Đóng cửa sổ thì app vẫn chạy nền; bấm icon Dock (hoặc ⌘1) để mở lại. App không có icon trên thanh menu.

## Pipeline

```
ScreenCaptureKit (chỉ vùng đã chọn, 4 fps)
 → FrameGate (chữ ký 64×8; chỉ đi tiếp khi ảnh đổi rồi ổn định 250 ms)
 → Vision OCR (.fast, en-US) → bỏ dòng trùng (≥ 90 % giống dòng trước)
 → TranslationQueue (phụ đề: chỉ giữ câu mới nhất)
 → TranslationRouter: Gemini API (free tier, token bucket RPM/RPD, glossary, ngữ cảnh 5 câu)
                     → fallback Apple Translation on-device khi hết quota / lỗi / offline / không có key
 → AVSpeechSynthesizer + Overlay + SQLite

Dịch thủ công: SCScreenshotManager → Vision OCR (.accurate, từng dòng)
 → Gemini JSON mode {summary, lines[]}  (Apple: dịch theo lô, không tóm tắt) → pane Phân tích + SQLite
```

## Yêu cầu

- macOS 15+ (đã test macOS 27, Apple Silicon)
- Xcode Command Line Tools (không cần Xcode)
- Gemini API key miễn phí: <https://aistudio.google.com/apikey> (không cần thẻ), hoặc chỉ dùng Apple Translation offline

## Build & chạy

```bash
make app     # swift build -c release + đóng gói build/ScreenTranslator.app (kèm icon)
make install # build rồi cài vào /Applications/ScreenTranslator.app (mở từ Launchpad/Spotlight)
make run     # cài rồi mở app
make debug   # chạy từ terminal để xem log
make icon    # sinh lại Resources/AppIcon.icns từ Scripts/make-icon.swift
```

> Command Line Tools không có macro plugin (SwiftUIMacros) cho SDK macOS 27, nên Makefile build với `SDKROOT=…/MacOSX26.5.sdk`. Có Xcode thì bỏ dòng đó.

## Lần đầu sử dụng

1. **Quyền Ghi màn hình**: bấm *Bắt đầu* lần đầu, macOS sẽ hỏi. Bật ScreenTranslator trong *System Settings → Privacy & Security → Screen & System Audio Recording*.
2. **Engine dịch** (⚙ → tab *Dịch*), một hoặc cả hai:
   - Dán Gemini API key → *Lưu key* → *Test key*.
   - *Tải gói ngôn ngữ Anh → Việt* của Apple (offline; dùng khi hết quota / mất mạng / không có key).
3. **Vùng phụ đề**: bấm *+ Thêm* ở mục Vùng phụ đề → kéo chuột quanh chỗ phụ đề → đặt tên.
4. **Vùng thủ công**: bấm *+ Thêm* ở mục Vùng dịch thủ công → kéo quanh toàn bộ cửa sổ game.
5. **Bắt đầu** (⌥⌘S). Khi cần hiểu cả màn hình: **⌥⌘T**.

Vùng gắn với toạ độ màn hình. Di chuyển/resize cửa sổ game thì *Chọn lại* vùng. Game fullscreen thì không cần.

## Tên người nói & gắn vùng vào app

- **Game có hiện tên người nói** (card trong cột Vùng, theo profile): app tự học tên nhân vật từ câu dạng `Atreus: …`, sửa khi OCR đọc sai dấu hai chấm (`Angrboda, …`, `Angrb0da. …`) thành `Angrboda: …` trước khi dịch, gửi danh sách tên cho Gemini để không dịch tên, và **không đọc tên khi phát voice**. Tắt toggle này với game không hiện tên. Thêm/xoá tên thủ công ngay trên card.
- **Gắn vùng với app**: khi vẽ vùng, app ghi nhớ cửa sổ nằm dưới vùng (ví dụ Microsoft Edge) và vị trí vùng so với cửa sổ đó. Hai chế độ khi Tab qua app khác (menu trên card):
  - **Vẫn dịch (bám cửa sổ)** – mặc định: chụp thẳng cửa sổ app bằng ScreenCaptureKit nên dù cửa sổ bị che hay bạn đang ở app khác vẫn lấy đúng phụ đề; kéo cửa sổ đi chỗ khác vẫn đúng. Đổi kích thước cửa sổ thì vùng tự co giãn theo tỉ lệ (kiểm tra mỗi 0,7 s, kể cả khi đang dịch); nếu nội dung không co giãn theo cửa sổ (ví dụ video giữ nguyên cỡ) thì *Chọn lại*.
  - **Tạm dừng**: chụp màn hình, ngừng khi app không ở phía trước.
- **Tách câu thoại, không đọc lại câu cũ**: kết quả OCR được tách thành từng câu thoại theo hàng mở đầu bằng `Tên:` hoặc gạch đầu dòng `-`, rồi lọc trùng theo từng câu. Game giữ câu cũ và hiện thêm câu mới bên dưới thì chỉ câu mới được dịch và đọc. Hai người nói hiện cùng lúc thành hai dòng riêng trong nhật ký và được đọc nối tiếp nhau. Game không hiện tên vẫn bỏ được câu cũ nếu nó nằm ở các hàng trên.
- **Chỉ nhận chữ ở giữa khung** (Cài đặt → Capture & OCR, mặc định bật): phụ đề luôn canh giữa, nên trong vùng phụ đề chỉ cụm chữ chạm dải giữa khung (40–60 % bề ngang) mới được nhận. Chữ ở mép như nút Quick Save, Back, biển hiệu trong cảnh game bị bỏ, kể cả khi nằm cùng hàng với phụ đề. Tắt nếu game canh phụ đề sang trái.
- **Câu quá đơn giản** (Cài đặt → Capture & OCR, mặc định bật): câu còn tối đa 2 từ sau khi bỏ tên người nói ("V: No.", "Mechanic: What?"), hoặc tối đa 5 từ mà toàn từ cơ bản ("Okay, let's go."), không được dịch hay đọc, vì mục tiêu là hiểu nội dung game chứ không phải đọc hết. Câu gốc vẫn được ghi vào nhật ký (hiện mờ, cột bản dịch để "—"). Câu ngắn không có từ tiếng Anh thật nào (OCR đọc bậy như "Imph.") thì bỏ hẳn; tra theo từ điển `/usr/share/dict/words` của macOS.
- **Bỏ chữ lạc**: (1) app học cỡ chữ phụ đề từ các câu dài đã nhận trong phiên và bỏ hàng chữ nhỏ hơn 60 % cỡ đó (chữ trên bảng điều khiển xe, biển hiệu nhỏ); (2) khi bật *Bỏ qua chữ giao diện*, mẩu chữ đứng một mình tối đa 2 từ, không có tên người nói và không có dấu câu ("mph", "Quick", "BACK") không được dịch hay đọc; log ghi `LẠC[...] bỏ qua`.
- **Soi thông minh** (Cài đặt → Capture & OCR, mặc định bật): sau khi nhận một câu phụ đề, app ước lượng câu đó còn nằm trên màn hình bao lâu (theo số từ) và nghỉ nửa thời gian đó trừ đi khoảng app chưa nhìn màn hình trước khi thấy câu, từ 0,3 đến 1,2 giây: không so khung, không OCR (nghỉ ngắn để câu ngắn hiện ngay sau không bị lọt). Câu cũ còn nguyên trên màn hình thì soi thưa dần (0,4 → 0,6 s); màn hình menu nghỉ 0,8 s. Hết nghỉ là OCR ngay khung kế tiếp. Dòng `STATS` trong log ghi thêm `nghỉ/10s` là số khung đã bỏ qua.
- **Đọc hết từng câu theo thứ tự** (mặc định): phụ đề đổi nhanh hơn tốc độ đọc thì câu đang đọc không bị cắt và không câu nào bị bỏ; câu kế tiếp tự đọc nhanh thêm 10 % để bắt kịp (chỉnh ở Cài đặt → Voice). Muốn kiểu cũ thì bật “Ngắt câu đang đọc khi có câu mới” và đổi hàng đợi sang “chỉ giữ câu mới nhất”.
- **Bỏ qua menu / màn hình cài đặt** (Cài đặt → Capture & OCR, mặc định bật): khi vùng phụ đề bị phủ bởi chữ giao diện (menu, cài đặt, danh sách mod…), app chấm điểm kết quả OCR theo heuristic (< 1 ms, không gọi AI): nhiều từ Viết Hoa Đầu Chữ, nhiều mảnh chữ cùng hàng (cột), ≥ 4 hàng, cỡ chữ lẫn lộn, nhiều số/nhãn có dấu hai chấm, cụm từ lặp. Từ 3 điểm trở lên thì **không dịch, không đọc**, ẩn overlay; tab Dịch hiện "Đang bỏ qua chữ giao diện…" và thẻ vùng hiện `⏸` trước dòng OCR. Câu đang đọc dở không bị cắt. Game dùng phụ đề TOÀN CHỮ HOA vẫn qua được (tiêu chí viết hoa bị bỏ khi ≥ 90 % chữ là hoa). Nếu phụ đề của một game bị bỏ qua nhầm, xem log `UI[...] bỏ qua (lý do)` rồi tắt toggle này.

## Engine dịch, giọng AI offline, Remote Play

**Engine dịch phụ đề** (Cài đặt → Dịch):

| Engine | Tốc độ đo trên M4 | Ghi chú |
|---|---|---|
| Tự động: Gemini → Apple Translation | ~1 s (Gemini) | Cần key và mạng, chất lượng tốt nhất |
| Apple Intelligence | 0,4–1,3 s, trung vị ~0,8 s | Model ngôn ngữ trên máy (FoundationModels, macOS 26+). Miễn phí, offline, dùng ngữ cảnh + thuật ngữ + tên nhân vật. Cần bật Apple Intelligence trong System Settings. Lỗi/quá thời gian thì rơi về Apple Translation |
| Apple Translation | 20–60 ms | Nhanh nhất, dịch từng câu rời |

Khi không có Gemini, phần *Dịch màn hình* dùng Apple Intelligence để viết tóm tắt.

**Giọng đọc** (Cài đặt → Voice → Engine):

| Engine | Trễ | Ghi chú |
|---|---|---|
| Apple | ~50 ms | Linh (Enhanced) |
| Giọng AI offline | ~0,2 s mỗi câu | sherpa-onnx + model Piper tiếng Việt của NGHI-TTS, 61 MB mỗi giọng, tải trong Cài đặt (nam: Minh Quang, Mạnh Dũng…; nữ: Lạc Phi, Ban Mai…). Một số giọng đổi cao độ nhiều giữa các câu nên nghe như nhiều người; ghi chú trong danh sách cho biết giọng nào ổn định. Lưu ở `~/Library/Application Support/ScreenTranslator/voices/` |
| Microsoft Edge | 3–5 s | Không hợp realtime |

Thư viện sherpa-onnx dựng sẵn được `make` tự tải vào `Vendor/` (script `Scripts/fetch-sherpa.sh`) và chép vào `Contents/Frameworks` của app.


## Nguồn hình PS5: lấy hình PS5 ngay trong app (nhúng libchiaki)

Nguồn **PS5** trong tab Màn hình mở một phiên Remote Play bằng thư viện lõi của [chiaki-ng](https://github.com/streetpea/chiaki-ng) được liên kết thẳng vào app. App **chỉ nhận hình** để hiển thị và OCR: không gửi điều khiển, không nhận âm thanh. Bạn chơi bằng tay cầm nối thẳng với PS5.

- **Đăng ký máy**: *Nhập từ chiaki-ng* lấy lại khoá của máy đã đăng ký trong chiaki-ng trên máy này; hoặc đăng ký mới bằng IP + PSN Account ID (base64) + mã PIN 8 số (PS5: Settings → System → Remote Play → Link Device). Khoá lưu trong file quyền 0600 ở Application Support.
- **Kết nối**: app tìm PS5 theo IP đã lưu, không thấy thì hỏi cả mạng và khớp theo địa chỉ MAC (hoặc bảng ARP), PS5 đang nghỉ thì gửi gói đánh thức, rồi mở phiên. PS5 chỉ cho **một** phiên Remote Play tại một thời điểm: phải thoát chiaki-ng / PS Remote Play trước.
- **Vùng phụ đề**: bật *Vẽ vùng phụ đề* rồi kéo chuột trên hình. Vùng lưu theo tỉ lệ khung hình trong game đang chọn; *Dịch màn hình* dùng toàn bộ khung hình. Bản dịch hiện ngay dưới hình.
- **Dịch màn hình**: nút *Dịch màn hình* ở thanh trên cùng (mọi tab, hoặc ⌥⌘T) chụp khung hình hiện tại, OCR từng khối chữ kèm vị trí (các dòng của cùng một đoạn văn được gộp để dịch trọn ý), rồi mở modal với ảnh chụp và bản dịch đặt đè đúng chỗ chữ gốc. *Xem bản gốc* để so sánh, rê chuột lên một khối để xem câu gốc, ←/→ để xem các ảnh chụp trước, Esc để đóng. Tab Nhật ký → Dịch màn hình liệt kê các ảnh đã chụp; bấm để mở lại. Ảnh được thu về tối đa 1600 px, nén JPEG và lưu ở `shots/` trong Application Support; mỗi game giữ 50 ảnh gần nhất, mục cũ hơn chỉ còn phần chữ.
- **Nhật ký theo game**: phụ đề đã dịch và ảnh dịch màn hình lưu kèm game đang chọn; tab Nhật ký, xuất file và nút xoá chỉ tác động lên game đó, đổi game là đổi nhật ký. Dòng có từ trước khi tách theo game (nếu còn) xem bằng nút *Dòng cũ*.
- **Chất lượng**: 1080p/30 fps mặc định (chữ nét cho OCR), đổi được sang 720p hoặc 60 fps. Giải mã H.264 bằng phần cứng (VideoToolbox); OCR lấy thẳng khung đã giải mã, không cần quyền Ghi màn hình.
- **Build**: `make` tự chạy `Scripts/build-chiaki.sh` (clone chiaki-ng vào `Vendor/`, dựng `libchiaki.a` bằng cmake). Cần `brew install cmake pkgconf json-c miniupnpc libevent nanopb opus openssl@3 uv`. Các thư viện này liên kết tĩnh; curl dùng bản của macOS.
- **Tắt màn hình**: nút mặt trăng trên header (hoặc menu trên thanh menu) tắt màn hình sau 2 giây bằng `pmset displaysleepnow` và giữ máy không ngủ cho tới khi màn hình bật lại; phiên PS5, dịch và giọng đọc vẫn chạy. Di chuột hoặc gõ phím để bật lại. Chỉ có tác dụng với tab PS5: vùng chụp màn hình/cửa sổ không có hình khi màn hình tắt.
- **Giấy phép**: libchiaki là AGPL-3.0. Nếu phát hành app có nhúng nó cho người khác, toàn bộ mã nguồn app phải công khai theo AGPL.

## Xem trên iPhone / iPad (máy chủ web trong mạng nội bộ)

App tự mở một máy chủ web nhỏ (mặc định cổng 8787, đổi hoặc tắt trong Cài đặt → iPhone / Web). Trên iPhone/iPad cùng mạng Wi‑Fi, quét mã QR trong tab cài đặt đó hoặc mở `http://<IP máy Mac>:8787` bằng Safari. Không cần cài app; *Chia sẻ → Thêm vào MH chính* để mở toàn màn hình.

- **Phụ đề**: câu đang dịch hiện chữ lớn ở dưới cùng; phía trên là 100 câu gần nhất, mờ, cuộn lên để xem lại. Tên nhân vật tô cùng màu với app. Nút `EN` bật/tắt câu gốc, `A−`/`A+` đổi cỡ chữ, chạm vào phụ đề để ẩn hết thanh. Hai nút nổi ở góc trên trái: *Dừng / Tiếp tục* (như ⌥⌘S) và *Dịch màn hình*.
- **Dịch màn hình**: chạy đúng chức năng ⌥⌘T trên Mac rồi mở ảnh chụp màn hình game phủ kín điện thoại, bản dịch đặt đè đúng vị trí chữ gốc như trên app. *Xem bản gốc* để so sánh, chạm một khối để xem câu gốc, vuốt ngang hoặc bấm ‹ › để xem các ảnh chụp trước. Tab *Dịch màn hình* liệt kê các ảnh đã chụp; mục cũ hơn 50 ảnh gần nhất chỉ còn chữ.
- **Nhật ký**: 300 câu gần nhất (mới nhất ở dưới cùng), có ô tìm, tự thêm câu mới.
- **Theo game**: trang web chỉ hiện nhật ký và ảnh của game đang chọn trên app; đổi game trên app thì trang tự nạp lại. Dòng nhật ký có từ trước khi có tính năng này không gắn với game nào nên chỉ xem được trên app (nút *Dòng cũ*).

Chỉ nghe IPv4 và chỉ nhận máy có địa chỉ mạng nội bộ; không có mật khẩu, nên tắt khi dùng Wi‑Fi công cộng. Safari chỉ cho giữ màn hình sáng trên HTTPS, nên muốn iPhone không tự khoá: Cài đặt → Màn hình & Độ sáng → Tự động khoá → Không. Mã ở `Sources/ScreenTranslator/Web/` (Network.framework, không thêm thư viện).

## Phím tắt toàn cục (đổi được trong Cài đặt → Phím tắt)

| Phím | Chức năng |
|---|---|
| ⌥⌘S | Bắt đầu / Dừng dịch phụ đề |
| ⌥⌘T | Dịch màn hình (thủ công) |
| ⌥⌘V | Bật / tắt voice |
| ⌥⌘O | Bật / tắt overlay |

Dùng Carbon hotkey nên hoạt động cả khi game fullscreen, không cần quyền Accessibility.

## Cài đặt đáng chú ý

| Tab | Mục | Ý nghĩa |
|---|---|---|
| Dịch | Dịch sang | Ngôn ngữ đích (vi, en, ja, ko, zh, fr, de, es, th, id). Đổi cả giọng đọc và gói Apple |
| Dịch | Model | Mặc định `gemini-2.5-flash-lite` (ổn định nhất trên free tier). Bấm *Tải danh sách* để lấy model thật của key. Model bị 503 quá tải / 404 / timeout thì app tự thử `gemini-2.5-flash-lite → gemini-flash-lite-latest → gemini-2.5-flash → gemini-3.1-flash-lite` và giữ model chạy được trong 5 phút |
| Dịch | request/phút, request/ngày | Giới hạn tự áp để không bị Gemini 429. Free tier ~10–15 RPM, 500–1000 RPD tuỳ account (xem aistudio.google.com/rate-limit) |
| Dịch | Ngữ cảnh N câu trước | Gửi kèm N cặp gốc/dịch gần nhất để dịch mượt hơn |
| Dịch | Engine | Tự động (Gemini → Apple Translation), Apple Intelligence, hoặc Apple Translation |
| Dịch | Đọc tóm tắt | Đọc phần tóm tắt sau khi dịch màn hình |
| Capture | Chờ ổn định | Tăng lên 500–800 ms nếu game có hiệu ứng chữ chạy |
| Capture | Bỏ qua chữ giao diện | Không dịch/đọc khi OCR ra chữ menu, cài đặt, danh sách (xem mục trên) |
| Overlay | Vị trí / độ mờ / câu gốc / cỡ chữ | Nút *Xem thử overlay* để xem ngay |
| Thuật ngữ | Bảng term → dịch | Tên nhân vật, thuật ngữ game; để trống = giữ nguyên. Nhập/xuất CSV `term,translation` |
| Profile | Danh sách | Mỗi game một bộ vùng + thuật ngữ; đổi nhanh ở header |
| Voice | Engine | **Apple** (offline, đọc tức thì ~50 ms; tải *Linh (Enhanced)* trong System Settings → Accessibility → Spoken Content → Manage Voices để có giọng tự nhiên hơn) là lựa chọn cho realtime. **Microsoft Edge neural** (đám mây, miễn phí, giọng nam *Nam Minh* / nữ *Hoài My*) nghe tự nhiên nhưng đo thực tế máy chủ miễn phí mất **3–5 s** mới trả âm thanh cho mỗi câu mới (câu lặp lại thì ~0,4 s nhờ cache), nên không hợp phụ đề thời gian thực. Muốn giọng Nam Minh realtime cần Azure Speech chính thức (chưa tích hợp) |
| Voice | Giọng | "Mặc định" tự chọn giọng chất lượng cao nhất mà app dùng được. Giọng Siri ("Voice 1/2…") chỉ app Apple dùng được, không hiện trong app. Tải giọng **Linh (Enhanced)** trong System Settings → Accessibility → Spoken Content → System Voice → Manage Voices… → Vietnamese |
| Voice | Tốc độ | Mặc định 0.60; câu dài tự đọc nhanh hơn 12–35 %. Không đọc tên người nói ở đầu câu |

## Tham số dòng lệnh (test / automation)

```bash
build/ScreenTranslator.app/Contents/MacOS/ScreenTranslator \
  --clear-regions \
  --add-region 100,100,1000,120,PhuDe \
  --add-region 100,100,1600,900,ManHinhGame,manual \
  --autostart --mute --quiet --hidden --analyze-once
# --gemini-key <key>, --gemini-base-url <url>
```

Kiểm thử im lặng: `--translate "câu 1|câu 2"` dịch thử qua router và ghi log, `--translate-engine auto|appleIntelligence|appleTranslation` ghi đè engine, `--speak "câu 1|câu 2"` đọc thử, `--voice-engine apple|local|edge`, `--download-voice <id>` tải giọng offline.

`--mute` tắt voice, `--quiet` không hiện hộp thoại, `--hidden` không mở cửa sổ chính, `--no-web` tắt máy chủ web, `--web-port N` đổi cổng (chạy bản thử song song với app đang mở). Toạ độ là CoreGraphics toàn cục (gốc trên-trái, point).

## Giữ quyền Screen Recording qua các lần build

App ký ad-hoc đổi chữ ký mỗi lần build, macOS có thể hỏi lại quyền. Tạo chứng chỉ self-signed tên **ScreenTranslator Dev** trong Keychain Access (*Certificate Assistant → Create a Certificate → Code Signing*), Makefile sẽ tự dùng.

## Dữ liệu

- Nhật ký + phân tích: `~/Library/Application Support/ScreenTranslator/history.sqlite`
- Gemini key: `~/Library/Application Support/ScreenTranslator/gemini-api-key.secret` (quyền 0600)
- Profile, vùng, cài đặt: UserDefaults `com.lipnguyen.ScreenTranslator`

## Khi thấy "Gemini lỗi …" ở thanh trạng thái

- **503 quá tải**: model 3.x-lite trên free tier thường xuyên quá tải; app tự chuyển model dự phòng, chỉ cần đợi câu tiếp theo.
- **404 model không có**: đổi model trong Cài đặt → Dịch → *Tải danh sách*.
- **401/403**: key sai hoặc bị thu hồi, tạo key mới.
- Nếu muốn không bao giờ mất câu kể cả khi Gemini lỗi: tải gói ngôn ngữ Apple (Cài đặt → Dịch), app sẽ tự dùng làm dự phòng.

## Lưu ý về Gemini free tier

Google dùng nội dung gửi qua free tier để cải thiện sản phẩm. Với phụ đề phim/game thì không đáng ngại, nhưng đừng đưa text nhạy cảm vào vùng theo dõi.
