package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

func init() { pbkdf2Iter = 1000 }

func TestPBKDF2Vector(t *testing.T) {
	// RFC 7914 §11: PBKDF2-HMAC-SHA256("passwd", "salt", 1, 64).
	got := hex.EncodeToString(pbkdf2Key([]byte("passwd"), []byte("salt"), 1, 64, sha256.New))
	want := "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"
	if got != want {
		t.Fatalf("pbkdf2 = %s", got)
	}
	h := hashPassword("bí mật 123")
	if !checkPassword(h, "bí mật 123") || checkPassword(h, "bí mật 124") || checkPassword("garbage", "x") {
		t.Fatal("checkPassword")
	}
}

// adminPost gửi form tới trang admin như trình duyệt đã đăng nhập.
func adminPost(t *testing.T, a *App, c *http.Cookie, path string, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Origin", "http://example.com")
	req.AddCookie(c)
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, req)
	return rec
}

func apiCall(t *testing.T, a *App, method, path, token string, body io.Reader) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, body)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, req)
	return rec
}

func login(t *testing.T, a *App, user, pass string) (string, int) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"username": user, "password": pass, "device": "Test PC"})
	rec := apiCall(t, a, http.MethodPost, "/v1/account/login", "", bytes.NewReader(body))
	var r struct{ Token string }
	json.Unmarshal(rec.Body.Bytes(), &r)
	return r.Token, rec.Code
}

func createAccount(t *testing.T, a *App, c *http.Cookie, user, pass string) {
	t.Helper()
	rec := adminPost(t, a, c, "/admin/accounts", url.Values{"action": {"create"}, "username": {user}, "password": {pass}})
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Đã tạo tài khoản") {
		t.Fatalf("create %s: %d %s", user, rec.Code, rec.Body)
	}
}

var zipBody = []byte("PK\x03\x04 fake zip payload for tests")

func machineID(seed string) string {
	h := sha256.Sum256([]byte(seed))
	return hex.EncodeToString(h[:])
}

func TestAccountBackupFlow(t *testing.T) {
	a := newTestApp(t)
	c := adminLogin(t, a)
	createAccount(t, a, c, "Minh@Example.com", "matkhau1")

	if _, code := login(t, a, "minh@example.com", "sai"); code != http.StatusUnauthorized {
		t.Fatalf("sai mật khẩu: %d", code)
	}
	if _, code := login(t, a, "khongco", "matkhau1"); code != http.StatusUnauthorized {
		t.Fatalf("không có user: %d", code)
	}
	tok, code := login(t, a, " MINH@example.com ", "matkhau1")
	if code != http.StatusOK || !strings.HasPrefix(tok, "sbu_") {
		t.Fatalf("login: %d %q", code, tok)
	}

	if rec := apiCall(t, a, http.MethodGet, "/v1/backups", "sbu_wrong", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("token sai: %d", rec.Code)
	}
	if rec := apiCall(t, a, http.MethodGet, "/v1/backups", "", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("không token: %d", rec.Code)
	}

	m1, m2 := machineID("mac"), machineID("win")
	put := func(tok, m, name string, body []byte) *httptest.ResponseRecorder {
		return apiCall(t, a, http.MethodPut, "/v1/backups/"+m+"?name="+url.QueryEscape(name)+"&platform=mac&v=0.3.0", tok, bytes.NewReader(body))
	}
	if rec := put(tok, "abc", "x", zipBody); rec.Code != http.StatusBadRequest {
		t.Fatalf("mã máy sai: %d", rec.Code)
	}
	if rec := put(tok, m1, "x", []byte("not a zip")); rec.Code != http.StatusBadRequest {
		t.Fatalf("không phải zip: %d", rec.Code)
	}
	big := append(append([]byte{}, zipBody...), make([]byte, a.backupMax)...)
	if rec := put(tok, m1, "x", big); rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("quá lớn: %d", rec.Code)
	}
	if rec := put(tok, m1, "Mac mini", zipBody); rec.Code != http.StatusOK {
		t.Fatalf("put: %d %s", rec.Code, rec.Body)
	}
	time.Sleep(1100 * time.Millisecond) // created tính theo giây: bản sau phải mới hơn
	v2 := append(append([]byte{}, zipBody...), []byte(" v2")...)
	if rec := put(tok, m1, "Mac mini mới", v2); rec.Code != http.StatusOK {
		t.Fatalf("put lại: %d", rec.Code)
	}
	if rec := put(tok, m2, "PC Win", zipBody); rec.Code != http.StatusOK {
		t.Fatalf("put máy 2: %d", rec.Code)
	}

	rec := apiCall(t, a, http.MethodGet, "/v1/backups", tok, nil)
	var list struct{ Backups []backupView }
	json.Unmarshal(rec.Body.Bytes(), &list)
	if len(list.Backups) != 2 {
		t.Fatalf("list: %s", rec.Body)
	}
	var mac backupView
	for _, b := range list.Backups {
		if b.Machine == m1 {
			mac = b
		}
	}
	sum := sha256.Sum256(v2)
	if mac.Name != "Mac mini mới" || mac.Size != int64(len(v2)) || mac.SHA256 != hex.EncodeToString(sum[:]) || mac.Platform != "mac" || mac.IP == "" {
		t.Fatalf("bản ghi đè sai: %+v", mac)
	}

	rec = apiCall(t, a, http.MethodGet, "/v1/backups/"+m1, tok, nil)
	if rec.Code != http.StatusOK || !bytes.Equal(rec.Body.Bytes(), v2) || rec.Header().Get("X-Backup-SHA256") != mac.SHA256 {
		t.Fatalf("download: %d", rec.Code)
	}

	// Tài khoản khác không thấy và không tải được bản của Minh.
	createAccount(t, a, c, "lan", "matkhau2")
	tok2, _ := login(t, a, "lan", "matkhau2")
	rec = apiCall(t, a, http.MethodGet, "/v1/backups", tok2, nil)
	json.Unmarshal(rec.Body.Bytes(), &list)
	if len(list.Backups) != 0 {
		t.Fatalf("lan thấy bản của minh: %s", rec.Body)
	}
	if rec := apiCall(t, a, http.MethodGet, "/v1/backups/"+m1, tok2, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("lan tải được bản của minh: %d", rec.Code)
	}

	if rec := apiCall(t, a, http.MethodDelete, "/v1/backups/"+m2, tok, nil); rec.Code != http.StatusOK {
		t.Fatalf("delete: %d", rec.Code)
	}
	if rec := apiCall(t, a, http.MethodGet, "/v1/backups/"+m2, tok, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("sau khi xoá: %d", rec.Code)
	}

	// Trang admin liệt kê tài khoản và bản sao lưu.
	req := httptest.NewRequest(http.MethodGet, "/admin?tab=accounts", nil)
	req.AddCookie(c)
	page := httptest.NewRecorder()
	a.routes().ServeHTTP(page, req)
	if !strings.Contains(page.Body.String(), "minh@example.com") || !strings.Contains(page.Body.String(), "Mac mini mới") {
		t.Fatalf("admin page thiếu dữ liệu")
	}

	minh, _ := a.store.UserByName("minh@example.com")
	id := url.Values{"id": {strconv.FormatInt(minh.ID, 10)}}
	with := func(k, v string) url.Values {
		f := url.Values{}
		for kk, vv := range id {
			f[kk] = vv
		}
		f.Set(k, v)
		return f
	}

	// Khoá → token bị từ chối; mở lại → dùng được.
	adminPost(t, a, c, "/admin/accounts", with("action", "lock"))
	if rec := apiCall(t, a, http.MethodGet, "/v1/backups", tok, nil); rec.Code != http.StatusForbidden {
		t.Fatalf("bị khoá: %d", rec.Code)
	}
	if _, code := login(t, a, "minh@example.com", "matkhau1"); code != http.StatusForbidden {
		t.Fatalf("login khi bị khoá: %d", code)
	}
	adminPost(t, a, c, "/admin/accounts", with("action", "unlock"))

	// Đổi mật khẩu (tự tạo) → token cũ mất hiệu lực, mật khẩu mới hiện một lần.
	rec = adminPost(t, a, c, "/admin/accounts", with("action", "password"))
	mpw := regexp.MustCompile(`Mật khẩu mới: (\S+)`).FindStringSubmatch(rec.Body.String())
	if mpw == nil {
		t.Fatalf("không thấy mật khẩu mới")
	}
	if rec := apiCall(t, a, http.MethodGet, "/v1/backups", tok, nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("token cũ sau đổi mật khẩu: %d", rec.Code)
	}
	if _, code := login(t, a, "minh@example.com", mpw[1]); code != http.StatusOK {
		t.Fatalf("login bằng mật khẩu mới: %d", code)
	}

	// Đăng xuất thu hồi token.
	tok3, _ := login(t, a, "minh@example.com", mpw[1])
	apiCall(t, a, http.MethodPost, "/v1/account/logout", tok3, nil)
	if rec := apiCall(t, a, http.MethodGet, "/v1/backups", tok3, nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("sau đăng xuất: %d", rec.Code)
	}

	// Xoá tài khoản → file sao lưu cũng mất.
	path := a.backupPath(minh.ID, m1)
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
	adminPost(t, a, c, "/admin/accounts", with("action", "delete"))
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("file còn sau khi xoá tài khoản")
	}
	if u, _ := a.store.UserByName("minh@example.com"); u != nil {
		t.Fatal("user còn")
	}
}

func TestAccountAdminValidation(t *testing.T) {
	a := newTestApp(t)
	c := adminLogin(t, a)
	for _, name := range []string{"ab", "có dấu", "a/b"} {
		rec := adminPost(t, a, c, "/admin/accounts", url.Values{"action": {"create"}, "username": {name}, "password": {"matkhau1"}})
		if !strings.Contains(rec.Body.String(), "Tên đăng nhập 3–64") {
			t.Errorf("%q được chấp nhận", name)
		}
	}
	createAccount(t, a, c, "binh", "")
	rec := adminPost(t, a, c, "/admin/accounts", url.Values{"action": {"create"}, "username": {"BINH"}, "password": {"matkhau1"}})
	if !strings.Contains(rec.Body.String(), "đã có") {
		t.Error("trùng tên được chấp nhận")
	}
	// Không đăng nhập admin hoặc khác origin → không làm gì.
	req := httptest.NewRequest(http.MethodPost, "/admin/accounts", strings.NewReader("action=create&username=hacker&password=matkhau1"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Origin", "http://evil.com")
	req.AddCookie(c)
	a.routes().ServeHTTP(httptest.NewRecorder(), req)
	if u, _ := a.store.UserByName("hacker"); u != nil {
		t.Error("CSRF tạo được tài khoản")
	}
}

func TestAccountLoginRateLimit(t *testing.T) {
	a := newTestApp(t)
	a.accountLimit = NewRateLimiter(3, time.Minute)
	for i := 0; i < 3; i++ {
		login(t, a, "x", "y")
	}
	if _, code := login(t, a, "x", "y"); code != http.StatusTooManyRequests {
		t.Fatalf("không bị giới hạn: %d", code)
	}
}
