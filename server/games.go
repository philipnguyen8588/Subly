package main

// Game mẫu: danh sách game kèm thuật ngữ, phong cách dịch và cài đặt tên người nói mà app dùng để tạo nhanh một game.
// Lưu trong DB, sửa trên trang quản trị (tab Game mẫu); app tải về qua GET /v1/games nên thêm / sửa game không cần
// build lại app. Định dạng giống file glossaries/*.json đóng kèm app (bản dự phòng khi chưa tải được).

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"
)

type GameTerm struct {
	Term        string `json:"term"`
	Translation string `json:"translation,omitempty"`
}

type GameGroup struct {
	Group   string     `json:"group"`
	Entries []GameTerm `json:"entries"`
}

type Game struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Aliases     []string `json:"aliases"`
	Style       string   `json:"style"`
	Description string   `json:"description"`
	// Ghi chú cho AI dịch (gửi kèm mỗi câu), như ô "Ghi chú cho AI dịch" của một game trong app.
	Note              string      `json:"note"`
	ShowsSpeakerNames bool        `json:"showsSpeakerNames"`
	SpeakerAbove      bool        `json:"speakerAbove"`
	Speakers          []string    `json:"speakers"`
	Glossary          []GameGroup `json:"glossary"`
	Updated           int64       `json:"updated,omitempty"`
}

// Phong cách dịch, trùng tên với enum TranslationStyle của app.
var gameStyles = []string{"auto", "modern", "fantasy", "myth", "eastern"}

var styleLabels = map[string]string{
	"auto":    "Tự động theo tên game",
	"modern":  "Hiện đại / đường phố",
	"fantasy": "Kỳ ảo trung cổ",
	"myth":    "Thần thoại sử thi",
	"eastern": "Cổ trang Á Đông",
}

const maxGameTerms = 3000

var gameIDRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)

func (g *Game) Terms() int {
	n := 0
	for _, gr := range g.Glossary {
		n += len(gr.Entries)
	}
	return n
}

// slugify: "Ghost of Yōtei" → "ghost-of-yotei" (bỏ dấu các chữ hay gặp, ký tự khác thành "-").
func slugify(name string) string {
	fold := map[rune]string{'ō': "o", 'ö': "o", 'ó': "o", 'ò': "o", 'ô': "o", 'é': "e", 'è': "e", 'ê': "e", 'ë': "e",
		'á': "a", 'à': "a", 'â': "a", 'ä': "a", 'ã': "a", 'í': "i", 'ï': "i", 'ú': "u", 'ü': "u", 'û': "u", 'ñ': "n", 'ç': "c", 'ß': "ss", 'đ': "d"}
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z' || r >= '0' && r <= '9':
			b.WriteRune(r)
			dash = false
		case fold[r] != "":
			b.WriteString(fold[r])
			dash = false
		default:
			if !dash && b.Len() > 0 {
				b.WriteByte('-')
				dash = true
			}
		}
	}
	s := strings.Trim(b.String(), "-")
	if len(s) > 64 {
		s = strings.Trim(s[:64], "-")
	}
	return s
}

// normalize kiểm tra và làm gọn một game (tên, id, phong cách, bỏ thuật ngữ trùng / rỗng).
func (g *Game) normalize() error {
	g.Name = clip(g.Name, 120)
	if g.Name == "" {
		return errors.New("thiếu tên game")
	}
	g.ID = strings.TrimSpace(g.ID)
	if g.ID == "" {
		g.ID = slugify(g.Name)
	}
	if !gameIDRe.MatchString(g.ID) {
		return fmt.Errorf("id %q không hợp lệ (chỉ chữ thường không dấu, số và dấu gạch ngang)", g.ID)
	}
	if g.Style == "" {
		g.Style = "auto"
	}
	if !slices.Contains(gameStyles, g.Style) {
		return fmt.Errorf("phong cách %q không hợp lệ (%s)", g.Style, strings.Join(gameStyles, ", "))
	}
	g.Description = clip(g.Description, 1000)
	g.Note = strings.TrimSpace(g.Note)
	if len([]rune(g.Note)) > 2000 {
		return errors.New("ghi chú quá dài (tối đa 2000 ký tự)")
	}
	g.Aliases = cleanList(g.Aliases, 100, 20)
	g.Speakers = cleanList(g.Speakers, 80, 300)
	seen := map[string]bool{}
	var groups []GameGroup
	for _, gr := range g.Glossary {
		out := GameGroup{Group: clip(gr.Group, 100)}
		for _, e := range gr.Entries {
			t := GameTerm{Term: clip(e.Term, 100), Translation: clip(e.Translation, 200)}
			k := strings.ToLower(t.Term)
			if t.Term == "" || seen[k] {
				continue
			}
			seen[k] = true
			out.Entries = append(out.Entries, t)
		}
		if len(out.Entries) > 0 {
			groups = append(groups, out)
		}
	}
	g.Glossary = groups
	if g.Terms() > maxGameTerms {
		return fmt.Errorf("quá nhiều thuật ngữ (%d, tối đa %d)", g.Terms(), maxGameTerms)
	}
	return nil
}

func cleanList(in []string, maxLen, maxItems int) []string {
	out := []string{}
	for _, s := range in {
		s = clip(s, maxLen)
		if s != "" && !slices.Contains(out, s) && len(out) < maxItems {
			out = append(out, s)
		}
	}
	return out
}

// parseGames đọc một file JSON: một game, một mảng game, hoặc {"games": [...]} (như GET /v1/games trả về).
func parseGames(data []byte) ([]*Game, error) {
	data = []byte(strings.TrimSpace(string(data)))
	newGame := func() *Game { return &Game{ShowsSpeakerNames: true} }
	var raws []json.RawMessage
	switch {
	case len(data) > 0 && data[0] == '[':
		if err := json.Unmarshal(data, &raws); err != nil {
			return nil, err
		}
	default:
		var wrap struct {
			Games []json.RawMessage `json:"games"`
		}
		if err := json.Unmarshal(data, &wrap); err == nil && wrap.Games != nil {
			raws = wrap.Games
		} else {
			raws = []json.RawMessage{data}
		}
	}
	var out []*Game
	for _, r := range raws {
		g := newGame()
		if err := json.Unmarshal(r, g); err != nil {
			return nil, err
		}
		if err := g.normalize(); err != nil {
			return nil, fmt.Errorf("%s: %w", g.Name, err)
		}
		out = append(out, g)
	}
	return out, nil
}

// --- Lưu trữ ---

const gamesTable = `CREATE TABLE IF NOT EXISTS games(id TEXT PRIMARY KEY, name TEXT NOT NULL, data TEXT NOT NULL, updated INTEGER NOT NULL)`

func (s *Store) Games() ([]*Game, error) {
	rows, err := s.db.Query(`SELECT data, updated FROM games ORDER BY name COLLATE NOCASE`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Game
	for rows.Next() {
		var data string
		var upd int64
		if err := rows.Scan(&data, &upd); err != nil {
			return nil, err
		}
		g := &Game{ShowsSpeakerNames: true}
		if err := json.Unmarshal([]byte(data), g); err != nil {
			return nil, err
		}
		g.Updated = upd
		out = append(out, g)
	}
	return out, rows.Err()
}

func (s *Store) Game(id string) (*Game, error) {
	var data string
	var upd int64
	err := s.db.QueryRow(`SELECT data, updated FROM games WHERE id = ?`, id).Scan(&data, &upd)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	g := &Game{ShowsSpeakerNames: true}
	if err := json.Unmarshal([]byte(data), g); err != nil {
		return nil, err
	}
	g.Updated = upd
	return g, nil
}

// PutGame thêm hoặc thay game cùng id.
func (s *Store) PutGame(g *Game, now time.Time) error {
	g.Updated = 0
	data, err := json.Marshal(g)
	if err != nil {
		return err
	}
	g.Updated = now.Unix()
	_, err = s.db.Exec(`INSERT INTO games(id, name, data, updated) VALUES(?,?,?,?)
		ON CONFLICT(id) DO UPDATE SET name=excluded.name, data=excluded.data, updated=excluded.updated`,
		g.ID, g.Name, string(data), g.Updated)
	return err
}

func (s *Store) DeleteGame(id string) error {
	_, err := s.db.Exec(`DELETE FROM games WHERE id = ?`, id)
	return err
}

// GamesVersion đổi mỗi khi thêm, sửa hoặc xoá game (dùng làm ETag cho app).
func (s *Store) GamesVersion() (string, error) {
	var n, max, sum int64
	err := s.db.QueryRow(`SELECT COUNT(*), COALESCE(MAX(updated), 0), COALESCE(SUM(updated), 0) FROM games`).Scan(&n, &max, &sum)
	return fmt.Sprintf("%d-%d-%d", n, max, sum%1000003), err
}

// --- API cho app ---

// handleGames: GET /v1/games → {"version", "games": [...]}; app gửi If-None-Match để khỏi tải lại khi không đổi.
func (a *App) handleGames(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if !a.apiLimit.Allow(a.clientIP(r)) {
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}
	ver, err := a.store.GamesVersion()
	if err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	etag := `"` + ver + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "no-cache")
	// Cloudflare nén response và đổi ETag sang dạng yếu (W/"…"), app gửi lại đúng dạng đó.
	if strings.TrimPrefix(r.Header.Get("If-None-Match"), "W/") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	games, err := a.store.Games()
	if err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	if games == nil {
		games = []*Game{}
	}
	writeJSON(w, map[string]any{"version": ver, "games": games})
}

// importGamesDir nạp mọi file *.json trong thư mục (lệnh `subly-server import-games <thư mục>`).
func importGamesDir(st *Store, dir string) (int, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return 0, err
	}
	n := 0
	now := time.Now()
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			return n, err
		}
		games, err := parseGames(data)
		if err != nil {
			return n, fmt.Errorf("%s: %w", filepath.Base(f), err)
		}
		for _, g := range games {
			if err := st.PutGame(g, now); err != nil {
				return n, err
			}
			n++
		}
	}
	return n, nil
}
