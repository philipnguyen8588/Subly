package main

import (
	"archive/zip"
	"bytes"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const tvConfig = `<?xml version="1.0" encoding="UTF-8"?>
<widget xmlns="http://www.w3.org/ns/widgets" xmlns:tizen="http://tizen.org/ns/widgets" id="http://lipnguyen/SubtitleTV" version="1.2.3">
    <tizen:application id="StSubTV001.SubtitleTV" package="StSubTV001" required_version="5.5"/>
    <content src="index.html"/>
</widget>`

func tvZip(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, body := range files {
		f, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		f.Write([]byte(body))
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestCheckTvZip(t *testing.T) {
	app, err := checkTvZip(tvZip(t, map[string]string{"config.xml": tvConfig, "index.html": "<html>", "js/main.js": "x"}))
	if err != nil || app.Version != "1.2.3" || app.AppID != "StSubTV001.SubtitleTV" || app.Package != "StSubTV001" || app.Files != 3 {
		t.Fatalf("%+v %v", app, err)
	}
	bad := []map[string]string{
		{"index.html": "<html>"},                                         // thiếu config.xml
		{"SubtitleTV/config.xml": tvConfig},                              // nén cả thư mục
		{"config.xml": tvConfig, "../evil.js": "x"},                      // thoát ra ngoài
		{"config.xml": tvConfig, "/etc/passwd": "x"},                     // đường dẫn tuyệt đối
		{"config.xml": tvConfig, "a\\b.js": "x"},                         // dấu \ kiểu Windows
		{"config.xml": `<widget xmlns="http://www.w3.org/ns/widgets"/>`}, // thiếu tizen:application
	}
	for _, files := range bad {
		if _, err := checkTvZip(tvZip(t, files)); err == nil {
			t.Fatalf("%v accepted", files)
		}
	}
	if _, err := checkTvZip([]byte("not a zip")); err == nil {
		t.Fatal("garbage accepted")
	}
}

func TestTvAppEndpoint(t *testing.T) {
	a := newTestApp(t)
	get := func(etag string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/v1/tv/app", nil)
		if etag != "" {
			req.Header.Set("If-None-Match", etag)
		}
		rec := httptest.NewRecorder()
		a.routes().ServeHTTP(rec, req)
		return rec
	}
	if rec := get(""); rec.Code != http.StatusNotFound {
		t.Fatalf("no app: %d", rec.Code)
	}

	zipData := tvZip(t, map[string]string{"config.xml": tvConfig, "index.html": "<html>"})
	src := filepath.Join(t.TempDir(), "in.zip")
	os.WriteFile(src, zipData, 0o644)
	if app, err := importTvZip(a.tvDir, src); err != nil || app.Version != "1.2.3" {
		t.Fatalf("import: %+v %v", app, err)
	}
	rec := get("")
	etag := rec.Header().Get("ETag")
	if rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), zipData) || etag == "" || rec.Header().Get("X-Tv-Version") != "1.2.3" {
		t.Fatalf("get: %d %q %q", rec.Code, etag, rec.Header().Get("X-Tv-Version"))
	}
	// Cloudflare đổi ETag sang dạng yếu.
	if rec := get("W/" + etag); rec.Code != http.StatusNotModified {
		t.Fatalf("304: %d", rec.Code)
	}

	// Nạp bản mới: bản cũ giữ ở .prev, ETag đổi. Zip hỏng thì không thay.
	os.WriteFile(src, tvZip(t, map[string]string{"config.xml": tvConfig, "index.html": "<html>v2"}), 0o644)
	if _, err := importTvZip(a.tvDir, src); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(a.tvDir, "SubtitleTV.prev.zip")); err != nil {
		t.Fatal("no prev")
	}
	if rec := get(etag); rec.Code != 200 {
		t.Fatalf("new version: %d", rec.Code)
	}
	os.WriteFile(src, []byte("broken"), 0o644)
	if _, err := importTvZip(a.tvDir, src); err == nil {
		t.Fatal("broken zip imported")
	}
	if rec := get(""); rec.Code != 200 {
		t.Fatalf("after broken import: %d", rec.Code)
	}
}

func TestTvAdmin(t *testing.T) {
	a := newTestApp(t)
	cookie := adminLogin(t, a)
	do := func(req *http.Request) *httptest.ResponseRecorder {
		req.AddCookie(cookie)
		rec := httptest.NewRecorder()
		a.routes().ServeHTTP(rec, req)
		return rec
	}
	page := func() string { return do(httptest.NewRequest(http.MethodGet, "/admin?tab=tv", nil)).Body.String() }
	upload := func(data []byte) string {
		var buf bytes.Buffer
		mw := multipart.NewWriter(&buf)
		_ = mw.WriteField("action", "upload")
		fw, _ := mw.CreateFormFile("file", "SubtitleTV.zip")
		fw.Write(data)
		mw.Close()
		req := httptest.NewRequest(http.MethodPost, "/admin/tv", &buf)
		req.Header.Set("Content-Type", mw.FormDataContentType())
		req.Header.Set("Origin", "http://example.com")
		return do(req).Body.String()
	}
	if !strings.Contains(page(), "Server chưa có app TV") {
		t.Fatal("empty page")
	}
	v1 := tvZip(t, map[string]string{"config.xml": tvConfig, "index.html": "<html>"})
	if body := upload(v1); !strings.Contains(body, "Đã nạp app TV version 1.2.3") || !strings.Contains(body, "index.html") {
		t.Fatalf("upload: %s", body)
	}
	if body := upload([]byte("broken")); !strings.Contains(body, "Lỗi: không đọc được zip") {
		t.Fatalf("broken upload: %s", body)
	}
	v2 := tvZip(t, map[string]string{"config.xml": strings.Replace(tvConfig, "1.2.3", "1.2.4", 1), "index.html": "<html>v2"})
	upload(v2)
	body := page()
	if !strings.Contains(body, "version 1.2.4") || !strings.Contains(body, "Bản trước") || !strings.Contains(body, "version 1.2.3") {
		t.Fatalf("page: %s", body)
	}
	rec := do(httptest.NewRequest(http.MethodGet, "/admin/tv/download", nil))
	if !bytes.Equal(rec.Body.Bytes(), v2) || !strings.Contains(rec.Header().Get("Content-Disposition"), "SubtitleTV-1.2.4.zip") {
		t.Fatalf("download: %q", rec.Header().Get("Content-Disposition"))
	}
	// Khôi phục: bản trước thành bản đang phát, /v1/tv/app phát lại v1.
	req := httptest.NewRequest(http.MethodPost, "/admin/tv", strings.NewReader("action=restore"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Origin", "http://example.com")
	if body := do(req).Body.String(); !strings.Contains(body, "Đã quay lại bản trước") {
		t.Fatalf("restore: %s", body)
	}
	if rec := do(httptest.NewRequest(http.MethodGet, "/v1/tv/app", nil)); !bytes.Equal(rec.Body.Bytes(), v1) {
		t.Fatal("restore did not swap")
	}
	if rec := do(httptest.NewRequest(http.MethodGet, "/admin/tv/download?f=prev", nil)); !bytes.Equal(rec.Body.Bytes(), v2) {
		t.Fatal("prev after restore")
	}
	// Chưa đăng nhập: không tải được, không nạp được.
	anon := httptest.NewRecorder()
	a.routes().ServeHTTP(anon, httptest.NewRequest(http.MethodGet, "/admin/tv/download", nil))
	if anon.Code != http.StatusSeeOther {
		t.Fatalf("anon download: %d", anon.Code)
	}
}
