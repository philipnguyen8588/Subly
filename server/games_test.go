package main

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
)

const sampleGame = `{"id":"gta-5","name":"Grand Theft Auto V","aliases":["GTA V"],"style":"modern",
 "glossary":[{"group":"Nhân vật","entries":[{"term":"Michael"},{"term":"michael"},{"term":""}]},
             {"group":"Tổ chức","entries":[{"term":"FIB","translation":"Cục Điều tra Liên bang"}]},{"group":"Trống","entries":[]}]}`

func TestParseGames(t *testing.T) {
	gs, err := parseGames([]byte(sampleGame))
	if err != nil || len(gs) != 1 {
		t.Fatalf("%v %v", gs, err)
	}
	g := gs[0]
	// Thiếu showsSpeakerNames → mặc định true; thuật ngữ trùng / rỗng và nhóm trống bị bỏ.
	if !g.ShowsSpeakerNames || g.Terms() != 2 || len(g.Glossary) != 2 {
		t.Fatalf("normalize: %+v", g)
	}
	// Mảng game và dạng {"games": [...]} như /v1/games trả về.
	if gs, err := parseGames([]byte("[" + sampleGame + "," + sampleGame + "]")); err != nil || len(gs) != 2 {
		t.Fatalf("array: %v", err)
	}
	if gs, err := parseGames([]byte(`{"version":"x","games":[` + sampleGame + `]}`)); err != nil || len(gs) != 1 {
		t.Fatalf("wrapped: %v", err)
	}
	for _, bad := range []string{`{"name":""}`, `{"name":"X","style":"anime"}`, `{"name":"X","id":"Có Dấu"}`, `not json`} {
		if _, err := parseGames([]byte(bad)); err == nil {
			t.Fatalf("%s accepted", bad)
		}
	}
	if s := slugify("Ghost of Yōtei"); s != "ghost-of-yotei" {
		t.Fatalf("slug %q", s)
	}
	if s := slugify("Marvel's Spider-Man 2"); s != "marvel-s-spider-man-2" {
		t.Fatalf("slug %q", s)
	}
}

func TestGlossaryTextRoundTrip(t *testing.T) {
	gs, _ := parseGames([]byte(sampleGame))
	txt := glossaryText(gs[0].Glossary)
	if !strings.Contains(txt, "# Tổ chức\nFIB,Cục Điều tra Liên bang\n") {
		t.Fatalf("text:\n%s", txt)
	}
	back := parseGlossaryText(txt)
	if len(back) != 2 || back[1].Entries[0].Translation != "Cục Điều tra Liên bang" || back[0].Entries[0].Term != "Michael" {
		t.Fatalf("back %+v", back)
	}
	// Dòng trước nhóm đầu tiên vào nhóm không tên.
	if g := parseGlossaryText("Alpha\n# B\nBeta,β"); len(g) != 2 || g[0].Group != "" || g[1].Entries[0].Translation != "β" {
		t.Fatalf("ungrouped %+v", g)
	}
}

// Mọi file glossaries/*.json đóng kèm app phải nạp được vào server.
func TestImportBundledGlossaries(t *testing.T) {
	if _, err := os.Stat("../glossaries"); err != nil {
		t.Skip("không có thư mục glossaries")
	}
	a := newTestApp(t)
	n, err := importGamesDir(a.store, "../glossaries")
	if err != nil || n < 40 {
		t.Fatalf("import %d: %v", n, err)
	}
	g, _ := a.store.Game("ghost-of-tsushima")
	if g == nil || g.Style != "eastern" || g.Terms() < 50 {
		t.Fatalf("ghost-of-tsushima %+v", g)
	}
}

func TestGamesAPI(t *testing.T) {
	a := newTestApp(t)
	gs, _ := parseGames([]byte(sampleGame))
	_ = a.store.PutGame(gs[0], a.now())
	get := func(etag string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/v1/games", nil)
		if etag != "" {
			req.Header.Set("If-None-Match", etag)
		}
		rec := httptest.NewRecorder()
		a.routes().ServeHTTP(rec, req)
		return rec
	}
	rec := get("")
	var body struct {
		Version string  `json:"version"`
		Games   []*Game `json:"games"`
	}
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &body) != nil || len(body.Games) != 1 || body.Games[0].Style != "modern" {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	etag := rec.Header().Get("ETag")
	if rec := get(etag); rec.Code != http.StatusNotModified {
		t.Fatalf("same etag: %d", rec.Code)
	}
	if rec := get("W/" + etag); rec.Code != http.StatusNotModified {
		t.Fatalf("weak etag: %d", rec.Code)
	}
	// Xoá game → phiên bản đổi.
	_ = a.store.DeleteGame("gta-5")
	if rec := get(etag); rec.Code != 200 || !strings.Contains(rec.Body.String(), `"games":[]`) {
		t.Fatalf("after delete: %d %s", rec.Code, rec.Body)
	}
}

func TestGamesAdmin(t *testing.T) {
	a := newTestApp(t)
	cookie := adminLogin(t, a)
	post := func(form url.Values, c *http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/admin/games", strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("Origin", "http://example.com")
		if c != nil {
			req.AddCookie(c)
		}
		rec := httptest.NewRecorder()
		a.routes().ServeHTTP(rec, req)
		return rec
	}
	form := url.Values{"action": {"save"}, "name": {"Ghost of Yōtei"}, "style": {"eastern"}, "aliases": {"Yotei, GoY"},
		"shows_speaker_names": {"1"}, "glossary": {"# Nhân vật\nAtsu\n# Địa danh\nEzo,Ezo\nMount Yōtei,Núi Yōtei"}}
	post(form, nil)
	if g, _ := a.store.Game("ghost-of-yotei"); g != nil {
		t.Fatal("saved without login")
	}
	if rec := post(form, cookie); rec.Code != http.StatusSeeOther {
		t.Fatalf("save: %d %s", rec.Code, rec.Body)
	}
	g, _ := a.store.Game("ghost-of-yotei")
	if g == nil || g.Style != "eastern" || g.Terms() != 3 || len(g.Aliases) != 2 || !g.ShowsSpeakerNames || g.SpeakerAbove {
		t.Fatalf("saved %+v", g)
	}
	// Thêm trùng id → báo lỗi; sửa (orig_id) → được, id giữ nguyên dù đổi tên.
	if rec := post(form, cookie); !strings.Contains(rec.Body.String(), "Đã có game") {
		t.Fatal("duplicate id accepted")
	}
	form.Set("orig_id", "ghost-of-yotei")
	form.Set("name", "Ghost of Yotei")
	form.Del("shows_speaker_names")
	post(form, cookie)
	if g, _ := a.store.Game("ghost-of-yotei"); g == nil || g.Name != "Ghost of Yotei" || g.ShowsSpeakerNames {
		t.Fatalf("edit %+v", g)
	}

	// Nhập file JSON (multipart).
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	_ = mw.WriteField("action", "import")
	fw, _ := mw.CreateFormFile("files", "gta-5.json")
	fw.Write([]byte(sampleGame))
	mw.Close()
	req := httptest.NewRequest(http.MethodPost, "/admin/games", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Origin", "http://example.com")
	req.AddCookie(cookie)
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, req)
	if !strings.Contains(rec.Body.String(), "Đã nhập 1 game") {
		t.Fatalf("import page: %s", rec.Body)
	}
	if g, _ := a.store.Game("gta-5"); g == nil {
		t.Fatal("import not saved")
	}

	// Trang danh sách, form sửa, xuất JSON.
	for _, path := range []string{"/admin?tab=games", "/admin?tab=games&edit=gta-5", "/admin/games/export?id=gta-5"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.AddCookie(cookie)
		rec := httptest.NewRecorder()
		a.routes().ServeHTTP(rec, req)
		if rec.Code != 200 || !strings.Contains(rec.Body.String(), "FIB") && !strings.Contains(rec.Body.String(), "Ghost of Yotei") {
			t.Fatalf("%s: %d", path, rec.Code)
		}
	}

	post(url.Values{"action": {"delete"}, "id": {"gta-5"}}, cookie)
	if g, _ := a.store.Game("gta-5"); g != nil {
		t.Fatal("delete not applied")
	}
}
