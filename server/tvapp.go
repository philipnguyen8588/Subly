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
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// App Subtitle TV (TV Samsung, Tizen) đặt trên server: app Mac / Windows tải về khi bấm "Cài app lên TV", ký bằng
// chứng chỉ của TV đó rồi cài. Cập nhật app TV chỉ cần nạp zip mới (subly-server import-tv), không cần build lại app
// máy tính. File $DATA_DIR/tv/SubtitleTV.zip là zip mã nguồn app chưa ký (config.xml, index.html… nằm ở gốc).

const (
	tvZipName  = "SubtitleTV.zip"
	tvPrevName = "SubtitleTV.prev.zip" // bản trước, để khôi phục
	tvMaxZip   = 20 << 20              // dung lượng tối đa của file zip
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
	return importTvData(dir, data)
}

func importTvData(dir string, data []byte) (TvApp, error) {
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
		_ = os.Rename(dst, filepath.Join(dir, tvPrevName))
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

// ---------- Trang quản trị: tab App TV ----------

type tvView struct {
	TvApp
	Size    int64
	Updated time.Time
	SHA     string
	Names   []string
}

// tvFile đọc thông tin một file zip app TV; nil nếu chưa có.
func tvFile(path string) *tvView {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	st, _ := os.Stat(path)
	v := &tvView{Size: int64(len(data)), Updated: st.ModTime()}
	sum := sha256.Sum256(data)
	v.SHA = hex.EncodeToString(sum[:])
	v.TvApp, err = checkTvZip(data)
	if err != nil {
		v.Version = "lỗi: " + err.Error()
		return v
	}
	if zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data))); err == nil {
		for _, f := range zr.File {
			if !strings.HasSuffix(f.Name, "/") {
				v.Names = append(v.Names, f.Name)
			}
		}
		sort.Strings(v.Names)
	}
	return v
}

func (a *App) renderTv(w http.ResponseWriter, notice string) {
	counts, _ := a.store.Counts()
	a.render(w, adminPage{LoggedIn: true, Tab: "tv", Counts: counts, Notice: notice,
		TvCur: tvFile(filepath.Join(a.tvDir, tvZipName)), TvPrev: tvFile(filepath.Join(a.tvDir, tvPrevName))})
}

// POST /admin/tv: action=upload (file zip) | restore (đổi chỗ bản hiện tại và bản trước).
func (a *App) handleTvAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !sameOrigin(r) || !a.loggedIn(r) {
		http.Redirect(w, r, "/admin?tab=tv", http.StatusSeeOther)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, tvMaxZip+1<<20)
	if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/") {
		if err := r.ParseMultipartForm(tvMaxZip + 1<<20); err != nil {
			a.renderTv(w, "Lỗi: file quá lớn hoặc hỏng")
			return
		}
	}
	switch r.FormValue("action") {
	case "upload":
		f, _, err := r.FormFile("file")
		if err != nil {
			a.renderTv(w, "Lỗi: chưa chọn file zip")
			return
		}
		data, err := io.ReadAll(f)
		f.Close()
		if err != nil {
			a.renderTv(w, "Lỗi: không đọc được file")
			return
		}
		app, err := importTvData(a.tvDir, data)
		if err != nil {
			a.renderTv(w, "Lỗi: "+err.Error())
			return
		}
		log.Printf("admin tv upload %s version %s", app.AppID, app.Version)
		a.renderTv(w, fmt.Sprintf("Đã nạp app TV version %s (%d file). Các máy bấm “Cài app lên TV” sẽ nhận bản này.", app.Version, app.Files))
	case "restore":
		cur, prev := filepath.Join(a.tvDir, tvZipName), filepath.Join(a.tvDir, tvPrevName)
		if _, err := os.Stat(prev); err != nil {
			a.renderTv(w, "Lỗi: không có bản trước")
			return
		}
		tmp := cur + ".swap"
		if err := os.Rename(cur, tmp); err != nil && !errors.Is(err, os.ErrNotExist) {
			a.renderTv(w, "Lỗi: "+err.Error())
			return
		}
		if err := os.Rename(prev, cur); err != nil {
			_ = os.Rename(tmp, cur)
			a.renderTv(w, "Lỗi: "+err.Error())
			return
		}
		_ = os.Rename(tmp, prev)
		log.Printf("admin tv restore previous")
		a.renderTv(w, "Đã quay lại bản trước (bản vừa thay giờ là “bản trước”).")
	default:
		http.Error(w, "bad request", http.StatusBadRequest)
	}
}

// GET /admin/tv/download[?f=prev]: tải file zip app TV về máy.
func (a *App) handleTvDownload(w http.ResponseWriter, r *http.Request) {
	if !a.loggedIn(r) {
		http.Redirect(w, r, "/admin", http.StatusSeeOther)
		return
	}
	name, out := tvZipName, "SubtitleTV.zip"
	if r.URL.Query().Get("f") == "prev" {
		name = tvPrevName
	}
	data, err := os.ReadFile(filepath.Join(a.tvDir, name))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if v := tvFile(filepath.Join(a.tvDir, name)); v != nil && v.Version != "" && !strings.HasPrefix(v.Version, "lỗi") {
		out = "SubtitleTV-" + v.Version + ".zip"
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="`+out+`"`)
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(data)
}
