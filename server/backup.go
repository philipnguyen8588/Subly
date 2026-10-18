package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Sao lưu dữ liệu app theo tài khoản: admin tạo tài khoản, app đăng nhập lấy token rồi đẩy một file zip cho mỗi máy
// (bản mới ghi đè bản cũ của cùng máy). Máy nào cũng tải được bản của bất kỳ máy nào trong cùng tài khoản.

const (
	userActive = "active"
	userLocked = "locked"
)

const accountTables = `
CREATE TABLE IF NOT EXISTS users(
	id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE, pass_hash TEXT NOT NULL,
	status TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', created INTEGER NOT NULL, last_login INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS user_tokens(
	token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL, device TEXT NOT NULL DEFAULT '',
	created INTEGER NOT NULL, last_used INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS backups(
	user_id INTEGER NOT NULL, machine TEXT NOT NULL, name TEXT NOT NULL DEFAULT '', platform TEXT NOT NULL DEFAULT '',
	app_version TEXT NOT NULL DEFAULT '', ip TEXT NOT NULL DEFAULT '', size INTEGER NOT NULL, sha256 TEXT NOT NULL,
	created INTEGER NOT NULL, PRIMARY KEY(user_id, machine));`

type User struct {
	ID        int64
	Username  string
	PassHash  string
	Status    string
	Note      string
	Created   time.Time
	LastLogin time.Time
}

type Backup struct {
	UserID     int64
	Machine    string
	Name       string
	Platform   string
	AppVersion string
	IP         string
	Size       int64
	SHA256     string
	Created    time.Time
}

// --- mật khẩu: PBKDF2-HMAC-SHA256 (thư viện chuẩn, không thêm phụ thuộc) ---

// pbkdf2Iter: số vòng cho mật khẩu mới; test hạ xuống cho nhanh. Số vòng được ghi trong chuỗi hash nên đổi không ảnh hưởng mật khẩu cũ.
var pbkdf2Iter = 310000

func pbkdf2Key(password, salt []byte, iter, keyLen int, h func() hash.Hash) []byte {
	prf := hmac.New(h, password)
	hLen := prf.Size()
	blocks := (keyLen + hLen - 1) / hLen
	out := make([]byte, 0, blocks*hLen)
	buf := make([]byte, 4)
	u := make([]byte, hLen)
	for b := 1; b <= blocks; b++ {
		prf.Reset()
		prf.Write(salt)
		binary.BigEndian.PutUint32(buf, uint32(b))
		prf.Write(buf)
		u = prf.Sum(u[:0])
		t := make([]byte, hLen)
		copy(t, u)
		for i := 1; i < iter; i++ {
			prf.Reset()
			prf.Write(u)
			u = prf.Sum(u[:0])
			for j := range t {
				t[j] ^= u[j]
			}
		}
		out = append(out, t...)
	}
	return out[:keyLen]
}

func hashPassword(pw string) string {
	salt := make([]byte, 16)
	_, _ = rand.Read(salt)
	k := pbkdf2Key([]byte(pw), salt, pbkdf2Iter, 32, sha256.New)
	return fmt.Sprintf("pbkdf2-sha256$%d$%s$%s", pbkdf2Iter, b64.EncodeToString(salt), b64.EncodeToString(k))
}

func checkPassword(stored, pw string) bool {
	parts := strings.Split(stored, "$")
	if len(parts) != 4 || parts[0] != "pbkdf2-sha256" {
		return false
	}
	iter, err := strconv.Atoi(parts[1])
	if err != nil || iter < 1 {
		return false
	}
	salt, err1 := b64.DecodeString(parts[2])
	want, err2 := b64.DecodeString(parts[3])
	if err1 != nil || err2 != nil || len(want) == 0 {
		return false
	}
	return subtle.ConstantTimeCompare(pbkdf2Key([]byte(pw), salt, iter, len(want), sha256.New), want) == 1
}

// randomPassword: 12 ký tự dễ đọc (không có 0/O, 1/l/I) cho admin gửi người dùng.
func randomPassword() string {
	const alphabet = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return string(b)
}

var usernameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9._@-]{2,63}$`)

func normalizeUsername(s string) string { return strings.ToLower(strings.TrimSpace(s)) }

func hashToken(t string) string {
	h := sha256.Sum256([]byte(t))
	return hex.EncodeToString(h[:])
}

// --- lưu trữ ---

var errUserExists = errors.New("username exists")

const userCols = `id, username, pass_hash, status, note, created, last_login`

func scanUser(sc interface{ Scan(...any) error }) (*User, error) {
	var u User
	var created, last int64
	if err := sc.Scan(&u.ID, &u.Username, &u.PassHash, &u.Status, &u.Note, &created, &last); err != nil {
		return nil, err
	}
	u.Created = time.Unix(created, 0)
	if last > 0 {
		u.LastLogin = time.Unix(last, 0)
	}
	return &u, nil
}

func (s *Store) CreateUser(username, passHash, note string, now time.Time) (int64, error) {
	if u, _ := s.UserByName(username); u != nil {
		return 0, errUserExists
	}
	res, err := s.db.Exec(`INSERT INTO users(username, pass_hash, status, note, created) VALUES(?,?,?,?,?)`,
		username, passHash, userActive, note, now.Unix())
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Store) UserByName(username string) (*User, error) {
	u, err := scanUser(s.db.QueryRow(`SELECT `+userCols+` FROM users WHERE username = ?`, username))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return u, err
}

func (s *Store) UserByID(id int64) (*User, error) {
	u, err := scanUser(s.db.QueryRow(`SELECT `+userCols+` FROM users WHERE id = ?`, id))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return u, err
}

func (s *Store) Users() ([]*User, error) {
	rows, err := s.db.Query(`SELECT ` + userCols + ` FROM users ORDER BY username`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*User
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// SetPassword đổi mật khẩu và thu hồi mọi token (các máy phải đăng nhập lại).
func (s *Store) SetPassword(id int64, passHash string) error {
	if _, err := s.db.Exec(`UPDATE users SET pass_hash = ? WHERE id = ?`, passHash, id); err != nil {
		return err
	}
	_, err := s.db.Exec(`DELETE FROM user_tokens WHERE user_id = ?`, id)
	return err
}

func (s *Store) SetUserStatus(id int64, status string) error {
	_, err := s.db.Exec(`UPDATE users SET status = ? WHERE id = ?`, status, id)
	return err
}

func (s *Store) SetUserNote(id int64, note string) error {
	_, err := s.db.Exec(`UPDATE users SET note = ? WHERE id = ?`, note, id)
	return err
}

func (s *Store) DeleteUser(id int64) error {
	for _, q := range []string{`DELETE FROM user_tokens WHERE user_id = ?`, `DELETE FROM backups WHERE user_id = ?`, `DELETE FROM users WHERE id = ?`} {
		if _, err := s.db.Exec(q, id); err != nil {
			return err
		}
	}
	return nil
}

// NewUserToken cấp token đăng nhập cho một máy; chỉ lưu sha256 của token.
func (s *Store) NewUserToken(userID int64, device string, now time.Time) (string, error) {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	tok := "sbu_" + base64.RawURLEncoding.EncodeToString(b)
	if _, err := s.db.Exec(`INSERT INTO user_tokens(token_hash, user_id, device, created, last_used) VALUES(?,?,?,?,?)`,
		hashToken(tok), userID, device, now.Unix(), now.Unix()); err != nil {
		return "", err
	}
	s.db.Exec(`UPDATE users SET last_login = ? WHERE id = ?`, now.Unix(), userID)
	return tok, nil
}

// UserByToken: người dùng ứng với token (nil nếu token sai). Cập nhật lần dùng cuối.
func (s *Store) UserByToken(tok string, now time.Time) (*User, error) {
	if !strings.HasPrefix(tok, "sbu_") {
		return nil, nil
	}
	th := hashToken(tok)
	var uid int64
	if err := s.db.QueryRow(`SELECT user_id FROM user_tokens WHERE token_hash = ?`, th).Scan(&uid); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	s.db.Exec(`UPDATE user_tokens SET last_used = ? WHERE token_hash = ?`, now.Unix(), th)
	return s.UserByID(uid)
}

func (s *Store) DeleteUserToken(tok string) error {
	_, err := s.db.Exec(`DELETE FROM user_tokens WHERE token_hash = ?`, hashToken(tok))
	return err
}

const backupCols = `user_id, machine, name, platform, app_version, ip, size, sha256, created`

func scanBackup(sc interface{ Scan(...any) error }) (*Backup, error) {
	var b Backup
	var created int64
	if err := sc.Scan(&b.UserID, &b.Machine, &b.Name, &b.Platform, &b.AppVersion, &b.IP, &b.Size, &b.SHA256, &created); err != nil {
		return nil, err
	}
	b.Created = time.Unix(created, 0)
	return &b, nil
}

// Backups: các bản sao lưu của một người dùng, mới nhất trước. userID = 0 → của mọi người dùng (trang admin).
func (s *Store) Backups(userID int64) ([]*Backup, error) {
	q, args := `SELECT `+backupCols+` FROM backups ORDER BY created DESC`, []any{}
	if userID != 0 {
		q, args = `SELECT `+backupCols+` FROM backups WHERE user_id = ? ORDER BY created DESC`, []any{userID}
	}
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Backup
	for rows.Next() {
		b, err := scanBackup(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func (s *Store) Backup(userID int64, machine string) (*Backup, error) {
	b, err := scanBackup(s.db.QueryRow(`SELECT `+backupCols+` FROM backups WHERE user_id = ? AND machine = ?`, userID, machine))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return b, err
}

func (s *Store) PutBackup(b *Backup) error {
	_, err := s.db.Exec(`INSERT INTO backups(`+backupCols+`) VALUES(?,?,?,?,?,?,?,?,?)
		ON CONFLICT(user_id, machine) DO UPDATE SET name=excluded.name, platform=excluded.platform, app_version=excluded.app_version,
		ip=excluded.ip, size=excluded.size, sha256=excluded.sha256, created=excluded.created`,
		b.UserID, b.Machine, b.Name, b.Platform, b.AppVersion, b.IP, b.Size, b.SHA256, b.Created.Unix())
	return err
}

func (s *Store) DeleteBackup(userID int64, machine string) error {
	_, err := s.db.Exec(`DELETE FROM backups WHERE user_id = ? AND machine = ?`, userID, machine)
	return err
}

// --- file trên đĩa ---

func (a *App) userBackupDir(userID int64) string {
	return filepath.Join(a.backupDir, strconv.FormatInt(userID, 10))
}

func (a *App) backupPath(userID int64, machine string) string {
	return filepath.Join(a.userBackupDir(userID), machine+".zip")
}

// --- API cho app ---

type backupView struct {
	Machine    string `json:"machine"`
	Name       string `json:"name"`
	Platform   string `json:"platform"`
	AppVersion string `json:"appVersion"`
	IP         string `json:"ip"`
	Size       int64  `json:"size"`
	SHA256     string `json:"sha256"`
	Created    int64  `json:"created"`
}

func viewBackup(b *Backup) backupView {
	return backupView{Machine: b.Machine, Name: b.Name, Platform: b.Platform, AppVersion: b.AppVersion, IP: b.IP,
		Size: b.Size, SHA256: b.SHA256, Created: b.Created.Unix()}
}

// apiError trả {"error": "…"} kèm mã HTTP; app hiện nguyên câu này cho người dùng.
func apiError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

const msgBadLogin = "Sai tên đăng nhập hoặc mật khẩu"

// handleAccountLogin: POST /v1/account/login {username, password, device} → {token, username}.
func (a *App) handleAccountLogin(w http.ResponseWriter, r *http.Request) {
	ip := a.clientIP(r)
	if !a.accountLimit.Allow(ip) {
		apiError(w, http.StatusTooManyRequests, "Thử sai quá nhiều lần, đợi 15 phút rồi thử lại")
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
		Device   string `json:"device"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil {
		apiError(w, http.StatusBadRequest, "Yêu cầu không hợp lệ")
		return
	}
	u, err := a.store.UserByName(normalizeUsername(req.Username))
	if err != nil {
		apiError(w, http.StatusInternalServerError, "Lỗi server")
		return
	}
	if u == nil || !checkPassword(u.PassHash, req.Password) {
		log.Printf("account login failed %q from %s", clip(req.Username, 64), ip)
		apiError(w, http.StatusUnauthorized, msgBadLogin)
		return
	}
	if u.Status != userActive {
		apiError(w, http.StatusForbidden, "Tài khoản đã bị khoá")
		return
	}
	tok, err := a.store.NewUserToken(u.ID, clip(req.Device, 100), a.now())
	if err != nil {
		apiError(w, http.StatusInternalServerError, "Lỗi server")
		return
	}
	log.Printf("account login %s from %s", u.Username, ip)
	writeJSON(w, map[string]string{"token": tok, "username": u.Username})
}

// handleAccountLogout: POST /v1/account/logout (Bearer) → thu hồi token này.
func (a *App) handleAccountLogout(w http.ResponseWriter, r *http.Request) {
	if tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer "); ok {
		a.store.DeleteUserToken(strings.TrimSpace(tok))
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// accountUser: người dùng ứng với token Bearer, nil (đã trả lỗi) nếu không dùng được.
func (a *App) accountUser(w http.ResponseWriter, r *http.Request) *User {
	if !a.apiLimit.Allow(a.clientIP(r)) {
		apiError(w, http.StatusTooManyRequests, "Quá nhiều yêu cầu, thử lại sau")
		return nil
	}
	tok, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	u, err := a.store.UserByToken(strings.TrimSpace(tok), a.now())
	if err != nil {
		apiError(w, http.StatusInternalServerError, "Lỗi server")
		return nil
	}
	if u == nil {
		apiError(w, http.StatusUnauthorized, "Phiên đăng nhập đã hết, hãy đăng nhập lại")
		return nil
	}
	if u.Status != userActive {
		apiError(w, http.StatusForbidden, "Tài khoản đã bị khoá")
		return nil
	}
	return u
}

// handleBackupList: GET /v1/backups → {"backups": [...]} của tài khoản, mới nhất trước.
func (a *App) handleBackupList(w http.ResponseWriter, r *http.Request) {
	u := a.accountUser(w, r)
	if u == nil {
		return
	}
	list, err := a.store.Backups(u.ID)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "Lỗi server")
		return
	}
	views := make([]backupView, 0, len(list))
	for _, b := range list {
		views = append(views, viewBackup(b))
	}
	writeJSON(w, map[string]any{"username": u.Username, "backups": views})
}

// extendDeadlines: server đặt timeout 20 s cho mọi request; tải lên/tải về bản sao lưu cần lâu hơn.
func extendDeadlines(w http.ResponseWriter, d time.Duration) {
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Now().Add(d))
	_ = rc.SetWriteDeadline(time.Now().Add(d))
}

// handleBackupPut: PUT /v1/backups/{machine}?name=&platform=&v= với body là file zip. Ghi đè bản cũ của cùng máy.
func (a *App) handleBackupPut(w http.ResponseWriter, r *http.Request) {
	u := a.accountUser(w, r)
	if u == nil {
		return
	}
	machine := r.PathValue("machine")
	if !validHash(machine) {
		apiError(w, http.StatusBadRequest, "Mã máy không hợp lệ")
		return
	}
	tooBig := fmt.Sprintf("Bản sao lưu vượt quá %d MB", a.backupMax>>20)
	if r.ContentLength > a.backupMax {
		apiError(w, http.StatusRequestEntityTooLarge, tooBig)
		return
	}
	extendDeadlines(w, 10*time.Minute)
	dir := a.userBackupDir(u.ID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		log.Printf("backup mkdir: %v", err)
		apiError(w, http.StatusInternalServerError, "Lỗi server")
		return
	}
	tmp, err := os.CreateTemp(dir, ".upload-*")
	if err != nil {
		log.Printf("backup temp: %v", err)
		apiError(w, http.StatusInternalServerError, "Lỗi server")
		return
	}
	defer os.Remove(tmp.Name()) // sau khi đổi tên thành công thì không còn file này
	sum := sha256.New()
	body := http.MaxBytesReader(w, r.Body, a.backupMax)
	var head [4]byte
	n, err := io.ReadFull(body, head[:])
	if err != nil || string(head[:n]) != "PK\x03\x04" {
		tmp.Close()
		apiError(w, http.StatusBadRequest, "File sao lưu không phải zip")
		return
	}
	sum.Write(head[:])
	tmp.Write(head[:])
	size, err := io.Copy(io.MultiWriter(tmp, sum), body)
	size += 4
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		var mb *http.MaxBytesError
		if errors.As(err, &mb) {
			apiError(w, http.StatusRequestEntityTooLarge, tooBig)
		} else {
			apiError(w, http.StatusBadRequest, "Tải lên bị gián đoạn")
		}
		return
	}
	if err := os.Rename(tmp.Name(), a.backupPath(u.ID, machine)); err != nil {
		log.Printf("backup rename: %v", err)
		apiError(w, http.StatusInternalServerError, "Lỗi server")
		return
	}
	q := r.URL.Query()
	platform := q.Get("platform")
	if platform != "mac" && platform != "win" {
		platform = ""
	}
	b := &Backup{UserID: u.ID, Machine: machine, Name: clip(q.Get("name"), 100), Platform: platform,
		AppVersion: clip(q.Get("v"), 20), IP: a.clientIP(r), Size: size, SHA256: hex.EncodeToString(sum.Sum(nil)), Created: a.now()}
	if err := a.store.PutBackup(b); err != nil {
		apiError(w, http.StatusInternalServerError, "Lỗi server")
		return
	}
	log.Printf("backup %s %s (%s) %d bytes from %s", u.Username, short(machine), b.Name, size, b.IP)
	writeJSON(w, viewBackup(b))
}

// handleBackupGet: GET /v1/backups/{machine} → file zip của máy đó (trong cùng tài khoản).
func (a *App) handleBackupGet(w http.ResponseWriter, r *http.Request) {
	u := a.accountUser(w, r)
	if u == nil {
		return
	}
	machine := r.PathValue("machine")
	b, err := a.store.Backup(u.ID, machine)
	if err != nil || !validHash(machine) {
		apiError(w, http.StatusBadRequest, "Mã máy không hợp lệ")
		return
	}
	if b == nil {
		apiError(w, http.StatusNotFound, "Không có bản sao lưu của máy này")
		return
	}
	f, err := os.Open(a.backupPath(u.ID, machine))
	if err != nil {
		apiError(w, http.StatusNotFound, "Không có bản sao lưu của máy này")
		return
	}
	defer f.Close()
	extendDeadlines(w, 10*time.Minute)
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Disposition", `attachment; filename="subly-backup.zip"`)
	w.Header().Set("X-Backup-SHA256", b.SHA256)
	http.ServeContent(w, r, "subly-backup.zip", b.Created, f)
}

// handleBackupDelete: DELETE /v1/backups/{machine}.
func (a *App) handleBackupDelete(w http.ResponseWriter, r *http.Request) {
	u := a.accountUser(w, r)
	if u == nil {
		return
	}
	machine := r.PathValue("machine")
	if !validHash(machine) {
		apiError(w, http.StatusBadRequest, "Mã máy không hợp lệ")
		return
	}
	if err := a.store.DeleteBackup(u.ID, machine); err != nil {
		apiError(w, http.StatusInternalServerError, "Lỗi server")
		return
	}
	os.Remove(a.backupPath(u.ID, machine))
	log.Printf("backup delete %s %s", u.Username, short(machine))
	writeJSON(w, map[string]bool{"ok": true})
}

// --- trang admin: tab Tài khoản ---

type accountView struct {
	*User
	Backups   []*Backup
	TotalSize int64
}

func (a *App) renderAccounts(w http.ResponseWriter, notice, errMsg string) {
	users, err := a.store.Users()
	if err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	all, err := a.store.Backups(0)
	if err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	byUser := map[int64][]*Backup{}
	for _, b := range all {
		byUser[b.UserID] = append(byUser[b.UserID], b)
	}
	views := make([]accountView, len(users))
	for i, u := range users {
		v := accountView{User: u, Backups: byUser[u.ID]}
		for _, b := range v.Backups {
			v.TotalSize += b.Size
		}
		views[i] = v
	}
	counts, _ := a.store.Counts()
	a.render(w, adminPage{LoggedIn: true, Tab: "accounts", Accounts: views, Notice: notice, Error: errMsg, Counts: counts,
		BackupMaxMB: int(a.backupMax >> 20)})
}

// handleAccountAction: tạo / đổi mật khẩu / khoá / mở / ghi chú / xoá tài khoản.
func (a *App) handleAccountAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !sameOrigin(r) || !a.loggedIn(r) {
		http.Redirect(w, r, "/admin", http.StatusSeeOther)
		return
	}
	act := r.FormValue("action")
	if act == "create" {
		name := normalizeUsername(r.FormValue("username"))
		if !usernameRe.MatchString(name) {
			a.renderAccounts(w, "", "Tên đăng nhập 3–64 ký tự: chữ thường, số, . _ @ -")
			return
		}
		pw, generated := r.FormValue("password"), false
		if pw == "" {
			pw, generated = randomPassword(), true
		}
		if len(pw) < 6 {
			a.renderAccounts(w, "", "Mật khẩu ít nhất 6 ký tự")
			return
		}
		if _, err := a.store.CreateUser(name, hashPassword(pw), clip(r.FormValue("note"), 200), a.now()); err != nil {
			if errors.Is(err, errUserExists) {
				a.renderAccounts(w, "", "Tên đăng nhập “"+name+"” đã có")
				return
			}
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		log.Printf("admin account create %s", name)
		notice := "Đã tạo tài khoản “" + name + "”."
		if generated {
			notice += " Mật khẩu: " + pw + " (chỉ hiện lần này)"
		}
		a.renderAccounts(w, notice, "")
		return
	}
	id, _ := strconv.ParseInt(r.FormValue("id"), 10, 64)
	u, err := a.store.UserByID(id)
	if err != nil || u == nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	notice := ""
	switch act {
	case "password":
		pw, generated := r.FormValue("password"), false
		if pw == "" {
			pw, generated = randomPassword(), true
		}
		if len(pw) < 6 {
			a.renderAccounts(w, "", "Mật khẩu ít nhất 6 ký tự")
			return
		}
		err = a.store.SetPassword(u.ID, hashPassword(pw))
		notice = "Đã đổi mật khẩu “" + u.Username + "”, các máy phải đăng nhập lại."
		if generated {
			notice += " Mật khẩu mới: " + pw + " (chỉ hiện lần này)"
		}
	case "lock":
		err = a.store.SetUserStatus(u.ID, userLocked)
	case "unlock":
		err = a.store.SetUserStatus(u.ID, userActive)
	case "note":
		err = a.store.SetUserNote(u.ID, clip(r.FormValue("note"), 200))
	case "delete":
		if err = a.store.DeleteUser(u.ID); err == nil {
			os.RemoveAll(a.userBackupDir(u.ID))
			notice = "Đã xoá tài khoản “" + u.Username + "” và các bản sao lưu."
		}
	case "delbackup":
		m := r.FormValue("machine")
		if !validHash(m) {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		if err = a.store.DeleteBackup(u.ID, m); err == nil {
			os.Remove(a.backupPath(u.ID, m))
		}
	default:
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	log.Printf("admin account %s %s", act, u.Username)
	if notice != "" {
		a.renderAccounts(w, notice, "")
		return
	}
	http.Redirect(w, r, "/admin?tab=accounts", http.StatusSeeOther)
}

// humanSize: dung lượng dạng "12,3 MB" cho trang admin.
func humanSize(n int64) string {
	switch {
	case n >= 1<<30:
		return strings.Replace(fmt.Sprintf("%.1f GB", float64(n)/(1<<30)), ".", ",", 1)
	case n >= 1<<20:
		return strings.Replace(fmt.Sprintf("%.1f MB", float64(n)/(1<<20)), ".", ",", 1)
	case n >= 1<<10:
		return fmt.Sprintf("%d KB", n>>10)
	default:
		return fmt.Sprintf("%d B", n)
	}
}
