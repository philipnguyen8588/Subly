#include "chiaki_bridge.h"
#include <chiaki/session.h>
#include <chiaki/regist.h>
#include <chiaki/discovery.h>
#include <chiaki/log.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
static void st_sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <unistd.h>
#include <netdb.h>
#include <arpa/inet.h>
static void st_sleep_ms(int ms) { usleep((useconds_t)ms * 1000); }
#endif

static pthread_once_t lib_once = PTHREAD_ONCE_INIT;
static void lib_init(void) { chiaki_lib_init(); }

typedef struct { STEventCb cb; void *user; } LogCtx;
static void log_cb(ChiakiLogLevel level, const char *msg, void *user) {
    LogCtx *c = (LogCtx *)user;
    if (c && c->cb) c->cb(ST_EVENT_LOG, msg, c->user);
}

// MARK: session

struct STSession {
    ChiakiSession session;
    ChiakiLog log;
    LogCtx log_ctx;
    STVideoCb video_cb;
    STEventCb event_cb;
    void *user;
    char *host;
};

static bool video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user) {
    STSession *s = (STSession *)user;
    if (s->video_cb) s->video_cb(buf, buf_size, s->user);
    return true;
}

static void event_cb(ChiakiEvent *event, void *user) {
    STSession *s = (STSession *)user;
    if (!s->event_cb) return;
    switch (event->type) {
        case CHIAKI_EVENT_CONNECTED: s->event_cb(ST_EVENT_CONNECTED, "", s->user); break;
        case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
            s->event_cb(ST_EVENT_PIN_REQUEST, event->login_pin_request.pin_incorrect ? "incorrect" : "", s->user); break;
        case CHIAKI_EVENT_QUIT: {
            char msg[256];
            snprintf(msg, sizeof msg, "%d|%s%s%s", (int)event->quit.reason, chiaki_quit_reason_string(event->quit.reason),
                     event->quit.reason_str ? ": " : "", event->quit.reason_str ? event->quit.reason_str : "");
            s->event_cb(ST_EVENT_QUIT, msg, s->user);
            break;
        }
        default: break;
    }
}

ST_API STSession *st_session_start(const char *host, int ps5, const uint8_t regist_key[16], const uint8_t morning[16],
                            const uint8_t account_id[8], int resolution, int fps, int hevc,
                            STVideoCb vcb, STEventCb ecb, void *user) {
    pthread_once(&lib_once, lib_init);
    STSession *s = calloc(1, sizeof(STSession));
    if (!s) return NULL;
    s->video_cb = vcb; s->event_cb = ecb; s->user = user;
    s->host = strdup(host);
    s->log_ctx.cb = ecb; s->log_ctx.user = user;
    chiaki_log_init(&s->log, CHIAKI_LOG_ALL & ~(CHIAKI_LOG_VERBOSE | CHIAKI_LOG_DEBUG), log_cb, &s->log_ctx);

    ChiakiConnectInfo info;
    memset(&info, 0, sizeof info);
    info.ps5 = ps5 != 0;
    info.host = s->host;
    memcpy(info.regist_key, regist_key, 16);
    memcpy(info.morning, morning, 16);
    memcpy(info.psn_account_id, account_id, 8);
    chiaki_connect_video_profile_preset(&info.video_profile, (ChiakiVideoResolutionPreset)resolution,
                                        fps >= 60 ? CHIAKI_VIDEO_FPS_PRESET_60 : CHIAKI_VIDEO_FPS_PRESET_30);
    info.video_profile.codec = hevc ? CHIAKI_CODEC_H265 : CHIAKI_CODEC_H264;
    info.video_profile_auto_downgrade = true;
    info.enable_keyboard = false;
    info.enable_dualsense = false;
    info.audio_video_disabled = CHIAKI_AUDIO_DISABLED;
    info.auto_regist = false;
    info.holepunch_session = NULL;
    info.rudp_sock = NULL;
    info.packet_loss_max = 0.05;
    info.enable_idr_on_fec_failure = true;

    if (chiaki_session_init(&s->session, &info, &s->log) != CHIAKI_ERR_SUCCESS) { free(s->host); free(s); return NULL; }
    chiaki_session_set_video_sample_cb(&s->session, video_cb, s);
    chiaki_session_set_event_cb(&s->session, event_cb, s);
    if (chiaki_session_start(&s->session) != CHIAKI_ERR_SUCCESS) {
        chiaki_session_fini(&s->session); free(s->host); free(s); return NULL;
    }
    return s;
}

ST_API void st_session_stop(STSession *s) {
    if (!s) return;
    chiaki_session_stop(&s->session);
    chiaki_session_join(&s->session);
    chiaki_session_fini(&s->session);
    free(s->host);
    free(s);
}

ST_API void st_session_request_idr(STSession *s) { if (s) chiaki_session_request_idr(&s->session); }
ST_API void st_session_set_pin(STSession *s, const char *pin) {
    if (s && pin) chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

// MARK: regist

struct STRegist {
    ChiakiRegist regist;
    ChiakiLog log;
    LogCtx log_ctx;
    STRegistCb cb;
    void *user;
    char *host;
    int started;
};

static void regist_cb(ChiakiRegistEvent *event, void *user) {
    STRegist *r = (STRegist *)user;
    if (event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && event->registered_host) {
        ChiakiRegisteredHost *h = event->registered_host;
        r->cb(1, h->server_nickname, h->server_mac, (const uint8_t *)h->rp_regist_key, h->rp_key, r->user);
    } else {
        r->cb(0, event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED ? "canceled" : "failed", NULL, NULL, NULL, r->user);
    }
}

ST_API STRegist *st_regist_start(const char *host, int ps5, const uint8_t account_id[8], uint32_t pin,
                          STRegistCb cb, STEventCb lcb, void *user) {
    pthread_once(&lib_once, lib_init);
    STRegist *r = calloc(1, sizeof(STRegist));
    if (!r) return NULL;
    r->cb = cb; r->user = user; r->host = strdup(host);
    r->log_ctx.cb = lcb; r->log_ctx.user = user;
    chiaki_log_init(&r->log, CHIAKI_LOG_ALL & ~(CHIAKI_LOG_VERBOSE | CHIAKI_LOG_DEBUG), log_cb, &r->log_ctx);
    ChiakiRegistInfo info;
    memset(&info, 0, sizeof info);
    info.target = ps5 ? CHIAKI_TARGET_PS5_1 : CHIAKI_TARGET_PS4_10;
    info.host = r->host;
    info.broadcast = false;
    info.psn_online_id = NULL;
    memcpy(info.psn_account_id, account_id, 8);
    info.pin = pin;
    info.console_pin = 0;
    info.holepunch_info = NULL;
    if (chiaki_regist_start(&r->regist, &r->log, &info, regist_cb, r) != CHIAKI_ERR_SUCCESS) { free(r->host); free(r); return NULL; }
    r->started = 1;
    return r;
}

ST_API void st_regist_finish(STRegist *r) {
    if (!r) return;
    if (r->started) { chiaki_regist_stop(&r->regist); chiaki_regist_fini(&r->regist); }
    free(r->host);
    free(r);
}

// MARK: discovery

typedef struct { STDiscoveryCb cb; void *user; int count; } DiscCtx;
static void disc_cb(ChiakiDiscoveryHost *host, void *user) {
    DiscCtx *c = (DiscCtx *)user;
    c->count++;
    int state = host->state == CHIAKI_DISCOVERY_HOST_STATE_READY ? 1 : host->state == CHIAKI_DISCOVERY_HOST_STATE_STANDBY ? 2 : 0;
    c->cb(host->host_addr ? host->host_addr : "", host->host_name ? host->host_name : "",
          host->host_id ? host->host_id : "", chiaki_discovery_host_is_ps5(host) ? 1 : 0, state, c->user);
}

ST_API int st_discover(const char *host, int timeout_ms, STDiscoveryCb cb, void *user) {
    pthread_once(&lib_once, lib_init);
    ChiakiLog log;
    chiaki_log_init(&log, 0, NULL, NULL);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) return -1;
    ChiakiDiscovery discovery;
    if (chiaki_discovery_init(&discovery, &log, AF_INET) != CHIAKI_ERR_SUCCESS) return -2;
    DiscCtx ctx = { cb, user, 0 };
    ChiakiDiscoveryThread thread;
    if (chiaki_discovery_thread_start(&thread, &discovery, disc_cb, &ctx) != CHIAKI_ERR_SUCCESS) {
        chiaki_discovery_fini(&discovery); return -3;
    }
    ChiakiDiscoveryPacket packet;
    memset(&packet, 0, sizeof packet);
    packet.cmd = CHIAKI_DISCOVERY_CMD_SRCH;
    for (int round = 0; round < 3; round++) {
        packet.protocol_version = CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5;
        addr.sin_port = htons(CHIAKI_DISCOVERY_PORT_PS5);
        chiaki_discovery_send(&discovery, &packet, (struct sockaddr *)&addr, sizeof addr);
        packet.protocol_version = CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS4;
        addr.sin_port = htons(CHIAKI_DISCOVERY_PORT_PS4);
        chiaki_discovery_send(&discovery, &packet, (struct sockaddr *)&addr, sizeof addr);
        st_sleep_ms(timeout_ms / 3);
    }
    chiaki_discovery_thread_stop(&thread);
    chiaki_discovery_fini(&discovery);
    return ctx.count;
}

ST_API int st_wakeup(const char *host, const uint8_t regist_key[16], int ps5) {
    pthread_once(&lib_once, lib_init);
    char key[17];
    memcpy(key, regist_key, 16); key[16] = 0;
    uint64_t cred = strtoull(key, NULL, 16);
    ChiakiLog log;
    chiaki_log_init(&log, 0, NULL, NULL);
    return chiaki_discovery_wakeup(&log, NULL, host, cred, ps5 != 0) == CHIAKI_ERR_SUCCESS ? 0 : -1;
}
