package main

import (
	_ "embed"
	"log"
	"net/http"
	"slices"
	"strconv"
	"strings"
)

//go:embed admin.js
var adminJS []byte

// serveAdminJS: nút Copy token (CSP của trang quản trị chỉ cho chạy script từ chính server).
func serveAdminJS(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.Write(adminJS)
}

type modelOption struct {
	Name    string
	Checked bool
}

// shareDraft: form thêm / sửa share đang nhập dở (giữ lại khi bấm "Tải model" hoặc khi lưu bị lỗi).
type shareDraft struct {
	ID       string // rỗng = thêm mới
	Label    string
	Provider string
	BaseURL  string
	Key      string // key vừa gõ; khi sửa, rỗng = giữ key cũ
	HasKey   bool   // đang sửa share đã có key
	Options  []modelOption
	Extra    string
	Error    string
	Info     string
}

type shareView struct {
	*Share
	MaskedKey    string
	ProviderName string
}

func draftFromShare(sh *Share) *shareDraft {
	d := &shareDraft{ID: sh.ID, Label: sh.Label, Provider: sh.Provider, BaseURL: sh.BaseURL, HasKey: true}
	for _, m := range sh.Models {
		d.Options = append(d.Options, modelOption{Name: m, Checked: true})
	}
	return d
}

// renderShares hiện tab AI share, kèm form đang nhập dở (nếu có).
func (a *App) renderShares(w http.ResponseWriter, draft *shareDraft) {
	list, err := a.shares.List()
	if err != nil {
		log.Printf("shares: %v", err)
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	views := make([]shareView, len(list))
	for i, sh := range list {
		views[i] = shareView{Share: sh, MaskedKey: maskKey(sh.Key), ProviderName: providerNames[sh.Provider]}
	}
	if draft == nil {
		draft = &shareDraft{Provider: "openai"}
	}
	counts, _ := a.store.Counts()
	a.render(w, adminPage{LoggedIn: true, Tab: "ai", Shares: views, Draft: draft, Counts: counts})
}

// handleShareAction: thêm / sửa / tải model / tạo token mới / thu hồi / bật lại / xoá một AI share.
func (a *App) handleShareAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !sameOrigin(r) || !a.loggedIn(r) {
		http.Redirect(w, r, "/admin", http.StatusSeeOther)
		return
	}
	id, act := r.FormValue("id"), r.FormValue("action")
	var existing *Share
	if id != "" {
		sh, err := a.shares.Get(id)
		if err != nil || sh == nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		existing = sh
	}

	switch act {
	case "load", "save":
		a.saveShare(w, r, existing, act == "load")
		return
	case "rotate", "revoke", "enable", "delete":
		if existing == nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		var err error
		switch act {
		case "rotate":
			err = a.shares.Rotate(id)
		case "revoke":
			err = a.shares.SetStatus(id, shareRevoked)
		case "enable":
			err = a.shares.SetStatus(id, shareActive)
		case "delete":
			err = a.shares.Delete(id)
		}
		if err != nil {
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		log.Printf("admin share %s %s (%s)", act, id, existing.Label)
	default:
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/admin?tab=ai#s-"+id, http.StatusSeeOther)
}

// saveShare đọc form; load = chỉ tải danh sách model bằng key rồi hiện lại form, ngược lại thì lưu.
func (a *App) saveShare(w http.ResponseWriter, r *http.Request, existing *Share, load bool) {
	_ = r.ParseForm()
	d := &shareDraft{
		Label: clip(r.FormValue("label"), 80), Provider: r.FormValue("provider"),
		BaseURL: strings.TrimSpace(r.FormValue("base_url")), Key: strings.TrimSpace(r.FormValue("key")),
		Extra: r.FormValue("extra"),
	}
	if existing != nil {
		d.ID, d.HasKey = existing.ID, true
	}
	checked := r.Form["model"]
	for _, m := range r.Form["option"] {
		d.Options = append(d.Options, modelOption{Name: m, Checked: slices.Contains(checked, m)})
	}
	fail := func(msg string) {
		d.Error = msg
		a.renderShares(w, d)
	}

	if _, ok := providers[d.Provider]; !ok {
		fail("Chọn nhà cung cấp.")
		return
	}
	sh := &Share{Label: d.Label, Provider: d.Provider, Key: d.Key}
	if existing != nil && sh.Key == "" {
		sh.Key = existing.Key
	}
	if d.Provider == "custom" {
		u, err := normalizeBaseURL(d.BaseURL)
		if err != nil {
			fail(err.Error())
			return
		}
		sh.BaseURL, d.BaseURL = u, u
	} else {
		d.BaseURL = ""
	}
	if sh.Key == "" && d.Provider != "custom" {
		fail("Nhập API key.")
		return
	}
	if len(sh.Key) > 400 {
		fail("Key quá dài.")
		return
	}

	if load {
		ids, err := a.fetchModels(r.Context(), sh)
		if err != nil {
			fail("Không tải được model: " + err.Error())
			return
		}
		prev := map[string]bool{}
		for _, o := range d.Options {
			prev[o.Name] = o.Checked
		}
		d.Options = nil
		for _, m := range ids {
			d.Options = append(d.Options, modelOption{Name: m, Checked: prev[m]})
		}
		// Model đã tick trước đó nhưng không có trong danh sách mới vẫn giữ lại.
		for _, m := range checked {
			if !slices.Contains(ids, m) {
				d.Options = append([]modelOption{{Name: m, Checked: true}}, d.Options...)
			}
		}
		d.Info = "Key dùng được, có " + strconv.Itoa(len(ids)) + " model. Tick những model muốn share."
		a.renderShares(w, d)
		return
	}

	sh.Models = parseModels(checked, d.Extra)
	if len(sh.Models) == 0 {
		fail("Chọn ít nhất một model.")
		return
	}
	if len(sh.Models) > maxModels {
		fail("Tối đa " + strconv.Itoa(maxModels) + " model.")
		return
	}
	if sh.Label == "" {
		sh.Label = providerNames[sh.Provider]
	}
	var err error
	if existing != nil {
		sh.ID = existing.ID
		err = a.shares.Update(sh)
	} else {
		err = a.shares.Insert(sh, a.now())
	}
	if err != nil {
		log.Printf("share save: %v", err)
		fail("Lỗi lưu: " + err.Error())
		return
	}
	log.Printf("admin share save %s (%s, %s, %d model)", sh.ID, sh.Label, sh.Provider, len(sh.Models))
	http.Redirect(w, r, "/admin?tab=ai#s-"+sh.ID, http.StatusSeeOther)
}
