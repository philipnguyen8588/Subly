package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

var b64 = base64.RawURLEncoding

// sessionRequest: máy gửi lên mỗi lần mở app và định kỳ. Tên trường ngắn và trung tính.
type sessionRequest struct {
	Hash     string `json:"h"`  // SHA-256 (hex) của id phần cứng
	Pub      string `json:"k"`  // public key Ed25519 của máy (base64url)
	Name     string `json:"n"`  // tên máy
	Email    string `json:"e"`  // email user tự nhập (để chủ app nhận ra ai)
	User     string `json:"u"`  // tài khoản đăng nhập
	Model    string `json:"m"`  // model máy
	Platform string `json:"p"`  // mac | win
	OS       string `json:"o"`  // phiên bản hệ điều hành
	Version  string `json:"v"`  // phiên bản app
	TS       int64  `json:"ts"` // unix giây
	Sig      string `json:"s"`  // Ed25519(device key, "s1|h|k|ts"), base64url
}

// sessionResponse: c = 0 kèm vé khi máy đã được duyệt; mọi trường hợp khác (chờ duyệt, thu hồi, sai chữ ký…) đều là
// c = 1 không kèm gì, để client không phân biệt được lý do.
type sessionResponse struct {
	C int    `json:"c"`
	T string `json:"t,omitempty"`
}

const clockSkew = 5 * time.Minute

func (a *App) handleSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	ip := a.clientIP(r)
	if !a.apiLimit.Allow(ip) {
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}
	deny := func(reason string, req *sessionRequest) {
		if req != nil {
			log.Printf("session %s from %s (%s): %s", short(req.Hash), ip, req.Name, reason)
		} else {
			log.Printf("session from %s: %s", ip, reason)
		}
		writeJSON(w, sessionResponse{C: 1})
	}

	var req sessionRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil {
		deny("bad json", nil)
		return
	}
	if !validHash(req.Hash) {
		deny("bad hash", &req)
		return
	}
	pub, err := b64.DecodeString(req.Pub)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		deny("bad key", &req)
		return
	}
	sig, err := b64.DecodeString(req.Sig)
	if err != nil || !ed25519.Verify(pub, []byte(signedMessage(req.Hash, req.Pub, req.TS)), sig) {
		deny("bad signature", &req)
		return
	}
	now := a.now()
	if d := now.Sub(time.Unix(req.TS, 0)); d > clockSkew || d < -clockSkew {
		deny("clock skew "+d.Round(time.Second).String(), &req)
		return
	}

	info := &Device{
		Hash: req.Hash, Pub: req.Pub, Name: clip(req.Name, 80), Email: clip(req.Email, 120), User: clip(req.User, 80), Model: clip(req.Model, 80),
		Platform: clip(req.Platform, 10), OS: clip(req.OS, 80), AppVersion: clip(req.Version, 30),
		LastSeen: now, LastIP: ip,
	}
	d, err := a.store.Get(req.Hash)
	if err != nil {
		log.Printf("db: %v", err)
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	if d == nil {
		info.Status, info.Created = statusPending, now
		if err := a.store.Insert(info); err != nil {
			log.Printf("db insert: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		log.Printf("new device %s: %s / %s / %s (%s) from %s", short(req.Hash), info.Name, info.User, info.Model, info.Platform, ip)
		a.notifyNewDevice(info)
		writeJSON(w, sessionResponse{C: 1})
		return
	}
	// Máy đã có: public key phải khớp key đã ghi lần đầu (rỗng = chủ app vừa cho phép ghi key mới).
	if d.Pub == "" {
		_ = a.store.SetPub(d.Hash, req.Pub)
	} else if d.Pub != req.Pub {
		_ = a.store.MarkConflict(d.Hash, now)
		deny("public key mismatch", &req)
		return
	}
	_ = a.store.Seen(info)
	if d.Status != statusApproved {
		deny("status "+d.Status, &req)
		return
	}
	writeJSON(w, sessionResponse{C: 0, T: a.issueTicket(req.Hash, req.Pub, now)})
}

func signedMessage(hash, pub string, ts int64) string {
	return "s1|" + hash + "|" + pub + "|" + strconv.FormatInt(ts, 10)
}

// issueTicket: "v1|hash|pub|iat|exp" và chữ ký của server, ghép thành base64url(payload) + "." + base64url(sig).
func (a *App) issueTicket(hash, pub string, now time.Time) string {
	payload := fmt.Sprintf("v1|%s|%s|%d|%d", hash, pub, now.Unix(), now.Add(a.ticketTTL).Unix())
	sig := ed25519.Sign(a.key, []byte(payload))
	return b64.EncodeToString([]byte(payload)) + "." + b64.EncodeToString(sig)
}

func validHash(h string) bool {
	if len(h) != 64 {
		return false
	}
	_, err := hex.DecodeString(h)
	return err == nil && strings.ToLower(h) == h
}

func clip(s string, n int) string {
	s = strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s))
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}

func short(h string) string {
	if len(h) >= 8 {
		return strings.ToUpper(h[:4] + "-" + h[4:8])
	}
	return h
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(v)
}
