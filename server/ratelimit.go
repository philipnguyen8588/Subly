package main

import (
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
