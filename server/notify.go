package main

import (
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// notifyNewDevice: báo qua Telegram khi có máy mới chờ duyệt (chỉ khi đã đặt TELEGRAM_TOKEN và TELEGRAM_CHAT_ID).
func (a *App) notifyNewDevice(d *Device) {
	if a.tgToken == "" || a.tgChat == "" {
		return
	}
	platform := map[string]string{"mac": "macOS", "win": "Windows"}[d.Platform]
	text := "Máy mới chờ duyệt: " + d.Name + "\n" + (func() string {
		if d.Email != "" {
			return "✉ " + d.Email + "\n"
		}
		return ""
	}()) + strings.Join([]string{d.User, d.Model, platform + " " + d.OS}, " · ") +
		"\n" + short(d.Hash) + " · IP " + d.LastIP
	go func() {
		c := http.Client{Timeout: 10 * time.Second}
		resp, err := c.PostForm("https://api.telegram.org/bot"+a.tgToken+"/sendMessage",
			url.Values{"chat_id": {a.tgChat}, "text": {text}})
		if err != nil {
			log.Printf("telegram: %v", err)
			return
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			log.Printf("telegram: HTTP %d", resp.StatusCode)
		}
	}()
}
