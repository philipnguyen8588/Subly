# ScreenTranslator cho Windows

> Bản port Windows của app macOS ở thư mục gốc (Swift). Giấy phép: GNU AGPL-3.0 (xem [../LICENSE](../LICENSE)), vì phần PS5 nhúng libchiaki của chiaki-ng (AGPL-3.0).

App dịch chữ trên màn hình theo thời gian thực cho phim và game: chọn vùng phụ đề → **OCR → dịch → đọc → overlay → nhật ký song ngữ**. Bấm phím tắt để **dịch + tóm tắt toàn bộ chữ trên màn hình game** (bản dịch đặt đè đúng vị trí). Có nguồn hình **PS5 Remote Play nhúng**, **xem phụ đề trên điện thoại** qua mạng nội bộ, profile theo game, thuật ngữ, tên nhân vật.

Viết bằng C# / .NET 8 / WPF. Toàn bộ logic giữ như bản macOS (lọc menu/UI, tách câu thoại, học tên người nói, lọc trùng, soi thông minh, hàng đợi dịch có thứ tự, fallback model Gemini, Edge TTS…); chỉ thay các API riêng của Apple bằng API Windows.

## Build

Yêu cầu: Windows 10 2004+ / Windows 11 x64, [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).

```powershell
cd windows
.\build.ps1            # tải sherpa-onnx + danh sách từ, dựng PS5 (nếu có MSYS2), build Release
.\build.ps1 -SkipPS5   # bỏ qua phần PS5
.\build.ps1 -Publish   # xuất bản thư mục chạy được: windows\dist\ScreenTranslator
.\build.ps1 -Run       # build rồi mở app
```

Chỉ cần build app (không có giọng AI offline / PS5) thì `dotnet build windows\ScreenTranslator.sln` là đủ: thiếu thư viện native thì app vẫn chạy, các tính năng đó báo "chưa cài".

| Phần | Script | Ghi chú |
|---|---|---|
| Giọng AI offline | `Scripts\fetch-sherpa.ps1` | sherpa-onnx v1.13.8 win-x64 (cùng phiên bản bản macOS). Cần Visual C++ Redistributable 2015-2022 x64 |
| Danh sách từ tiếng Anh | `Scripts\fetch-words.ps1` | Thay `/usr/share/dict/words` của macOS |
| PS5 (`st_chiaki.dll`) | `Scripts\build-chiaki.sh` | Chạy trong [MSYS2](https://www.msys2.org/) MINGW64 (build.ps1 tự gọi). Tự cài gói pacman, clone chiaki-ng, dựng FFmpeg tối giản (chỉ decoder H.264/HEVC + swscale), rồi liên kết `native\st_chiaki` |
| Icon | `Scripts\make-icon.ps1` | Sinh `AppIcon.png` / `AppIcon.ico` |

Thư viện tải/dựng nằm trong `windows\Vendor\` (không commit) và được chép cạnh `ScreenTranslator.exe` khi build.

### Bản phát hành có duyệt máy (tuỳ chọn)

Giống bản macOS: nếu có file `subly.local.env` ở **thư mục gốc repo** (dùng chung Mac + Windows) thì bản build sẽ chỉ chạy
các tính năng dịch trên máy đã được duyệt ở [server](../server/). Không có file thì bản build là bản dùng riêng, không kiểm
tra gì.

```
# subly.local.env (gốc repo, không commit)
SUBLY_SERVER=https://translate.helioapple.com
SUBLY_PUBKEY=<public key do `docker compose run --rm subly keygen` in ra>
```

`build.ps1` (và `dotnet build` khi chưa có file cấu hình) tự chạy `Scripts\gen-runtime-config.ps1` để sinh
`ScreenTranslator\Core\RuntimeConfigValues.cs` (server + public key được XOR mỗi lần build, không nằm nguyên văn trong
file chạy; file này không commit). App luôn mở bình thường; chỉ **Bắt đầu / Dịch màn hình / Tóm tắt** mới kiểm tra, và
chỉ hiện một màn hình lỗi chung chung (không nói gì về duyệt/giấy phép). Lần đầu app hỏi email để gửi kèm lên server cho
chủ app nhận ra máy. Máy đã duyệt nhận vé ký Ed25519 hạn 7 ngày nên vẫn chạy khi tạm mất mạng.

## Lần đầu sử dụng

1. **OCR tiếng Anh**: app dùng Windows OCR có sẵn. Nếu báo "Chưa cài OCR tiếng Anh": Settings → Time & language → Language & region → thêm *English (United States)*.
2. **Engine dịch** (⚙ → Dịch): dán Gemini API key miễn phí (<https://aistudio.google.com/apikey>) → *Lưu key* → *Test key*. Không có key thì app dùng Google Translate (miễn phí, không cần key).
3. **Giọng đọc** (⚙ → Voice):
   - **Windows**: giọng có sẵn, tức thì. Muốn giọng tiếng Việt: Settings → Time & language → Speech → Add voices → Vietnamese.
   - **Giọng AI offline**: Piper tiếng Việt (NGHI-TTS), tải ngay trong Cài đặt (61 MB mỗi giọng).
   - **Microsoft Edge**: giọng neural miễn phí qua mạng (trễ 3–5 s).
4. **Tab Màn hình** → *Chọn vùng game*: kéo chuột quanh toàn bộ khu vực hình của game. App chụp một tấm để bạn *Vẽ khung phụ đề* (có sẵn ở dải dưới).
5. **Bắt đầu** (Ctrl+Alt+S). Hiểu cả màn hình: **Ctrl+Alt+T**.

Đóng cửa sổ thì app vẫn chạy nền: biểu tượng ở khay hệ thống (góc phải taskbar) để mở lại hoặc *Thoát*.

## Khác bản macOS

| macOS | Windows |
|---|---|
| ScreenCaptureKit | GDI `BitBlt`; vùng bám cửa sổ chụp bằng `PrintWindow(PW_RENDERFULLCONTENT)` nên vẫn dịch khi cửa sổ bị che (cửa sổ DirectX/fullscreen không vẽ được thì tự chụp màn hình). Cửa sổ của app (overlay…) được loại khỏi ảnh chụp bằng `WDA_EXCLUDEFROMCAPTURE` |
| Vision OCR | Windows.Media.Ocr (en-US) |
| Apple Translation | Google Translate (endpoint miễn phí `translate.googleapis.com`) |
| Apple Intelligence | Bỏ (không có tương đương). Không có Gemini thì *Dịch màn hình* chỉ dịch từng dòng, không tóm tắt |
| AVSpeechSynthesizer | Windows.Media.SpeechSynthesis (giọng OneCore) |
| Carbon hotkey ⌥⌘S/T/V/O | `RegisterHotKey` **Ctrl+Alt+S/T/V/O** (đổi được) |
| VideoToolbox (H.264 PS5) | FFmpeg (libavcodec) trong `st_chiaki.dll` |
| UserDefaults | `%APPDATA%\ScreenTranslator\settings.json` |
| File `.secret` quyền 0600 | File `.secret` mã hoá DPAPI (chỉ tài khoản Windows hiện tại đọc được) |
| Network.framework (web) | `TcpListener` IPv4 (không cần quyền admin; lần đầu Windows hỏi cho qua tường lửa: chọn mạng *Private*) |
| `pmset displaysleepnow` | `SC_MONITORPOWER` + giữ máy thức |
| Toạ độ CoreGraphics (point) | Pixel vật lý toàn cục (app chạy Per-Monitor DPI v2) |
| Nhập khoá từ chiaki-ng (CFPreferences) | Registry `HKCU\Software\Chiaki\Chiaki` hoặc `%APPDATA%\Chiaki\Chiaki.ini` |
| Icon Dock | Biểu tượng khay hệ thống |

Không port: `--show-frames` / khung kéo-thả trên màn hình (`RegionFrameEditor`), vốn chỉ dùng để debug ở bản macOS.

## Dữ liệu

`%APPDATA%\ScreenTranslator\`:

- `settings.json`: profile, vùng, cài đặt
- `history.sqlite`: nhật ký + dịch màn hình (cùng schema với bản macOS), `shots\`: ảnh dịch màn hình (50 ảnh gần nhất mỗi game)
- `gemini-api-key.secret`, `ps5host.secret`: mã hoá DPAPI
- `voices\`: giọng AI offline, `app.log`: log (cắt khi > 2 MB)

## Tham số dòng lệnh (test / automation)

```powershell
ScreenTranslator.exe --clear-regions --add-region 100,100,1000,120,PhuDe --add-region 100,100,1600,900,ManHinhGame,manual `
  --autostart --mute --quiet --hidden --analyze-once
```

Toạ độ là pixel vật lý toàn cục (gốc trên-trái màn hình chính). Thêm: `--translate "câu 1|câu 2"`, `--translate-engine auto|google`, `--speak "a|b"`, `--voice-engine windows|local|edge`, `--download-voice <id>`, `--feed "a|b"`, `--profile <tên>`, `--delete-profile <tên>`, `--test-region x,y,w,h`, `--gemini-key`, `--gemini-base-url`, `--no-web`, `--web-port N`, `--no-overlay`, `--tab source|log|speakers`, `--open-settings`, `--show-shot`, `--ps5-import`, `--ps5-connect`, `--ps5-discover`.

Chỉ có ở bản Windows: `--snap <thư mục>` (chụp từng vùng ra PNG + OCR thử), `--render-ui <thư mục>` (vẽ mọi tab/trang cài đặt ra PNG), `--quit-after <giây>` (tự thoát). Kết quả ghi vào `app.log`.

## Cấu trúc

```
windows/
  ScreenTranslator.sln, build.ps1
  ScreenTranslator/          app C# (WPF)
    AppSettings.cs Pipeline.cs App.xaml(.cs)
    Models/ Capture/ OCR/ Analyze/ Translate/ Speech/ Support/ History/ PS5/ Web/ UI/ Native/
  native/st_chiaki/          cầu nối C tới libchiaki + giải mã H.264 (FFmpeg)
  Scripts/                   tải / dựng thư viện phụ
```
