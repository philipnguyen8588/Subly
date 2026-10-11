package main

import (
	"path/filepath"
	"testing"
	"time"
)

// Phiên quản trị phải còn sau khi mở lại DB (tương đương khởi động lại server) và sau khi hết hạn thì mất.
func TestSessionSurvivesRestart(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "devices.db")
	st, err := openStore(p)
	if err != nil {
		t.Fatal(err)
	}
	id := st.Sessions(time.Hour).New()
	if !st.Sessions(time.Hour).Valid(id) {
		t.Fatal("phiên vừa tạo phải hợp lệ")
	}
	st.db.Close()

	st2, err := openStore(p)
	if err != nil {
		t.Fatal(err)
	}
	ss := st2.Sessions(time.Hour)
	if !ss.Valid(id) {
		t.Fatal("phiên phải còn sau khi mở lại DB")
	}
	if ss.Valid("x") || ss.Valid("") {
		t.Fatal("id lạ không được hợp lệ")
	}
	ss.Delete(id)
	if ss.Valid(id) {
		t.Fatal("đã đăng xuất mà vẫn hợp lệ")
	}

	// Hết hạn: ttl âm thì expires nằm trong quá khứ.
	old := st2.Sessions(-time.Minute).New()
	if ss.Valid(old) {
		t.Fatal("phiên hết hạn vẫn hợp lệ")
	}
}
