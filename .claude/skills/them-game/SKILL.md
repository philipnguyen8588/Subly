---
name: them-game
description: >-
  Thêm (hoặc cập nhật) một game mẫu cho Subly: tra cứu game, soạn file glossaries/<id>.json (thuật ngữ, phong cách
  dịch, tên gọi khác, cài đặt tên người nói), kiểm tra, nạp lên server translate.helioapple.com để app tự tải về
  (không cần build lại app), rồi commit. Dùng khi người dùng nói "thêm game X", "thêm glossary/thuật ngữ cho game X",
  "tạo game mẫu X", "cập nhật/bổ sung thuật ngữ game X", hoặc gửi tên game mới cần đưa vào danh sách Game mẫu.
  Add or update a sample game (glossary + translation style) and publish it to the Subly server.
---

# Thêm game mẫu cho Subly

Game mẫu là một file `glossaries/<id>.json`. App (Mac + Windows) tải danh sách game mẫu từ server
(`GET https://translate.helioapple.com/v1/games`) khi mở và khi bấm Thêm game, nên chỉ cần **nạp lên server** là người
dùng thấy game mới; file trong repo là bản đóng kèm app (dự phòng khi mất mạng) và là bản gốc để sửa sau này.

Làm hết các bước dưới **không cần hỏi lại**, trừ khi tên game mơ hồ (nhiều game trùng tên / nhiều phần) thì hỏi đúng
một câu để chọn.

## 1. Kiểm tra game đã có chưa

```sh
ls glossaries/ | grep -i <từ khoá>
curl -s https://translate.helioapple.com/v1/games | python3 -c "import json,sys; [print(g['id'], '|', g['name'], '|', g['style']) for g in json.load(sys.stdin)['games']]"
```

- Đã có → đây là **cập nhật**: lấy bản trên server làm gốc (admin có thể đã sửa trên web, đừng ghi đè mất):
  `curl -s https://translate.helioapple.com/v1/games | python3 -c "import json,sys; g=[x for x in json.load(sys.stdin)['games'] if x['id']=='<id>'][0]; g.pop('updated',None); print(json.dumps(g,ensure_ascii=False))" > glossaries/<id>.json`
  rồi bổ sung / sửa, giữ nguyên `id`.
- Chưa có → tạo mới. `id` = tên viết thường không dấu, nối bằng `-` (giống các file có sẵn: `gta-5`, `ghost-of-yotei`,
  `final-fantasy-7-rebirth`).

## 2. Tra cứu

Dùng WebSearch / WebFetch (wiki fandom của game, trang chính thức, Wikipedia, hướng dẫn uy tín). Cần:
- Nhân vật chính, đồng hành, phản diện, nhân vật phụ hay xuất hiện trong thoại — **tên đầy đủ và cách gọi tắt**
  (họ / tên / biệt danh mà các nhân vật dùng khi nói chuyện).
- Địa danh (vùng, thành phố, khu, công trình), phe phái / tổ chức, kẻ địch / boss, vật phẩm và cơ chế có tên riêng,
  thuật ngữ cốt truyện, tiếng lóng đặc trưng.
- Bối cảnh (thời đại, thế giới) để chọn phong cách dịch.
- Phụ đề có hiện tên người nói không (mặc định hay chỉ là tuỳ chọn) và tên nằm cùng dòng hay ở dòng trên.
- Game chưa phát hành / mới ra: chỉ dùng thông tin chính thức, không dùng tin rò rỉ; ghi rõ ở `description`
  ("Trạng thái game và nguồn: …", có ngày).

Mục tiêu 100–300 thuật ngữ, ưu tiên những từ **thật sự xuất hiện trong thoại**.

## 3. Soạn file JSON

Định dạng (giống mọi file trong `glossaries/`; xem mẫu `glossaries/gta-5.json`, `glossaries/ghost-of-tsushima.json`):

```json
{
  "id": "gta-5",
  "name": "Grand Theft Auto V",
  "aliases": ["GTA V", "GTA 5"],
  "style": "modern",
  "description": "Phạm vi: …",
  "note": "",
  "showsSpeakerNames": true,
  "speakerAbove": false,
  "speakers": [],
  "glossary": [
    {"group": "Tên game", "entries": [
      {"term": "Grand Theft Auto V"},
      {"term": "GTA V"}
    ]},
    {"group": "Nhân vật", "entries": [
      {"term": "Michael De Santa"},
      {"term": "FIB", "translation": "Cục Điều tra Liên bang"}
    ]}
  ]
}
```

**Các trường**
- `name`: tên chính thức đầy đủ (có dấu, ký tự đặc biệt như ō, ö giữ nguyên).
- `aliases`: tên gọi khác của *game* (viết tắt, số La Mã / số thường, tên ngắn). Không ghi tên studio. App dùng để tìm
  và để nhận ra game người dùng tự đặt tên (phong cách "Tự động").
- `style` — chọn một:

  | style | Khi nào | Xưng hô |
  |---|---|---|
  | `modern` | hiện đại, đô thị, sci-fi, hậu tận thế, viễn tây, kinh dị hiện đại, siêu anh hùng | tôi – cậu/anh, tao – mày khi thù địch |
  | `fantasy` | trung cổ châu Âu, kỳ ảo phương Tây, hiệp sĩ, lãnh chúa, phép thuật cổ | tôi – ngài, ta – ngươi, Sir → ngài |
  | `myth` | sử thi thần thoại (Bắc Âu, Hy Lạp…), thần linh khổng lồ | ta – ngươi, cha – con |
  | `eastern` | Nhật phong kiến, Trung Hoa cổ, samurai, ninja, kiếm hiệp, thần thoại Á Đông | chúa công – thuộc hạ, sư phụ – đồ nhi, bần tăng |

  Không để `auto`. Phân vân thì theo giọng thoại thật của game (FF7 là `modern` dù tên "Final Fantasy").
- `description`: phạm vi / trạng thái phát hành / nguồn dữ liệu (chỉ để ghi nhớ, không gửi cho AI).
- `note` ("Ghi chú cho AI dịch", gửi kèm **mỗi câu phụ đề** nên mỗi ký tự đều tốn token): cách xưng hô giữa các
  nhân vật chính, để AI giữ xưng hô nhất quán. Bắt buộc với game có cốt truyện. Quy tắc:
  - Chỉ những nhân vật **nói chuyện nhiều suốt game** (nhân vật chính, đồng đội, gia đình đi cùng, phản diện chính).
    **Bỏ** nhân vật chỉ xuất hiện ít: chết ở đầu game, chỉ có trong mở đầu / hồi tưởng / vài cảnh (ví dụ FF16 bỏ Elwin
    và Anabella). Không ghi mô tả quan hệ hay tính cách: cặp xưng hô đã đủ. Tránh tiết lộ bất ngờ lớn.
  - Đúng định dạng mũi tên, mỗi dòng một cặp hoặc một nhóm, không gạch đầu dòng; mục tiêu ≤ 350 ký tự, tối đa 450:
    ```
    Xưng hô (A → B: x/y = A xưng x, gọi B là y; ↔ = cả hai chiều):
    Clive ↔ Joshua: anh/em
    Clive ↔ Byron: cháu/chú
    Cid → Clive: tôi/cậu; Clive → Cid: tôi/anh
    Cloud, Tifa → nhau: tớ/cậu
    Gav, Otto, Tarja → Clive: tôi/cậu
    Benedikta, Hugo, Barnabas, kẻ thù → Clive: ta/ngươi
    ```
    `A ↔ B: x/y` = A xưng x gọi B là y, **và** B xưng y gọi A là x (chỉ dùng cho cặp đối xứng như anh/em, cha/con,
    chú/cháu). Hai bên dùng cùng một cặp (tớ/cậu, tao/mày, ta/ngươi) thì viết `A, B → nhau: tớ/cậu`. Gộp nhiều nhân vật
    cùng cách xưng hô vào một dòng. Ghi chú thêm trong ngoặc chỉ khi thật cần (`(gắt: tao/mày)`, `("Boy" → "Con")`).
  - Tên viết đúng như trong glossary; xưng hô khớp `style`. Game ít quan hệ thì 1–3 dòng, không độn. Đặt bằng Python
    (`g['note'] = …`) rồi chạy `fmt` để giữ bố cục.
- `showsSpeakerNames`: **phải tra**, không mặc định `true`. Tìm bài accessibility (caniplaythat.com, trang
  accessibility của PlayStation / hãng) hoặc danh sách tuỳ chọn phụ đề. `true` khi phụ đề có hiện tên, kể cả khi đó
  chỉ là tuỳ chọn (ví dụ "Speaker Names") mà game tắt sẵn; khi đó báo người dùng bật tuỳ chọn này trong game. `false`
  khi phụ đề không bao giờ có tên, ví dụ FromSoftware (Elden Ring, Sekiro), Black Myth: Wukong, GTA V, Red Dead
  Redemption 1, hai game Star Wars Jedi. Lý do: bật nhầm thì app có thể coi một từ đầu câu là tên người nói.
- `speakerAbove`: `true` khi tên nằm ở dòng riêng phía trên câu thoại, không có dấu hai chấm. Thường gặp ở khung hội
  thoại có thẻ tên: FF7 Remake / Rebirth, Metaphor, Like a Dragon, Onimusha. Chỉ đặt khi có ảnh chụp hoặc nguồn
  xác nhận, còn không chắc thì để `false`.
- `speakers`: để `[]` (app tự học), trừ khi chắc chắn danh sách tên người nói.

**Nhóm** (`group`, theo thứ tự này nếu có): `Tên game`, `Nhân vật` (có thể tách `Nhân vật đồng hành`, `Nhân vật khác`),
`Địa danh`, `Phe phái / Tổ chức`, `Kẻ địch / Boss`, `Vật phẩm / Cơ chế`, `Thuật ngữ cốt truyện`, `Tiếng lóng`.

**Dịch hay giữ nguyên**
- Không có `translation` = giữ nguyên tên gốc: tên người, tên riêng địa danh, tên băng nhóm / thương hiệu / vật phẩm
  hiện trong giao diện.
- Có `translation` (tiếng Việt tự nhiên): địa danh có phần mô tả ("Mount Chiliad" → "Núi Chiliad", "Del Perro Pier" →
  "Bến tàu Del Perro"), cơ quan / tổ chức có tên chung ("Federal Investigation Bureau" → "Cục Điều tra Liên bang"),
  thuật ngữ gameplay ("Wanted Level" → "Mức truy nã"), tiếng lóng ("cops" → "cớm"), danh xưng theo phong cách
  (`eastern`: "Lord Shimura" → "lãnh chúa Shimura", "Sensei Ishikawa" → "sư phụ Ishikawa"; `fantasy`: "Sir Wade" →
  "ngài Wade").
- **Bỏ** thuật ngữ một từ trùng với từ tiếng Anh thông dụng mà không phải tên riêng nổi bật (ví dụ "Terminal", "Chef",
  "Harmony", "score", một chữ cái như "T"): giữ nguyên chúng làm câu thoại thường bị để nguyên tiếng Anh. Tên nhân vật
  chính dù là từ thường (V, Chop) vẫn giữ.
- Thêm cả dạng ngắn mà nhân vật hay gọi (tên riêng, họ) như một thuật ngữ riêng. Không lặp thuật ngữ (không phân biệt
  hoa thường). Thuật ngữ không chứa dấu phẩy.

## 4. Kiểm tra

```sh
python3 -I .claude/skills/them-game/scripts/game_json.py fmt glossaries/<id>.json
python3 -I .claude/skills/them-game/scripts/game_json.py check glossaries/<id>.json
```

Sửa hết `lỗi:`; xem lại `cảnh báo:`. Đọc lướt file một lượt: tên viết đúng, phong cách hợp, không có thuật ngữ bịa.

## 5. Nạp lên server

Server: DeployTool project **`Translate-screen-server`** (local `server/` → `/app/translate-screen` trên VPS EbayServer).
Lệnh `subly-server import-games` thêm game mới hoặc thay game cùng `id`; server không cần build lại.

1. Chép file vào thư mục tạm của project (đã nằm trong `server/.gitignore`):
   `mkdir -p server/import-games && cp glossaries/<id>.json server/import-games/`
   (nhiều game thì chép hết vào cùng thư mục, nạp một lần).
2. `mcp__DeployTool__connect_project` → `Translate-screen-server`, rồi `mcp__DeployTool__upload_files` với
   `files: ["import-games/<id>.json"]`.
3. `mcp__DeployTool__run_command`:
   ```sh
   cd /app/translate-screen && docker compose run --rm -v /app/translate-screen/import-games:/seed:ro subly import-games /seed && mv import-games ../translate-screen-backup/import-games-<YYYYMMDD-HHMMSS>
   ```
   Phải in `đã nạp N game`. Thay `<YYYYMMDD-HHMMSS>` bằng thời điểm hiện tại (guard của DeployTool chặn `rm`/`rmdir`,
   nên dọn bằng `mv` sang thư mục backup).
4. Xoá thư mục tạm ở máy: `rm -rf server/import-games`.
5. Xác minh qua domain thật:
   ```sh
   curl -s https://translate.helioapple.com/v1/games | python3 -c "import json,sys; g=[x for x in json.load(sys.stdin)['games'] if x['id']=='<id>']; print(g[0]['name'], g[0]['style'], sum(len(x['entries']) for x in g[0]['glossary']) if g else 'KHÔNG THẤY')"
   ```

Không dùng `sync`/`sync_and_delete` của DeployTool cho việc này (chỉ upload đúng file).

## 6. Commit

`git add glossaries/<id>.json && git commit` (chỉ file game, message kiểu "glossaries: add <Tên game>" kèm dòng
Co-Authored-By). **Push** khi người dùng đã bảo push hoặc bảo "commit push". Không build lại app: bản đóng kèm chỉ là dự
phòng, app lấy danh sách mới từ server.

## 7. Báo lại người dùng

Ngắn gọn: tên game, phong cách đã chọn (và lý do một câu), số thuật ngữ theo nhóm, những gì cố ý bỏ hoặc chưa chắc,
đã nạp lên server (xác minh OK), đã commit. Nhắc: người dùng mở hộp **Thêm game** trong app là thấy game mới; game đã
tạo trước đó không tự đổi thuật ngữ (chỉ phong cách "Tự động" theo game mẫu mới).
