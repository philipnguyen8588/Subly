// Server duyệt máy cho ScreenTranslator: máy mới tự đăng ký ở trạng thái chờ, chủ app duyệt trên /admin,
// máy đã duyệt nhận vé có chữ ký Ed25519 (hạn mặc định 7 ngày) để app chạy được cả khi tạm mất mạng.
//
//	subly-server keygen   tạo khoá ký (nếu chưa có) và in public key để nhúng vào app
//	subly-server pubkey   in public key
//	subly-server import-games <thư mục>   nạp các file game mẫu *.json (game cùng id thì được thay)
//	subly-server import-tv <file.zip>     thay app Subtitle TV (zip mã nguồn app TV, xem tvapp.go)
//	subly-server          chạy server
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Phiên đăng nhập trang quản trị: lưu trong DB, hạn trượt 1 năm → đăng nhập một lần là đủ.
const sessionTTL = 365 * 24 * time.Hour

type App struct {
	store        *Store
	key          ed25519.PrivateKey
	ticketTTL    time.Duration
	adminPass    string
	trustProxy   bool
	secureCookie bool
	tgToken      string
	tgChat       string
	apiLimit     *RateLimiter
	loginLimit   *RateLimiter
	sessions     *SessionStore
	shares       *ShareStore
	shareLimit   *RateLimiter
	aiClient     *http.Client
	aiBase       map[string]string // chỉ dùng trong test: thay địa chỉ gốc của nhà cung cấp
	accountLimit *RateLimiter      // đăng nhập tài khoản sao lưu, theo IP
	backupDir    string            // $DATA_DIR/backups/<user id>/<máy>.zip
	backupMax    int64             // dung lượng tối đa một bản sao lưu (byte)
	tvDir        string            // $DATA_DIR/tv: app Subtitle TV (SubtitleTV.zip)
	now          func() time.Time
}

func env(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func keyPath(dataDir string) string { return filepath.Join(dataDir, "server.key") }

// loadKey đọc khoá ký (seed 32 byte, base64). create = true thì tạo mới nếu chưa có.
func loadKey(dataDir string, create bool) (ed25519.PrivateKey, error) {
	p := keyPath(dataDir)
	raw, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) && create {
		seed := make([]byte, ed25519.SeedSize)
		if _, err := rand.Read(seed); err != nil {
			return nil, err
		}
		if err := os.MkdirAll(dataDir, 0o700); err != nil {
			return nil, err
		}
		if err := os.WriteFile(p, []byte(base64.StdEncoding.EncodeToString(seed)+"\n"), 0o600); err != nil {
			return nil, err
		}
		return ed25519.NewKeyFromSeed(seed), nil
	}
	if err != nil {
		return nil, fmt.Errorf("chưa có khoá ký %s (chạy: subly-server keygen): %w", p, err)
	}
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("khoá ký %s hỏng", p)
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	dataDir := env("DATA_DIR", "/data")

	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "keygen", "pubkey":
			key, err := loadKey(dataDir, os.Args[1] == "keygen")
			if err != nil {
				log.Fatal(err)
			}
			fmt.Println(base64.RawURLEncoding.EncodeToString(key.Public().(ed25519.PublicKey)))
			return
		case "import-games":
			if len(os.Args) < 3 {
				log.Fatal("dùng: subly-server import-games <thư mục chứa *.json>")
			}
			st, err := openStore(filepath.Join(dataDir, "devices.db"))
			if err != nil {
				log.Fatal(err)
			}
			n, err := importGamesDir(st, os.Args[2])
			if err != nil {
				log.Fatalf("đã nạp %d game, lỗi: %v", n, err)
			}
			fmt.Printf("đã nạp %d game\n", n)
			return
		case "import-tv":
			if len(os.Args) < 3 {
				log.Fatal("dùng: subly-server import-tv <SubtitleTV.zip>")
			}
			app, err := importTvZip(filepath.Join(dataDir, "tv"), os.Args[2])
			if err != nil {
				log.Fatalf("không nạp được app TV: %v", err)
			}
			fmt.Printf("đã nạp app TV %s (version %s, %d file)\n", app.AppID, app.Version, app.Files)
			return
		default:
			log.Fatalf("lệnh không rõ: %s (dùng: keygen | pubkey | import-games | import-tv)", os.Args[1])
		}
	}

	key, err := loadKey(dataDir, false)
	if err != nil {
		log.Fatal(err)
	}
	pass := os.Getenv("ADMIN_PASSWORD")
	if len(pass) < 12 {
		log.Fatal("ADMIN_PASSWORD phải dài ít nhất 12 ký tự")
	}
	store, err := openStore(filepath.Join(dataDir, "devices.db"))
	if err != nil {
		log.Fatal(err)
	}
	maxMB, _ := strconv.Atoi(env("BACKUP_MAX_MB", "90"))
	if maxMB < 1 {
		maxMB = 90
	}
	days, _ := strconv.Atoi(env("TICKET_DAYS", "7"))
	if days < 1 {
		days = 7
	}
	a := &App{
		store: store, key: key, ticketTTL: time.Duration(days) * 24 * time.Hour, adminPass: pass,
		trustProxy: env("TRUST_PROXY", "1") == "1", secureCookie: env("INSECURE_COOKIE", "0") != "1",
		tgToken: os.Getenv("TELEGRAM_TOKEN"), tgChat: os.Getenv("TELEGRAM_CHAT_ID"),
		apiLimit:     NewRateLimiter(30, time.Minute),
		loginLimit:   NewRateLimiter(10, 15*time.Minute),
		sessions:     store.Sessions(sessionTTL),
		shares:       store.Shares(shareCipher(key)),
		shareLimit:   NewRateLimiter(120, time.Minute),
		aiClient:     newAIClient(),
		now:          time.Now,
		accountLimit: NewRateLimiter(20, 15*time.Minute),
		backupDir:    filepath.Join(dataDir, "backups"),
		backupMax:    int64(maxMB) << 20,
		tvDir:        filepath.Join(dataDir, "tv"),
	}
	addr := env("LISTEN", ":8080")
	srv := &http.Server{
		Addr: addr, Handler: a.routes(),
		ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 20 * time.Second, WriteTimeout: 20 * time.Second,
	}
	log.Printf("listening on %s, ticket %d days, public key %s", addr, days,
		base64.RawURLEncoding.EncodeToString(key.Public().(ed25519.PublicKey)))
	log.Fatal(srv.ListenAndServe())
}

func (a *App) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/session", a.handleSession)
	mux.HandleFunc("/admin", a.handleAdmin)
	mux.HandleFunc("/admin/login", a.handleLogin)
	mux.HandleFunc("/admin/logout", a.handleLogout)
	mux.HandleFunc("/admin/device", a.handleDeviceAction)
	mux.HandleFunc("/admin/share", a.handleShareAction)
	mux.HandleFunc("/admin/app.js", serveAdminJS)
	mux.HandleFunc("/admin/games", a.handleGameAction)
	mux.HandleFunc("/admin/games/export", a.handleGameExport)
	mux.HandleFunc("/v1/games", a.handleGames)
	mux.HandleFunc("/v1/tv/app", a.handleTvApp)
	mux.HandleFunc("/v1/share/info", a.handleShareInfo)
	mux.HandleFunc("/v1/ai/", a.handleAIProxy)
	mux.HandleFunc("POST /v1/account/login", a.handleAccountLogin)
	mux.HandleFunc("POST /v1/account/logout", a.handleAccountLogout)
	mux.HandleFunc("GET /v1/backups", a.handleBackupList)
	mux.HandleFunc("PUT /v1/backups/{machine}", a.handleBackupPut)
	mux.HandleFunc("GET /v1/backups/{machine}", a.handleBackupGet)
	mux.HandleFunc("DELETE /v1/backups/{machine}", a.handleBackupDelete)
	mux.HandleFunc("/admin/accounts", a.handleAccountAction)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	return securityHeaders(mux)
}

func securityHeaders(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "same-origin")
		h.ServeHTTP(w, r)
	})
}

// clientIP: sau Cloudflare thì lấy CF-Connecting-IP (IP thật của máy), sau proxy khác thì X-Forwarded-For,
// không thì lấy địa chỉ kết nối. Chỉ tin các header này khi server không mở cổng trực tiếp ra Internet (TRUST_PROXY=1).
func (a *App) clientIP(r *http.Request) string {
	if a.trustProxy {
		if cf := strings.TrimSpace(r.Header.Get("CF-Connecting-IP")); cf != "" {
			return cf
		}
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
