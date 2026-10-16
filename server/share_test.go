package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

const realKey = "sk-real-secret-key-1234567890"

// fakeProvider giả làm OpenAI / Anthropic / Gemini: ghi lại request cuối và trả lời theo model.
type fakeProvider struct {
	srv     *httptest.Server
	lastReq *http.Request
	body    string
}

func newFakeProvider(t *testing.T) *fakeProvider {
	f := &fakeProvider{}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		f.lastReq, f.body = r, string(b)
		switch {
		case strings.HasSuffix(r.URL.Path, "/models"):
			w.Write([]byte(`{"data":[{"id":"gpt-5.4-mini"},{"id":"gpt-5.4"},{"id":"gpt-4o-2024-08-06"},{"id":"text-embedding-3-small"}]}`))
		case strings.Contains(f.body, "echo-key"):
			w.Write([]byte(`{"error":{"message":"bad key ` + realKey + `"}}`))
		case strings.Contains(f.body, "unauthorized"):
			w.WriteHeader(http.StatusUnauthorized)
			w.Write([]byte(`{"error":{"message":"Incorrect API key provided: sk-rea...7890"}}`))
		default:
			w.Write([]byte(`{"ok":true}`))
		}
	}))
	t.Cleanup(f.srv.Close)
	return f
}

// shareApp: app test với nhà cung cấp giả (địa chỉ loopback nên dùng client thường, không chặn IP nội bộ).
func shareApp(t *testing.T) (*App, *fakeProvider) {
	a := newTestApp(t)
	f := newFakeProvider(t)
	a.aiClient = &http.Client{Timeout: 5 * time.Second}
	a.aiBase = map[string]string{"openai": f.srv.URL, "anthropic": f.srv.URL, "gemini": f.srv.URL}
	return a, f
}

func addShare(t *testing.T, a *App, provider string, models ...string) *Share {
	t.Helper()
	sh := &Share{Label: "cho Minh", Provider: provider, Key: realKey, Models: models}
	if err := a.shares.Insert(sh, time.Now()); err != nil {
		t.Fatal(err)
	}
	return sh
}

func aiCall(t *testing.T, a *App, path, header, token, body string) *httptest.ResponseRecorder {
	t.Helper()
	method := http.MethodPost
	if body == "" {
		method = http.MethodGet
	}
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	switch header {
	case "bearer":
		req.Header.Set("Authorization", "Bearer "+token)
	default:
		req.Header.Set(header, token)
	}
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, req)
	if strings.Contains(rec.Body.String(), realKey) {
		t.Fatalf("%s: response leaks key: %s", path, rec.Body)
	}
	return rec
}

func TestShareProxy(t *testing.T) {
	a, f := shareApp(t)
	sh := addShare(t, a, "openai", "gpt-5.4-mini", "gpt-5.4")

	// Thông tin share.
	rec := aiCall(t, a, "/v1/share/info", "bearer", sh.Token, "")
	var info shareInfo
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &info) != nil || info.Provider != "openai" || len(info.Models) != 2 {
		t.Fatalf("info %d %s", rec.Code, rec.Body)
	}

	// Model được share → tới nhà cung cấp với key thật.
	rec = aiCall(t, a, "/v1/ai/openai/chat/completions", "bearer", sh.Token, `{"model":"gpt-5.4-mini","messages":[]}`)
	if rec.Code != 200 || rec.Body.String() != `{"ok":true}` {
		t.Fatalf("allowed model: %d %s", rec.Code, rec.Body)
	}
	if got := f.lastReq.Header.Get("Authorization"); got != "Bearer "+realKey {
		t.Fatalf("upstream auth %q", got)
	}
	if f.lastReq.URL.Path != "/chat/completions" {
		t.Fatalf("upstream path %q", f.lastReq.URL.Path)
	}

	// Model ngoài danh sách, sai nhà cung cấp, sai đường dẫn, sai token.
	f.lastReq = nil
	if rec := aiCall(t, a, "/v1/ai/openai/chat/completions", "bearer", sh.Token, `{"model":"gpt-5.4-pro"}`); rec.Code != 403 {
		t.Fatalf("other model: %d", rec.Code)
	}
	if rec := aiCall(t, a, "/v1/ai/anthropic/messages", "x-api-key", sh.Token, `{"model":"gpt-5.4"}`); rec.Code != 403 {
		t.Fatalf("wrong provider: %d", rec.Code)
	}
	if rec := aiCall(t, a, "/v1/ai/openai/embeddings", "bearer", sh.Token, `{"model":"gpt-5.4"}`); rec.Code != 404 {
		t.Fatalf("other path: %d", rec.Code)
	}
	if rec := aiCall(t, a, "/v1/ai/openai/chat/completions", "bearer", "sts_nope", `{"model":"gpt-5.4"}`); rec.Code != 403 {
		t.Fatalf("bad token: %d", rec.Code)
	}
	if rec := aiCall(t, a, "/v1/ai/openai/chat/completions", "bearer", realKey, `{"model":"gpt-5.4"}`); rec.Code != 403 {
		t.Fatalf("raw key as token: %d", rec.Code)
	}
	if f.lastReq != nil {
		t.Fatal("rejected request reached upstream")
	}

	// Nhà cung cấp nhắc lại key trong lời báo → bị che; key hỏng (401) → lời báo chung.
	aiCall(t, a, "/v1/ai/openai/chat/completions", "bearer", sh.Token, `{"model":"gpt-5.4","x":"echo-key"}`)
	if rec := aiCall(t, a, "/v1/ai/openai/chat/completions", "bearer", sh.Token, `{"model":"gpt-5.4","x":"unauthorized"}`); rec.Code != 502 || strings.Contains(rec.Body.String(), "sk-rea") {
		t.Fatalf("upstream 401: %d %s", rec.Code, rec.Body)
	}

	// Thu hồi → hết dùng được; bật lại → dùng được.
	_ = a.shares.SetStatus(sh.ID, shareRevoked)
	if rec := aiCall(t, a, "/v1/ai/openai/chat/completions", "bearer", sh.Token, `{"model":"gpt-5.4"}`); rec.Code != 403 {
		t.Fatalf("revoked: %d", rec.Code)
	}
	if rec := aiCall(t, a, "/v1/share/info", "bearer", sh.Token, ""); rec.Code != 403 || !strings.Contains(rec.Body.String(), "thu hồi") {
		t.Fatalf("revoked info: %d %s", rec.Code, rec.Body)
	}
	_ = a.shares.SetStatus(sh.ID, shareActive)

	// Token mới → token cũ hết hiệu lực.
	_ = a.shares.Rotate(sh.ID)
	if rec := aiCall(t, a, "/v1/ai/openai/chat/completions", "bearer", sh.Token, `{"model":"gpt-5.4"}`); rec.Code != 403 {
		t.Fatalf("old token after rotate: %d", rec.Code)
	}
	fresh, _ := a.shares.Get(sh.ID)
	if fresh.Token == sh.Token {
		t.Fatal("token unchanged")
	}
	if rec := aiCall(t, a, "/v1/ai/openai/chat/completions", "bearer", fresh.Token, `{"model":"gpt-5.4"}`); rec.Code != 200 {
		t.Fatalf("new token: %d", rec.Code)
	}
}

// Mỗi backend của app gửi key ở header riêng; server nhận token ở cả ba và gắn key thật đúng kiểu nhà cung cấp.
func TestShareHeaders(t *testing.T) {
	a, f := shareApp(t)
	an := addShare(t, a, "anthropic", "claude-haiku-5-5")
	rec := aiCall(t, a, "/v1/ai/anthropic/messages", "x-api-key", an.Token, `{"model":"claude-haiku-5-5"}`)
	if rec.Code != 200 || f.lastReq.Header.Get("x-api-key") != realKey || f.lastReq.Header.Get("anthropic-version") == "" {
		t.Fatalf("anthropic: %d %v", rec.Code, f.lastReq.Header)
	}
	g := addShare(t, a, "gemini", "gemini-3.5-flash")
	rec = aiCall(t, a, "/v1/ai/gemini/interactions", "x-goog-api-key", g.Token, `{"model":"gemini-3.5-flash"}`)
	if rec.Code != 200 || f.lastReq.Header.Get("x-goog-api-key") != realKey || f.lastReq.URL.Path != "/interactions" {
		t.Fatalf("gemini: %d %v", rec.Code, f.lastReq.Header)
	}
}

func TestShareEncryptedAtRest(t *testing.T) {
	a, _ := shareApp(t)
	sh := addShare(t, a, "openai", "gpt-5.4")
	var keyEnc, tokEnc, hash string
	if err := a.store.db.QueryRow(`SELECT key_enc, token_enc, token_hash FROM shares WHERE id=?`, sh.ID).Scan(&keyEnc, &tokEnc, &hash); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(keyEnc, "real-secret") || strings.Contains(tokEnc, sh.Token[4:]) || hash == sh.Token {
		t.Fatal("secrets stored in clear")
	}
	got, _ := a.shares.Get(sh.ID)
	if got.Key != realKey || got.Token != sh.Token {
		t.Fatal("decrypt mismatch")
	}
}

func TestShareSSRF(t *testing.T) {
	for _, u := range []string{"http://api.example.com/v1", "ftp://x", "https://", "https://u:p@x.com", "not a url"} {
		if _, err := normalizeBaseURL(u); err == nil {
			t.Fatalf("%q accepted", u)
		}
	}
	if u, err := normalizeBaseURL(" https://openrouter.ai/api/v1/ "); err != nil || u != "https://openrouter.ai/api/v1" {
		t.Fatalf("normalize %q %v", u, err)
	}
	// Share custom trỏ vào địa chỉ nội bộ: client thật không chịu kết nối.
	a := newTestApp(t)
	inner := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("internal address reached") }))
	defer inner.Close()
	sh := &Share{Label: "x", Provider: "custom", BaseURL: inner.URL, Key: realKey, Models: []string{"m"}}
	_ = a.shares.Insert(sh, time.Now())
	if rec := aiCall(t, a, "/v1/ai/custom/chat/completions", "bearer", sh.Token, `{"model":"m"}`); rec.Code != 502 {
		t.Fatalf("internal custom URL: %d %s", rec.Code, rec.Body)
	}
}

func TestOpenAIModelFilter(t *testing.T) {
	for id, want := range map[string]bool{"gpt-5.4-mini": true, "o4-mini": true, "gpt-4o-2024-08-06": false,
		"gpt-4o-audio-preview": false, "text-embedding-3-small": false, "omni-moderation": false} {
		if openAIChatModel(id) != want {
			t.Errorf("%s: want %v", id, want)
		}
	}
}

func adminLogin(t *testing.T, a *App) *http.Cookie {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/admin/login", strings.NewReader(url.Values{"password": {a.adminPass}}.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Origin", "http://example.com")
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, req)
	cs := rec.Result().Cookies()
	if len(cs) != 1 {
		t.Fatal("login failed")
	}
	return cs[0]
}

func TestShareAdmin(t *testing.T) {
	a, _ := shareApp(t)
	cookie := adminLogin(t, a)
	post := func(form url.Values, origin string, c *http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/admin/share", strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("Origin", origin)
		if c != nil {
			req.AddCookie(c)
		}
		rec := httptest.NewRecorder()
		a.routes().ServeHTTP(rec, req)
		return rec
	}
	count := func() int { l, _ := a.shares.List(); return len(l) }

	create := url.Values{"action": {"save"}, "provider": {"openai"}, "key": {realKey}, "label": {"cho Minh"},
		"model": {"gpt-5.4-mini"}, "extra": {"gpt-5.4, gpt-5.4-mini"}}
	// Không đăng nhập hoặc từ trang khác → bỏ qua.
	post(create, "http://example.com", nil)
	post(create, "http://evil.test", cookie)
	if count() != 0 {
		t.Fatal("share created without login / cross-origin")
	}

	// Tải model bằng key: hiện lại form có danh sách model đã lọc, key không lưu.
	load := url.Values{"action": {"load"}, "provider": {"openai"}, "key": {realKey}}
	rec := post(load, "http://example.com", cookie)
	if body := rec.Body.String(); !strings.Contains(body, `value="gpt-5.4-mini"`) || strings.Contains(body, "embedding") || count() != 0 {
		t.Fatalf("load models page wrong (%d shares)", count())
	}

	// Tạo: model tick + gõ thêm được gộp, bỏ trùng.
	if rec := post(create, "http://example.com", cookie); rec.Code != http.StatusSeeOther {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	list, _ := a.shares.List()
	if len(list) != 1 || strings.Join(list[0].Models, ",") != "gpt-5.4-mini,gpt-5.4" || list[0].Key != realKey {
		t.Fatalf("created %+v", list)
	}
	sh := list[0]

	// Trang AI share: có token, key chỉ hiện dạng che.
	req := httptest.NewRequest(http.MethodGet, "/admin?tab=ai", nil)
	req.AddCookie(cookie)
	page := httptest.NewRecorder()
	a.routes().ServeHTTP(page, req)
	if !strings.Contains(page.Body.String(), sh.Token) || strings.Contains(page.Body.String(), realKey) {
		t.Fatal("admin page: token missing or key shown")
	}

	// Sửa model, để trống key → giữ key cũ.
	post(url.Values{"action": {"save"}, "id": {sh.ID}, "provider": {"openai"}, "label": {"cho Minh"}, "model": {"gpt-5.4"}}, "http://example.com", cookie)
	got, _ := a.shares.Get(sh.ID)
	if strings.Join(got.Models, ",") != "gpt-5.4" || got.Key != realKey || got.Token != sh.Token {
		t.Fatalf("edit: %+v", got)
	}

	// Chưa chọn model → báo lỗi, không lưu.
	if rec := post(url.Values{"action": {"save"}, "provider": {"anthropic"}, "key": {"k"}}, "http://example.com", cookie); !strings.Contains(rec.Body.String(), "ít nhất một model") || count() != 1 {
		t.Fatal("empty models accepted")
	}

	post(url.Values{"action": {"revoke"}, "id": {sh.ID}}, "http://example.com", cookie)
	if got, _ := a.shares.Get(sh.ID); got.Status != shareRevoked {
		t.Fatal("revoke not applied")
	}
	post(url.Values{"action": {"delete"}, "id": {sh.ID}}, "http://example.com", cookie)
	if count() != 0 {
		t.Fatal("delete not applied")
	}
}
