package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// App Subtitle TV (TV Samsung, Tizen) đặt trên server: app Mac / Windows tải về khi bấm "Cài app lên TV", ký bằng
// chứng chỉ của TV đó rồi cài. Cập nhật app TV chỉ cần nạp zip mới (subly-server import-tv), không cần build lại app
// máy tính. File $DATA_DIR/tv/SubtitleTV.zip là zip mã nguồn app chưa ký (config.xml, index.html… nằm ở gốc).

const (
	tvZipName  = "SubtitleTV.zip"
	tvMaxZip   = 20 << 20 // dung lượng tối đa của file zip
	tvMaxFiles = 200
	tvMaxSize  = 50 << 20 // tổng dung lượng sau giải nén
)

type TvApp struct {
	Version string // version trong config.xml
	AppID   string
	Package string
	Files   int
}

// checkTvZip kiểm tra zip app TV: tên file an toàn (không ../, không đường dẫn tuyệt đối, không symlink), có
// config.xml ở gốc với <tizen:application id package>.
func checkTvZip(data []byte) (TvApp, error) {
	var app TvApp
	if len(data) > tvMaxZip {
		return app, fmt.Errorf("zip quá lớn (%d byte, tối đa %d)", len(data), tvMaxZip)
	}
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return app, fmt.Errorf("không đọc được zip: %w", err)
	}
	var total uint64
	var config *zip.File
	for _, f := range zr.File {
		name := f.Name
		if strings.HasSuffix(name, "/") {
			continue // thư mục
		}
		if name == "" || strings.Contains(name, "\\") || strings.HasPrefix(name, "/") ||
			strings.Contains(name, ":") || f.Mode()&os.ModeType != 0 {
			return app, fmt.Errorf("tên file không hợp lệ trong zip: %q", name)
		}
		for _, part := range strings.Split(name, "/") {
			if part == "" || part == "." || part == ".." {
				return app, fmt.Errorf("tên file không hợp lệ trong zip: %q", name)
			}
		}
		app.Files++
		total += f.UncompressedSize64
		if name == "config.xml" {
			config = f
		}
	}
	if app.Files > tvMaxFiles || total > tvMaxSize {
		return app, fmt.Errorf("zip có quá nhiều file / quá lớn (%d file, %d byte)", app.Files, total)
	}
	if config == nil {
		return app, errors.New("zip không có config.xml ở thư mục gốc (nén các file bên trong SubtitleTV/, không nén cả thư mục)")
	}
	rc, err := config.Open()
	if err != nil {
		return app, err
	}
	raw, err := io.ReadAll(io.LimitReader(rc, 1<<20))
	rc.Close()
	if err != nil {
		return app, err
	}
	var w struct {
		Version string `xml:"version,attr"`
		App     struct {
			ID      string `xml:"id,attr"`
			Package string `xml:"package,attr"`
		} `xml:"http://tizen.org/ns/widgets application"`
	}
	if err := xml.Unmarshal(raw, &w); err != nil {
		return app, fmt.Errorf("config.xml lỗi: %w", err)
	}
	if w.App.ID == "" || w.App.Package == "" {
		return app, errors.New("config.xml thiếu <tizen:application id=… package=…>")
	}
	app.Version, app.AppID, app.Package = w.Version, w.App.ID, w.App.Package
	return app, nil
}

// importTvZip thay app TV trên server bằng file zip `src` (bản cũ giữ lại ở SubtitleTV.prev.zip).
func importTvZip(dir, src string) (TvApp, error) {
	data, err := os.ReadFile(src)
	if err != nil {
		return TvApp{}, err
	}
	app, err := checkTvZip(data)
	if err != nil {
		return app, err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return app, err
	}
	tmp := filepath.Join(dir, tvZipName+".tmp")
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return app, err
	}
	dst := filepath.Join(dir, tvZipName)
	if _, err := os.Stat(dst); err == nil {
		_ = os.Rename(dst, filepath.Join(dir, "SubtitleTV.prev.zip"))
	}
	return app, os.Rename(tmp, dst)
}

// GET /v1/tv/app: zip mã nguồn app TV. ETag = SHA-256 của file nên app gửi If-None-Match, không đổi thì 304.
// 404 = server chưa có app TV (app dùng bản đóng kèm).
func (a *App) handleTvApp(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if !a.apiLimit.Allow(a.clientIP(r)) {
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}
	data, err := os.ReadFile(filepath.Join(a.tvDir, tvZipName))
	if errors.Is(err, os.ErrNotExist) {
		http.Error(w, "no tv app", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	sum := sha256.Sum256(data)
	etag := `"` + hex.EncodeToString(sum[:]) + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "no-cache")
	if strings.TrimPrefix(r.Header.Get("If-None-Match"), "W/") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "application/zip")
	if app, err := checkTvZip(data); err == nil {
		w.Header().Set("X-Tv-Version", app.Version)
	}
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write(data)
}
