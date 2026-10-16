package main

// AI share: chủ app nhập API key trên trang quản trị, mỗi mục sinh một token. App của người được share gửi token đó
// thay cho key; server kiểm tra model có nằm trong danh sách được share, tự gắn key thật rồi chuyển request tới nhà
// cung cấp. Key không bao giờ rời server, nên người được share không lấy được key.

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	shareActive  = "active"
	shareRevoked = "revoked"
	tokenPrefix  = "sts_"
	maxShareBody = 2 << 20
	maxModels    = 40
)

// Nhà cung cấp được hỗ trợ: địa chỉ gốc (custom lấy theo từng share) và đường dẫn duy nhất được phép gọi qua proxy.
var providers = map[string]struct{ base, path string }{
	"openai":    {"https://api.openai.com/v1", "chat/completions"},
	"anthropic": {"https://api.anthropic.com/v1", "messages"},
	"gemini":    {"https://generativelanguage.googleapis.com/v1beta", "interactions"},
	"custom":    {"", "chat/completions"},
}

var providerNames = map[string]string{"openai": "OpenAI", "anthropic": "Anthropic", "gemini": "Gemini", "custom": "Custom"}

type Share struct {
	ID       string
	Label    string
	Provider string
	BaseURL  string
	Models   []string
	Key      string // đã giải mã
	Token    string // đã giải mã
	Status   string
	Created  time.Time
	LastUsed time.Time
	Uses     int
}

func (s *Share) allows(model string) bool { return slices.Contains(s.Models, model) }

// ShareStore lưu share trong SQLite; key và token được mã hoá AES-GCM, token còn lưu SHA-256 để tra cứu.
type ShareStore struct {
	db   *sql.DB
	aead cipher.AEAD

	mu      sync.Mutex
	pending map[string]int       // số lần dùng chưa ghi xuống DB
	flushed map[string]time.Time // lần ghi gần nhất
}

// shareCipher: khoá mã hoá suy ra từ khoá ký của server, nên chỉ cần sao lưu data/ như cũ.
func shareCipher(key ed25519.PrivateKey) cipher.AEAD {
	k := sha256.Sum256(append(key.Seed(), []byte("ai-share-v1")...))
	block, err := aes.NewCipher(k[:])
	if err != nil {
		panic(err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		panic(err)
	}
	return aead
}

func (s *Store) Shares(aead cipher.AEAD) *ShareStore {
	return &ShareStore{db: s.db, aead: aead, pending: map[string]int{}, flushed: map[string]time.Time{}}
}

func (s *ShareStore) seal(plain string) string {
	nonce := make([]byte, s.aead.NonceSize())
	_, _ = rand.Read(nonce)
	return b64.EncodeToString(s.aead.Seal(nonce, nonce, []byte(plain), nil))
}

func (s *ShareStore) open(enc string) (string, error) {
	raw, err := b64.DecodeString(enc)
	n := s.aead.NonceSize()
	if err != nil || len(raw) < n {
		return "", errors.New("bad ciphertext")
	}
	out, err := s.aead.Open(nil, raw[:n], raw[n:], nil)
	return string(out), err
}

func tokenHash(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

func randomID(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return b64.EncodeToString(b)
}

const shareCols = `id, label, provider, base_url, models, key_enc, token_enc, status, created, last_used, uses`

func (s *ShareStore) scan(sc interface{ Scan(...any) error }) (*Share, error) {
	var sh Share
	var models, keyEnc, tokEnc string
	var created, used int64
	if err := sc.Scan(&sh.ID, &sh.Label, &sh.Provider, &sh.BaseURL, &models, &keyEnc, &tokEnc, &sh.Status,
		&created, &used, &sh.Uses); err != nil {
		return nil, err
	}
	_ = json.Unmarshal([]byte(models), &sh.Models)
	var err error
	if sh.Key, err = s.open(keyEnc); err != nil {
		return nil, fmt.Errorf("share %s: key: %w", sh.ID, err)
	}
	if sh.Token, err = s.open(tokEnc); err != nil {
		return nil, fmt.Errorf("share %s: token: %w", sh.ID, err)
	}
	sh.Created = time.Unix(created, 0)
	if used > 0 {
		sh.LastUsed = time.Unix(used, 0)
	}
	return &sh, nil
}

func (s *ShareStore) one(where string, arg any) (*Share, error) {
	sh, err := s.scan(s.db.QueryRow(`SELECT `+shareCols+` FROM shares WHERE `+where, arg))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return sh, err
}

func (s *ShareStore) Get(id string) (*Share, error) { return s.one("id = ?", id) }

func (s *ShareStore) ByToken(token string) (*Share, error) {
	if !strings.HasPrefix(token, tokenPrefix) || len(token) > 100 {
		return nil, nil
	}
	return s.one("token_hash = ?", tokenHash(token))
}

func (s *ShareStore) List() ([]*Share, error) {
	rows, err := s.db.Query(`SELECT ` + shareCols + ` FROM shares ORDER BY status = 'active' DESC, created DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Share
	for rows.Next() {
		sh, err := s.scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, sh)
	}
	return out, rows.Err()
}

func newToken() string { return tokenPrefix + randomID(32) }

// Insert tạo share mới (sinh id và token).
func (s *ShareStore) Insert(sh *Share, now time.Time) error {
	sh.ID, sh.Token, sh.Status, sh.Created = randomID(9), newToken(), shareActive, now
	models, _ := json.Marshal(sh.Models)
	_, err := s.db.Exec(`INSERT INTO shares(`+shareCols+`, token_hash) VALUES(?,?,?,?,?,?,?,?,?,0,0,?)`,
		sh.ID, sh.Label, sh.Provider, sh.BaseURL, string(models), s.seal(sh.Key), s.seal(sh.Token), sh.Status,
		now.Unix(), tokenHash(sh.Token))
	return err
}

// Update ghi tên, nhà cung cấp, địa chỉ, model và key; token giữ nguyên.
func (s *ShareStore) Update(sh *Share) error {
	models, _ := json.Marshal(sh.Models)
	_, err := s.db.Exec(`UPDATE shares SET label=?, provider=?, base_url=?, models=?, key_enc=? WHERE id=?`,
		sh.Label, sh.Provider, sh.BaseURL, string(models), s.seal(sh.Key), sh.ID)
	return err
}

// Rotate thay token: token cũ hết hiệu lực ngay.
func (s *ShareStore) Rotate(id string) error {
	t := newToken()
	_, err := s.db.Exec(`UPDATE shares SET token_enc=?, token_hash=? WHERE id=?`, s.seal(t), tokenHash(t), id)
	return err
}

func (s *ShareStore) SetStatus(id, status string) error {
	_, err := s.db.Exec(`UPDATE shares SET status=? WHERE id=?`, status, id)
	return err
}

func (s *ShareStore) Delete(id string) error {
	_, err := s.db.Exec(`DELETE FROM shares WHERE id=?`, id)
	return err
}

// Touch đếm một lần dùng; chỉ ghi DB tối đa mỗi phút một lần cho mỗi share.
func (s *ShareStore) Touch(id string, now time.Time) {
	s.mu.Lock()
	s.pending[id]++
	if now.Sub(s.flushed[id]) < time.Minute {
		s.mu.Unlock()
		return
	}
	n := s.pending[id]
	delete(s.pending, id)
	s.flushed[id] = now
	s.mu.Unlock()
	s.db.Exec(`UPDATE shares SET uses = uses + ?, last_used = ? WHERE id = ?`, n, now.Unix(), id)
}

// --- API cho app ---

// shareToken lấy token từ đúng header mà từng backend của app gửi kèm key.
func shareToken(r *http.Request) string {
	if t, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer "); ok {
		return strings.TrimSpace(t)
	}
	if t := r.Header.Get("x-api-key"); t != "" {
		return strings.TrimSpace(t)
	}
	return strings.TrimSpace(r.Header.Get("x-goog-api-key"))
}

// aiError trả lỗi theo dạng {"error":{"message":…}} mà cả ba backend của app đều đọc được.
func aiError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"message": msg}})
}

const msgBadShare = "AI share không hợp lệ hoặc đã bị thu hồi"

// activeShare: share ứng với token trong request, nil (đã trả lỗi) nếu không dùng được.
func (a *App) activeShare(w http.ResponseWriter, r *http.Request) *Share {
	sh, err := a.shares.ByToken(shareToken(r))
	if err != nil {
		log.Printf("share lookup: %v", err)
		aiError(w, http.StatusInternalServerError, "server error")
		return nil
	}
	if sh == nil || sh.Status != shareActive {
		aiError(w, http.StatusForbidden, msgBadShare)
		return nil
	}
	return sh
}

type shareInfo struct {
	Label    string   `json:"label"`
	Provider string   `json:"provider"`
	Models   []string `json:"models"`
}

// handleShareInfo: GET /v1/share/info → tên, nhà cung cấp và các model được dùng của token.
func (a *App) handleShareInfo(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if !a.apiLimit.Allow(a.clientIP(r)) {
		aiError(w, http.StatusTooManyRequests, "too many requests")
		return
	}
	if sh := a.activeShare(w, r); sh != nil {
		writeJSON(w, shareInfo{Label: sh.Label, Provider: sh.Provider, Models: sh.Models})
	}
}

// handleAIProxy: POST /v1/ai/{provider}/{path} → kiểm tra token và model, gắn key thật, chuyển tới nhà cung cấp.
func (a *App) handleAIProxy(w http.ResponseWriter, r *http.Request) {
	provider, path, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/v1/ai/"), "/")
	p, ok := providers[provider]
	if !ok || r.Method != http.MethodPost || path != p.path {
		aiError(w, http.StatusNotFound, "not found")
		return
	}
	sh := a.activeShare(w, r)
	if sh == nil {
		return
	}
	if sh.Provider != provider {
		aiError(w, http.StatusForbidden, "AI share này dùng "+providerNames[sh.Provider])
		return
	}
	if !a.shareLimit.Allow(sh.ID) {
		aiError(w, http.StatusTooManyRequests, "AI share: quá nhiều request, thử lại sau một phút")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxShareBody))
	if err != nil {
		aiError(w, http.StatusRequestEntityTooLarge, "request quá lớn")
		return
	}
	var m struct {
		Model string `json:"model"`
	}
	if err := json.Unmarshal(body, &m); err != nil {
		aiError(w, http.StatusBadRequest, "bad json")
		return
	}
	if !sh.allows(m.Model) {
		aiError(w, http.StatusForbidden, fmt.Sprintf("Model %q không nằm trong AI share (được dùng: %s)", m.Model, strings.Join(sh.Models, ", ")))
		return
	}

	// Request AI có thể lâu hơn WriteTimeout chung của server.
	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(a.now().Add(150 * time.Second))

	ctx, cancel := context.WithTimeout(r.Context(), 140*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.upstreamBase(sh)+"/"+path, bytes.NewReader(body))
	if err != nil {
		aiError(w, http.StatusBadGateway, "địa chỉ API không hợp lệ")
		return
	}
	req.Header.Set("Content-Type", "application/json")
	for _, h := range []string{"anthropic-version", "anthropic-beta"} {
		if v := r.Header.Get(h); v != "" {
			req.Header.Set(h, v)
		}
	}
	setProviderAuth(req, sh.Provider, sh.Key)
	resp, err := a.aiClient.Do(req)
	if err != nil {
		log.Printf("share %s (%s): upstream: %v", sh.ID, sh.Label, err)
		aiError(w, http.StatusBadGateway, "AI share: không gọi được "+providerNames[sh.Provider])
		return
	}
	defer resp.Body.Close()
	a.shares.Touch(sh.ID, a.now())
	// Key hỏng / hết hạn: không chuyển lời báo của nhà cung cấp (có thể chứa một phần key).
	if resp.StatusCode == http.StatusUnauthorized {
		log.Printf("share %s (%s): upstream 401", sh.ID, sh.Label)
		aiError(w, http.StatusBadGateway, "Key của AI share không còn dùng được, hãy báo người share")
		return
	}
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if sh.Key != "" {
		out = bytes.ReplaceAll(out, []byte(sh.Key), []byte("***"))
	}
	w.Header().Set("Content-Type", resp.Header.Get("Content-Type"))
	w.Header().Set("Cache-Control", "no-store")
	if v := resp.Header.Get("Retry-After"); v != "" {
		w.Header().Set("Retry-After", v)
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(out)
}

func (a *App) upstreamBase(sh *Share) string {
	if sh.Provider == "custom" {
		return sh.BaseURL
	}
	if b, ok := a.aiBase[sh.Provider]; ok {
		return b
	}
	return providers[sh.Provider].base
}

func setProviderAuth(req *http.Request, provider, key string) {
	switch provider {
	case "anthropic":
		req.Header.Set("x-api-key", key)
		if req.Header.Get("anthropic-version") == "" {
			req.Header.Set("anthropic-version", "2023-06-01")
		}
	case "gemini":
		req.Header.Set("x-goog-api-key", key)
	default:
		if key != "" {
			req.Header.Set("Authorization", "Bearer "+key)
		}
	}
}

// --- Gọi nhà cung cấp ---

// newAIClient: HTTP client gọi nhà cung cấp, không cho kết nối tới địa chỉ nội bộ (địa chỉ custom do admin nhập,
// nhưng VPS còn chạy các dịch vụ khác).
func newAIClient() *http.Client {
	d := &net.Dialer{Timeout: 10 * time.Second, Control: func(_, address string, _ syscall.RawConn) error {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return err
		}
		ip := net.ParseIP(host)
		if ip == nil || !publicIP(ip) {
			return fmt.Errorf("địa chỉ %s không được phép", host)
		}
		return nil
	}}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = d.DialContext
	tr.Proxy = nil
	return &http.Client{Transport: tr, Timeout: 140 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

func publicIP(ip net.IP) bool {
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() || ip.IsMulticast() || ip.IsInterfaceLocalMulticast() {
		return false
	}
	_, cgnat, _ := net.ParseCIDR("100.64.0.0/10")
	return !cgnat.Contains(ip)
}

// normalizeBaseURL: địa chỉ API tuỳ chỉnh phải là https, bỏ "/" cuối.
func normalizeBaseURL(s string) (string, error) {
	s = strings.TrimRight(strings.TrimSpace(s), "/")
	u, err := url.Parse(s)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("địa chỉ API phải dạng https://…")
	}
	return s, nil
}

// fetchModels lấy danh sách model mà key dùng được, lọc giống app (bỏ model âm thanh, ảnh, embedding…).
func (a *App) fetchModels(ctx context.Context, sh *Share) ([]string, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	u := a.upstreamBase(sh) + "/models"
	switch sh.Provider {
	case "anthropic":
		u += "?limit=100"
	case "gemini":
		u += "?pageSize=200"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	setProviderAuth(req, sh.Provider, sh.Key)
	resp, err := a.aiClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var obj struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
		Models []struct {
			Name    string   `json:"name"`
			Methods []string `json:"supportedGenerationMethods"`
		} `json:"models"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&obj)
	if resp.StatusCode/100 != 2 {
		msg := obj.Error.Message
		if msg == "" || sh.Key != "" && strings.Contains(msg, sh.Key) {
			msg = resp.Status
		}
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, msg)
	}
	var ids []string
	if sh.Provider == "gemini" {
		for _, m := range obj.Models {
			id := m.Name[strings.LastIndex(m.Name, "/")+1:]
			if !slices.Contains(m.Methods, "generateContent") || containsAny(id, "tts", "image", "embedding", "live", "omni") {
				continue
			}
			ids = append(ids, id)
		}
	} else {
		for _, m := range obj.Data {
			if sh.Provider == "openai" && !openAIChatModel(m.ID) {
				continue
			}
			ids = append(ids, m.ID)
		}
	}
	sort.Strings(ids)
	return ids, nil
}

func openAIChatModel(id string) bool {
	if !(strings.HasPrefix(id, "gpt-") || len(id) > 1 && id[0] == 'o' && id[1] >= '0' && id[1] <= '9') {
		return false
	}
	if containsAny(id, "audio", "tts", "transcribe", "realtime", "image", "search", "codex", "embedding", "moderation", "research") {
		return false
	}
	// Bỏ bản chụp theo ngày (gpt-4o-2024-08-06).
	return !datedModel.MatchString(id)
}

var datedModel = regexp.MustCompile(`-\d{4}-\d{2}-\d{2}$`)

func containsAny(s string, subs ...string) bool {
	for _, x := range subs {
		if strings.Contains(s, x) {
			return true
		}
	}
	return false
}

// parseModels gộp model được tick và model gõ thêm (cách nhau dấu phẩy, khoảng trắng hoặc xuống dòng).
func parseModels(checked []string, extra string) []string {
	var out []string
	add := func(m string) {
		m = clip(m, 100)
		if m != "" && !slices.Contains(out, m) {
			out = append(out, m)
		}
	}
	for _, m := range checked {
		add(m)
	}
	for _, m := range strings.FieldsFunc(extra, func(r rune) bool { return r == ',' || r == ' ' || r == '\n' || r == '\r' || r == '\t' }) {
		add(m)
	}
	return out
}

func maskKey(k string) string {
	if len(k) <= 12 {
		return strings.Repeat("•", len(k))
	}
	return k[:6] + "…" + k[len(k)-4:]
}
