package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
)

// Ô thuật ngữ trên trang quản trị dùng dạng chữ quen thuộc: dòng "# Nhóm" mở một nhóm, mỗi dòng
// "thuật ngữ,bản dịch" (bỏ phần sau dấu phẩy = giữ nguyên thuật ngữ).
func glossaryText(groups []GameGroup) string {
	var b strings.Builder
	for i, g := range groups {
		if i > 0 {
			b.WriteByte('\n')
		}
		if g.Group != "" {
			b.WriteString("# " + g.Group + "\n")
		}
		for _, e := range g.Entries {
			b.WriteString(e.Term)
			if e.Translation != "" {
				b.WriteString("," + e.Translation)
			}
			b.WriteByte('\n')
		}
	}
	return b.String()
}

func parseGlossaryText(text string) []GameGroup {
	var groups []GameGroup
	cur := -1
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "#") {
			groups = append(groups, GameGroup{Group: strings.TrimSpace(strings.TrimLeft(line, "#"))})
			cur = len(groups) - 1
			continue
		}
		term, tr, _ := strings.Cut(line, ",")
		if cur < 0 {
			groups = append(groups, GameGroup{})
			cur = 0
		}
		groups[cur].Entries = append(groups[cur].Entries, GameTerm{Term: strings.TrimSpace(term), Translation: strings.TrimSpace(tr)})
	}
	return groups
}

func splitList(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == '\n' || r == '\r' })
}

// gameDraft: form thêm / sửa game đang nhập dở (giữ lại khi lưu bị lỗi).
type gameDraft struct {
	OrigID            string // rỗng = thêm mới
	ID                string
	Name              string
	Aliases           string
	Style             string
	Description       string
	Note              string
	ShowsSpeakerNames bool
	SpeakerAbove      bool
	Speakers          string
	Glossary          string
	Error             string
}

func draftFromGame(g *Game) *gameDraft {
	return &gameDraft{OrigID: g.ID, ID: g.ID, Name: g.Name, Aliases: strings.Join(g.Aliases, ", "), Style: g.Style,
		Description: g.Description, Note: g.Note, ShowsSpeakerNames: g.ShowsSpeakerNames, SpeakerAbove: g.SpeakerAbove,
		Speakers: strings.Join(g.Speakers, ", "), Glossary: glossaryText(g.Glossary)}
}

type styleOption struct{ Value, Label string }

type gameView struct {
	*Game
	StyleLabel string
	TermCount  int
}

// renderGames hiện tab Game mẫu; draft != nil thì mở form thêm / sửa.
func (a *App) renderGames(w http.ResponseWriter, draft *gameDraft, notice string) {
	games, err := a.store.Games()
	if err != nil {
		log.Printf("games: %v", err)
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	views := make([]gameView, len(games))
	for i, g := range games {
		views[i] = gameView{Game: g, StyleLabel: styleLabels[g.Style], TermCount: g.Terms()}
	}
	counts, _ := a.store.Counts()
	a.render(w, adminPage{LoggedIn: true, Tab: "games", Games: views, GameDraft: draft, Notice: notice, Counts: counts})
}

func styleOptions() []styleOption {
	out := make([]styleOption, len(gameStyles))
	for i, s := range gameStyles {
		out[i] = styleOption{s, styleLabels[s]}
	}
	return out
}

// handleGameAction: lưu / xoá / nhập file JSON cho game mẫu.
func (a *App) handleGameAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !sameOrigin(r) || !a.loggedIn(r) {
		http.Redirect(w, r, "/admin", http.StatusSeeOther)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8<<20)
	if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/") {
		if err := r.ParseMultipartForm(8 << 20); err != nil {
			a.renderGames(w, nil, "Lỗi: file quá lớn hoặc hỏng")
			return
		}
	}
	switch r.FormValue("action") {
	case "save":
		a.saveGame(w, r)
	case "delete":
		id := r.FormValue("id")
		if err := a.store.DeleteGame(id); err != nil {
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		log.Printf("admin game delete %s", id)
		http.Redirect(w, r, "/admin?tab=games", http.StatusSeeOther)
	case "import":
		a.importGames(w, r)
	default:
		http.Error(w, "bad request", http.StatusBadRequest)
	}
}

func (a *App) saveGame(w http.ResponseWriter, r *http.Request) {
	d := &gameDraft{
		OrigID: r.FormValue("orig_id"), ID: strings.TrimSpace(r.FormValue("id")), Name: r.FormValue("name"),
		Aliases: r.FormValue("aliases"), Style: r.FormValue("style"), Description: r.FormValue("description"),
		Note: r.FormValue("note"), ShowsSpeakerNames: r.FormValue("shows_speaker_names") == "1",
		SpeakerAbove: r.FormValue("speaker_above") == "1", Speakers: r.FormValue("speakers"), Glossary: r.FormValue("glossary"),
	}
	g := &Game{ID: d.ID, Name: d.Name, Aliases: splitList(d.Aliases), Style: d.Style, Description: d.Description, Note: d.Note,
		ShowsSpeakerNames: d.ShowsSpeakerNames, SpeakerAbove: d.SpeakerAbove, Speakers: splitList(d.Speakers),
		Glossary: parseGlossaryText(d.Glossary)}
	if d.OrigID != "" {
		g.ID = d.OrigID // id cố định sau khi tạo (app nhận ra game theo id)
	}
	fail := func(msg string) {
		d.Error = msg
		a.renderGames(w, d, "")
	}
	if err := g.normalize(); err != nil {
		fail(err.Error())
		return
	}
	if d.OrigID == "" {
		if old, _ := a.store.Game(g.ID); old != nil {
			fail("Đã có game với id “" + g.ID + "”. Đổi id hoặc sửa game đó.")
			return
		}
	}
	if err := a.store.PutGame(g, a.now()); err != nil {
		fail("Lỗi lưu: " + err.Error())
		return
	}
	log.Printf("admin game save %s (%s, %s, %d thuật ngữ)", g.ID, g.Name, g.Style, g.Terms())
	http.Redirect(w, r, "/admin?tab=games#g-"+g.ID, http.StatusSeeOther)
}

// importGames: tải lên một hoặc nhiều file .json (game có id trùng thì được thay).
func (a *App) importGames(w http.ResponseWriter, r *http.Request) {
	if r.MultipartForm == nil || len(r.MultipartForm.File["files"]) == 0 {
		a.renderGames(w, nil, "Lỗi: chưa chọn file")
		return
	}
	n := 0
	var errs []string
	for _, fh := range r.MultipartForm.File["files"] {
		f, err := fh.Open()
		if err != nil {
			errs = append(errs, fh.Filename+": "+err.Error())
			continue
		}
		data, _ := io.ReadAll(io.LimitReader(f, 4<<20))
		f.Close()
		games, err := parseGames(data)
		if err != nil {
			errs = append(errs, fh.Filename+": "+err.Error())
			continue
		}
		for _, g := range games {
			if err := a.store.PutGame(g, a.now()); err != nil {
				errs = append(errs, g.Name+": "+err.Error())
				continue
			}
			n++
		}
	}
	log.Printf("admin game import: %d game, %d lỗi", n, len(errs))
	msg := "Đã nhập " + strconv.Itoa(n) + " game."
	if len(errs) > 0 {
		msg += " Lỗi: " + strings.Join(errs, "; ")
	}
	a.renderGames(w, nil, msg)
}

// handleGameExport: GET /admin/games/export[?id=…] tải file JSON của một game hoặc của cả danh sách.
func (a *App) handleGameExport(w http.ResponseWriter, r *http.Request) {
	if !a.loggedIn(r) {
		http.Redirect(w, r, "/admin", http.StatusSeeOther)
		return
	}
	var v any
	name := "games.json"
	if id := r.URL.Query().Get("id"); id != "" {
		g, err := a.store.Game(id)
		if err != nil || g == nil {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		g.Updated = 0
		v, name = g, id+".json"
	} else {
		games, err := a.store.Games()
		if err != nil {
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		for _, g := range games {
			g.Updated = 0
		}
		v = games
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}
