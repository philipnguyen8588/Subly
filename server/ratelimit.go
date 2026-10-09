package main

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"
)

// RateLimiter: tối đa n lần trong mỗi cửa sổ thời gian cho mỗi khoá (IP). Đủ dùng cho một server nhỏ.
type RateLimiter struct {
	mu     sync.Mutex
	n      int
	window time.Duration
	hits   map[string][]time.Time
	now    func() time.Time
}

func NewRateLimiter(n int, window time.Duration) *RateLimiter {
	return &RateLimiter{n: n, window: window, hits: map[string][]time.Time{}, now: time.Now}
}

func (l *RateLimiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	cut := now.Add(-l.window)
	h := l.hits[key]
	i := 0
	for i < len(h) && h[i].Before(cut) {
		i++
	}
	h = h[i:]
	if len(h) >= l.n {
		l.hits[key] = h
		return false
	}
	l.hits[key] = append(h, now)
	if len(l.hits) > 10000 { // dọn các IP đã lâu không gọi
		for k, v := range l.hits {
			if len(v) == 0 || v[len(v)-1].Before(cut) {
				delete(l.hits, k)
			}
		}
	}
	return true
}

// SessionStore: phiên đăng nhập trang quản trị, giữ trong bộ nhớ (khởi động lại server thì đăng nhập lại).
type SessionStore struct {
	mu  sync.Mutex
	ttl time.Duration
	m   map[string]time.Time
}

func NewSessionStore(ttl time.Duration) *SessionStore {
	return &SessionStore{ttl: ttl, m: map[string]time.Time{}}
}

func (s *SessionStore) New() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	id := hex.EncodeToString(b)
	s.mu.Lock()
	s.m[id] = time.Now().Add(s.ttl)
	s.mu.Unlock()
	return id
}

func (s *SessionStore) Valid(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	exp, ok := s.m[id]
	if !ok {
		return false
	}
	if time.Now().After(exp) {
		delete(s.m, id)
		return false
	}
	return true
}

func (s *SessionStore) Delete(id string) {
	s.mu.Lock()
	delete(s.m, id)
	s.mu.Unlock()
}
