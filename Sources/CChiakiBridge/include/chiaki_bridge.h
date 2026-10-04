// Cầu nối C mỏng tới libchiaki (AGPL-3.0, https://github.com/streetpea/chiaki-ng) để Swift không phải đụng các struct lớn.
// Chỉ dùng: tìm máy, đánh thức, đăng ký, nhận luồng video. Không gửi điều khiển, không nhận âm thanh.
#ifndef ST_CHIAKI_BRIDGE_H
#define ST_CHIAKI_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { ST_EVENT_LOG = 0, ST_EVENT_CONNECTED = 1, ST_EVENT_QUIT = 2, ST_EVENT_PIN_REQUEST = 3 };

typedef void (*STVideoCb)(const uint8_t *buf, size_t size, void *user);
typedef void (*STEventCb)(int type, const char *msg, void *user);
typedef struct STSession STSession;

/// resolution: 1=360p 2=540p 3=720p 4=1080p. fps: 30|60. hevc: 0 = H.264, 1 = H.265.
STSession *st_session_start(const char *host, int ps5, const uint8_t regist_key[16], const uint8_t morning[16],
                            const uint8_t account_id[8], int resolution, int fps, int hevc,
                            STVideoCb video_cb, STEventCb event_cb, void *user);
/// Dừng, đợi luồng kết thúc và giải phóng. Chặn tới ~vài giây.
void st_session_stop(STSession *s);
void st_session_request_idr(STSession *s);
void st_session_set_pin(STSession *s, const char *pin);

typedef void (*STRegistCb)(int ok, const char *nickname, const uint8_t mac[6], const uint8_t regist_key[16],
                           const uint8_t rp_key[16], void *user);
typedef struct STRegist STRegist;
STRegist *st_regist_start(const char *host, int ps5, const uint8_t account_id[8], uint32_t pin,
                          STRegistCb cb, STEventCb log_cb, void *user);
/// Gọi sau khi callback đã chạy (hoặc để huỷ).
void st_regist_finish(STRegist *r);

/// state: 0 không rõ, 1 đang bật, 2 chế độ nghỉ.
typedef void (*STDiscoveryCb)(const char *addr, const char *name, const char *host_id, int is_ps5, int state, void *user);
/// Gửi yêu cầu tìm máy tới `host` (IP hoặc 255.255.255.255) và chờ `timeout_ms`. Trả về số máy tìm thấy, <0 nếu lỗi.
int st_discover(const char *host, int timeout_ms, STDiscoveryCb cb, void *user);
int st_wakeup(const char *host, const uint8_t regist_key[16], int ps5);

#ifdef __cplusplus
}
#endif
#endif
