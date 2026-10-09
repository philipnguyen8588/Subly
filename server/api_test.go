package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func newTestApp(t *testing.T) *App {
	t.Helper()
	dir := t.TempDir()
	key, err := loadKey(dir, true)
	if err != nil {
		t.Fatal(err)
	}
	st, err := openStore(filepath.Join(dir, "devices.db"))
	if err != nil {
		t.Fatal(err)
	}
	return &App{store: st, key: key, ticketTTL: 7 * 24 * time.Hour, adminPass: "correct horse battery",
		apiLimit: NewRateLimiter(1000, time.Minute), loginLimit: NewRateLimiter(3, time.Minute),
		sessions: NewSessionStore(time.Hour), now: time.Now}
}

type testDevice struct {
	hash string
	pub  ed25519.PublicKey
	priv ed25519.PrivateKey
}

func newDevice(seed string) testDevice {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	h := sha256.Sum256([]byte("subly-v1|" + seed))
	return testDevice{hash: hex.EncodeToString(h[:]), pub: pub, priv: priv}
}

func (d testDevice) request(ts time.Time) sessionRequest {
	k := b64.EncodeToString(d.pub)
	sig := ed25519.Sign(d.priv, []byte(signedMessage(d.hash, k, ts.Unix())))
	return sessionRequest{Hash: d.hash, Pub: k, Name: "Test Mac", User: "minh", Model: "Mac16,10", Platform: "mac",
		OS: "15.5", Version: "0.1.0", TS: ts.Unix(), Sig: b64.EncodeToString(sig)}
}

func call(t *testing.T, a *App, req sessionRequest) sessionResponse {
	t.Helper()
	body, _ := json.Marshal(req)
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(body)))
	if rec.Code != http.StatusOK {
		t.Fatalf("HTTP %d: %s", rec.Code, rec.Body)
	}
	var r sessionResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &r); err != nil {
		t.Fatal(err)
	}
	return r
}

// verifyTicket làm đúng việc client làm: chữ ký, máy, hạn.
func verifyTicket(t *testing.T, pub ed25519.PublicKey, ticket, hash, devPub string, now time.Time) {
	t.Helper()
	parts := strings.Split(ticket, ".")
	if len(parts) != 2 {
		t.Fatalf("bad ticket %q", ticket)
	}
	payload, _ := b64.DecodeString(parts[0])
	sig, _ := b64.DecodeString(parts[1])
	if !ed25519.Verify(pub, payload, sig) {
		t.Fatal("ticket signature invalid")
	}
	f := strings.Split(string(payload), "|")
	if len(f) != 5 || f[0] != "v1" || f[1] != hash || f[2] != devPub {
		t.Fatalf("ticket fields %v", f)
	}
	exp, _ := strconv.ParseInt(f[4], 10, 64)
	if !time.Unix(exp, 0).After(now.Add(6 * 24 * time.Hour)) {
		t.Fatalf("ticket exp too soon: %v", time.Unix(exp, 0))
	}
}

func TestFlow(t *testing.T) {
	a := newTestApp(t)
	d := newDevice("mac-uuid-1")
	now := time.Now()

	// Máy mới: chờ duyệt, không có vé, đã được ghi vào danh sách kèm thông tin.
	if r := call(t, a, d.request(now)); r.C != 1 || r.T != "" {
		t.Fatalf("new device got %+v", r)
	}
	got, _ := a.store.Get(d.hash)
	if got == nil || got.Status != statusPending || got.Name != "Test Mac" || got.Model != "Mac16,10" {
		t.Fatalf("stored %+v", got)
	}

	// Duyệt → có vé hợp lệ.
	_ = a.store.SetStatus(d.hash, statusApproved)
	r := call(t, a, d.request(now))
	if r.C != 0 {
		t.Fatalf("approved device got %+v", r)
	}
	verifyTicket(t, a.key.Public().(ed25519.PublicKey), r.T, d.hash, b64.EncodeToString(d.pub), now)

	// Máy khác giả mã máy này (khoá khác) → không có vé, đánh dấu nghi vấn.
	fake := newDevice("other")
	fake.hash = d.hash
	if r := call(t, a, fake.request(now)); r.C != 1 {
		t.Fatalf("impostor got %+v", r)
	}
	got, _ = a.store.Get(d.hash)
	if got.Conflict.IsZero() {
		t.Fatal("conflict not recorded")
	}
	// Máy thật vẫn dùng bình thường.
	if r := call(t, a, d.request(now)); r.C != 0 {
		t.Fatalf("real device after impostor got %+v", r)
	}

	// Chủ app cho ghi khoá mới (máy cài lại hệ điều hành) → khoá mới được nhận và dùng được.
	_ = a.store.ResetKey(d.hash)
	if r := call(t, a, fake.request(now)); r.C != 0 {
		t.Fatalf("after resetkey got %+v", r)
	}
	if r := call(t, a, d.request(now)); r.C != 1 {
		t.Fatalf("old key after resetkey got %+v", r)
	}

	// Thu hồi → không còn vé.
	_ = a.store.SetStatus(d.hash, statusRevoked)
	if r := call(t, a, fake.request(now)); r.C != 1 {
		t.Fatalf("revoked got %+v", r)
	}
}

func TestRejects(t *testing.T) {
	a := newTestApp(t)
	d := newDevice("x")
	_ = call(t, a, d.request(time.Now()))
	_ = a.store.SetStatus(d.hash, statusApproved)

	// Chữ ký sai.
	req := d.request(time.Now())
	req.Name = "khác" // tên không nằm trong chữ ký nên vẫn hợp lệ
	if r := call(t, a, req); r.C != 0 {
		t.Fatalf("name change should be fine, got %+v", r)
	}
	req = d.request(time.Now())
	req.TS++
	if r := call(t, a, req); r.C != 1 {
		t.Fatalf("tampered ts got %+v", r)
	}
	// Yêu cầu cũ (phát lại) hoặc đồng hồ lệch quá 5 phút.
	if r := call(t, a, d.request(time.Now().Add(-10*time.Minute))); r.C != 1 {
		t.Fatalf("old request got %+v", r)
	}
	// Hash không hợp lệ.
	req = d.request(time.Now())
	req.Hash = "ABC"
	if r := call(t, a, req); r.C != 1 {
		t.Fatalf("bad hash got %+v", r)
	}
}

func TestRateLimit(t *testing.T) {
	l := NewRateLimiter(3, time.Minute)
	base := time.Now()
	l.now = func() time.Time { return base }
	for i := 0; i < 3; i++ {
		if !l.Allow("ip") {
			t.Fatal("should allow")
		}
	}
	if l.Allow("ip") {
		t.Fatal("should block 4th")
	}
	if !l.Allow("other") {
		t.Fatal("other key should be allowed")
	}
	l.now = func() time.Time { return base.Add(61 * time.Second) }
	if !l.Allow("ip") {
		t.Fatal("should allow after window")
	}
}

func TestAdminAuth(t *testing.T) {
	a := newTestApp(t)
	h := a.routes()
	post := func(path string, form url.Values, origin string, cookie *http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		if cookie != nil {
			req.AddCookie(cookie)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}
	// Sai mật khẩu → không có cookie.
	if rec := post("/admin/login", url.Values{"password": {"wrong"}}, "http://example.com", nil); len(rec.Result().Cookies()) != 0 {
		t.Fatal("cookie set on wrong password")
	}
	// Thiếu Origin (CSRF) → không đăng nhập.
	if rec := post("/admin/login", url.Values{"password": {a.adminPass}}, "", nil); len(rec.Result().Cookies()) != 0 {
		t.Fatal("cookie set without origin")
	}
	rec := post("/admin/login", url.Values{"password": {a.adminPass}}, "http://example.com", nil)
	cs := rec.Result().Cookies()
	if len(cs) != 1 || !cs[0].HttpOnly {
		t.Fatalf("login cookies %+v", cs)
	}
	d := newDevice("y")
	_ = call(t, a, d.request(time.Now()))
	// Duyệt từ trang khác (CSRF) → bị bỏ qua.
	post("/admin/device", url.Values{"hash": {d.hash}, "action": {"approve"}}, "http://evil.test", cs[0])
	if got, _ := a.store.Get(d.hash); got.Status != statusPending {
		t.Fatal("cross-origin approve applied")
	}
	post("/admin/device", url.Values{"hash": {d.hash}, "action": {"approve"}}, "http://example.com", cs[0])
	if got, _ := a.store.Get(d.hash); got.Status != statusApproved {
		t.Fatal("approve not applied")
	}
	// Không đăng nhập → bị bỏ qua.
	post("/admin/device", url.Values{"hash": {d.hash}, "action": {"revoke"}}, "http://example.com", nil)
	if got, _ := a.store.Get(d.hash); got.Status != statusApproved {
		t.Fatal("revoke without login applied")
	}
	// Đoán mật khẩu quá 3 lần → bị chặn dù đúng.
	for i := 0; i < 3; i++ {
		post("/admin/login", url.Values{"password": {"wrong"}}, "http://example.com", nil)
	}
	if rec := post("/admin/login", url.Values{"password": {a.adminPass}}, "http://example.com", nil); len(rec.Result().Cookies()) != 0 {
		t.Fatal("login allowed after too many attempts")
	}
}
