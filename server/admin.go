package main

import (
	"crypto/subtle"
	_ "embed"
	"html/template"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

//go:embed admin.html
var adminHTML string

var adminTmpl = template.Must(template.New("admin").Funcs(template.FuncMap{
	"short": short,
	"ago": func(t time.Time) string {
		if t.IsZero() {
			return ""
		}
		d := time.Since(t)
		switch {
		case d < time.Minute:
			return "vừa xong"
		case d < time.Hour:
			return strconv.Itoa(int(d.Minutes())) + " phút trước"
		case d < 48*time.Hour:
			return strconv.Itoa(int(d.Hours())) + " giờ trước"
		default:
			return strconv.Itoa(int(d.Hours()/24)) + " ngày trước"
		}
	},
	"date": func(t time.Time) string { return t.Local().Format("2006-01-02 15:04") },
}).Parse(adminHTML))

const cookieName = "sid"

func (a *App) loggedIn(r *http.Request) bool {
	c, err := r.Cookie(cookieName)
	return err == nil && a.sessions.Valid(c.Value)
}

// sameOrigin chặn CSRF: yêu cầu POST phải đến từ chính trang này.
func sameOrigin(r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" {
		o = r.Header.Get("Referer")
	}
	if o == "" {
		return false
	}
	u, err := url.Parse(o)
	if err != nil {
		return false
	}
	if h := os.Getenv("PUBLIC_HOST"); h != "" {
		return u.Host == h
	}
	return u.Host == r.Host
}

type adminPage struct {
	LoggedIn bool
	Error    string
	Devices  []*Device
	Counts   map[string]int
	Status   string
	Q        string
	TTLDays  int
}

func (a *App) render(w http.ResponseWriter, p adminPage) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
	p.TTLDays = int(a.ticketTTL.Hours() / 24)
	if err := adminTmpl.Execute(w, p); err != nil {
		log.Printf("template: %v", err)
	}
}

func (a *App) handleAdmin(w http.ResponseWriter, r *http.Request) {
	if !a.loggedIn(r) {
		a.render(w, adminPage{})
		return
	}
	status, q := r.URL.Query().Get("status"), r.URL.Query().Get("q")
	switch status {
	case statusPending, statusApproved, statusRevoked:
	default:
		status = ""
	}
	devs, err := a.store.List(status, q)
	if err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	counts, _ := a.store.Counts()
	a.render(w, adminPage{LoggedIn: true, Devices: devs, Counts: counts, Status: status, Q: q})
}

func (a *App) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !sameOrigin(r) {
		http.Redirect(w, r, "/admin", http.StatusSeeOther)
		return
	}
	ip := a.clientIP(r)
	if !a.loginLimit.Allow(ip) {
		a.render(w, adminPage{Error: "Sai quá nhiều lần, thử lại sau 15 phút."})
		return
	}
	if subtle.ConstantTimeCompare([]byte(r.FormValue("password")), []byte(a.adminPass)) != 1 {
		log.Printf("admin login failed from %s", ip)
		a.render(w, adminPage{Error: "Sai mật khẩu."})
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name: cookieName, Value: a.sessions.New(), Path: "/admin", HttpOnly: true,
		Secure: a.secureCookie, SameSite: http.SameSiteLaxMode, MaxAge: int(12 * time.Hour / time.Second),
	})
	log.Printf("admin login from %s", ip)
	http.Redirect(w, r, "/admin", http.StatusSeeOther)
}

func (a *App) handleLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost && sameOrigin(r) {
		if c, err := r.Cookie(cookieName); err == nil {
			a.sessions.Delete(c.Value)
		}
		http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/admin", MaxAge: -1})
	}
	http.Redirect(w, r, "/admin", http.StatusSeeOther)
}

// handleDeviceAction: duyệt / thu hồi / ghi chú / cho ghi key mới / xoá một máy.
func (a *App) handleDeviceAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !sameOrigin(r) || !a.loggedIn(r) {
		http.Redirect(w, r, "/admin", http.StatusSeeOther)
		return
	}
	hash := r.FormValue("hash")
	if !validHash(hash) {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	var err error
	switch act := r.FormValue("action"); act {
	case "approve":
		err = a.store.SetStatus(hash, statusApproved)
	case "revoke":
		err = a.store.SetStatus(hash, statusRevoked)
	case "pending":
		err = a.store.SetStatus(hash, statusPending)
	case "note":
		err = a.store.SetNote(hash, clip(r.FormValue("note"), 200))
	case "resetkey":
		err = a.store.ResetKey(hash)
	case "delete":
		err = a.store.Delete(hash)
	default:
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if err != nil {
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	log.Printf("admin %s %s", r.FormValue("action"), short(hash))
	back := "/admin"
	if ref, err := url.Parse(r.Referer()); err == nil && strings.HasPrefix(ref.Path, "/admin") {
		back = ref.RequestURI()
	}
	http.Redirect(w, r, back, http.StatusSeeOther)
}
