package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// Trạng thái của một máy. Client không bao giờ thấy các giá trị này: nó chỉ nhận vé hoặc không.
const (
	statusPending  = "pending"
	statusApproved = "approved"
	statusRevoked  = "revoked"
)

type Device struct {
	Hash       string
	Pub        string
	Name       string
	Email      string
	User       string
	Model      string
	Platform   string
	OS         string
	AppVersion string
	Status     string
	Note       string
	Created    time.Time
	LastSeen   time.Time
	LastIP     string
	// Lần gần nhất máy gửi lên một public key khác với key đã ghi (có thể là máy khác giả mã máy này).
	Conflict time.Time
}

type Store struct{ db *sql.DB }

func openStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS devices(
		hash TEXT PRIMARY KEY, pub TEXT NOT NULL, name TEXT NOT NULL DEFAULT '', email TEXT NOT NULL DEFAULT '', user TEXT NOT NULL DEFAULT '',
		model TEXT NOT NULL DEFAULT '', platform TEXT NOT NULL DEFAULT '', os TEXT NOT NULL DEFAULT '',
		app_version TEXT NOT NULL DEFAULT '', status TEXT NOT NULL, note TEXT NOT NULL DEFAULT '',
		created INTEGER NOT NULL, last_seen INTEGER NOT NULL, last_ip TEXT NOT NULL DEFAULT '',
		conflict INTEGER NOT NULL DEFAULT 0)`)
	if err != nil {
		return nil, err
	}
	// Thêm cột email cho DB tạo trước khi có tính năng này (bỏ qua nếu đã có).
	db.Exec(`ALTER TABLE devices ADD COLUMN email TEXT NOT NULL DEFAULT ''`)
	// Phiên đăng nhập trang quản trị lưu trong DB để khởi động lại server vẫn còn đăng nhập.
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, expires INTEGER NOT NULL)`); err != nil {
		return nil, err
	}
	return &Store{db: db}, nil
}

// SessionStore: phiên đăng nhập trang quản trị, lưu trong SQLite. Mỗi lần dùng phiên còn hạn thì hạn được gia hạn
// thêm ttl kể từ lúc đó (hạn trượt), nên đăng nhập một lần rồi dùng đều là không bao giờ phải đăng nhập lại.
type SessionStore struct {
	db  *sql.DB
	ttl time.Duration
}

func (s *Store) Sessions(ttl time.Duration) *SessionStore { return &SessionStore{db: s.db, ttl: ttl} }

func (s *SessionStore) New() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	id := hex.EncodeToString(b)
	now := time.Now()
	s.db.Exec(`DELETE FROM sessions WHERE expires < ?`, now.Unix())
	s.db.Exec(`INSERT INTO sessions(id, expires) VALUES(?, ?)`, id, now.Add(s.ttl).Unix())
	return id
}

func (s *SessionStore) Valid(id string) bool {
	if len(id) != 64 {
		return false
	}
	var exp int64
	if err := s.db.QueryRow(`SELECT expires FROM sessions WHERE id = ?`, id).Scan(&exp); err != nil {
		return false
	}
	now := time.Now()
	if now.Unix() > exp {
		s.db.Exec(`DELETE FROM sessions WHERE id = ?`, id)
		return false
	}
	// Gia hạn khi đã dùng hết 1/4 hạn (không ghi DB mỗi lần tải trang).
	if time.Unix(exp, 0).Sub(now) < s.ttl-s.ttl/4 {
		s.db.Exec(`UPDATE sessions SET expires = ? WHERE id = ?`, now.Add(s.ttl).Unix(), id)
	}
	return true
}

func (s *SessionStore) Delete(id string) {
	s.db.Exec(`DELETE FROM sessions WHERE id = ?`, id)
}

const deviceCols = `hash, pub, name, email, user, model, platform, os, app_version, status, note, created, last_seen, last_ip, conflict`

func scanDevice(sc interface{ Scan(...any) error }) (*Device, error) {
	var d Device
	var created, seen, conflict int64
	if err := sc.Scan(&d.Hash, &d.Pub, &d.Name, &d.Email, &d.User, &d.Model, &d.Platform, &d.OS, &d.AppVersion,
		&d.Status, &d.Note, &created, &seen, &d.LastIP, &conflict); err != nil {
		return nil, err
	}
	d.Created, d.LastSeen = time.Unix(created, 0), time.Unix(seen, 0)
	if conflict > 0 {
		d.Conflict = time.Unix(conflict, 0)
	}
	return &d, nil
}

func (s *Store) Get(hash string) (*Device, error) {
	d, err := scanDevice(s.db.QueryRow(`SELECT `+deviceCols+` FROM devices WHERE hash = ?`, hash))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return d, err
}

func (s *Store) Insert(d *Device) error {
	_, err := s.db.Exec(`INSERT INTO devices(`+deviceCols+`) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)`,
		d.Hash, d.Pub, d.Name, d.Email, d.User, d.Model, d.Platform, d.OS, d.AppVersion, d.Status, d.Note,
		d.Created.Unix(), d.LastSeen.Unix(), d.LastIP)
	return err
}

// Seen cập nhật thông tin máy tự báo (tên máy, phiên bản…) và lần cuối thấy.
func (s *Store) Seen(d *Device) error {
	_, err := s.db.Exec(`UPDATE devices SET name=?, email=?, user=?, model=?, platform=?, os=?, app_version=?, last_seen=?, last_ip=? WHERE hash=?`,
		d.Name, d.Email, d.User, d.Model, d.Platform, d.OS, d.AppVersion, d.LastSeen.Unix(), d.LastIP, d.Hash)
	return err
}

func (s *Store) MarkConflict(hash string, at time.Time) error {
	_, err := s.db.Exec(`UPDATE devices SET conflict=? WHERE hash=?`, at.Unix(), hash)
	return err
}

func (s *Store) SetStatus(hash, status string) error {
	_, err := s.db.Exec(`UPDATE devices SET status=? WHERE hash=?`, status, hash)
	return err
}

func (s *Store) SetNote(hash, note string) error {
	_, err := s.db.Exec(`UPDATE devices SET note=? WHERE hash=?`, note, hash)
	return err
}

// ResetKey quên public key đã ghi: lần kết nối tới của máy sẽ ghi key mới (dùng khi máy cài lại hệ điều hành).
func (s *Store) ResetKey(hash string) error {
	_, err := s.db.Exec(`UPDATE devices SET pub='', conflict=0 WHERE hash=?`, hash)
	return err
}

func (s *Store) SetPub(hash, pub string) error {
	_, err := s.db.Exec(`UPDATE devices SET pub=?, conflict=0 WHERE hash=?`, pub, hash)
	return err
}

func (s *Store) Delete(hash string) error {
	_, err := s.db.Exec(`DELETE FROM devices WHERE hash=?`, hash)
	return err
}

// List trả danh sách máy, chờ duyệt lên đầu rồi tới mới thấy gần nhất. status rỗng = tất cả; q tìm trong tên, user, model, hash, ghi chú.
func (s *Store) List(status, q string) ([]*Device, error) {
	where, args := []string{"1=1"}, []any{}
	if status != "" {
		where = append(where, "status = ?")
		args = append(args, status)
	}
	if q = strings.TrimSpace(q); q != "" {
		like := "%" + strings.ToLower(q) + "%"
		where = append(where, "(lower(name) LIKE ? OR lower(email) LIKE ? OR lower(user) LIKE ? OR lower(model) LIKE ? OR lower(hash) LIKE ? OR lower(note) LIKE ?)")
		args = append(args, like, like, like, like, like, like)
	}
	rows, err := s.db.Query(`SELECT `+deviceCols+` FROM devices WHERE `+strings.Join(where, " AND ")+
		` ORDER BY status = 'pending' DESC, last_seen DESC`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Device
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Store) Counts() (map[string]int, error) {
	rows, err := s.db.Query(`SELECT status, COUNT(*) FROM devices GROUP BY status`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var st string
		var n int
		if err := rows.Scan(&st, &n); err != nil {
			return nil, err
		}
		out[st] = n
	}
	return out, rows.Err()
}
