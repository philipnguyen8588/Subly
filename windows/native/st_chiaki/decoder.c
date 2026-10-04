// Giải mã H.264 (Annex-B từ libchiaki) → khung BGRA, thay cho VideoToolbox của bản macOS.
// Dùng FFmpeg tối giản (chỉ decoder h264 + swscale), liên kết tĩnh vào st_chiaki.dll.
#include "chiaki_bridge.h"
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>
#include <stdlib.h>
#include <string.h>

struct STDecoder {
    const AVCodec *codec;
    AVCodecContext *ctx;
    AVPacket *pkt;
    AVFrame *frame;
    struct SwsContext *sws;
    int sws_w, sws_h, sws_fmt;
    uint8_t *bgra;
    int width, height, stride;
};

ST_API STDecoder *st_decoder_new(void) {
    STDecoder *d = calloc(1, sizeof(STDecoder));
    if (!d) return NULL;
    d->codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    if (!d->codec) { free(d); return NULL; }
    d->ctx = avcodec_alloc_context3(d->codec);
    d->pkt = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->ctx || !d->pkt || !d->frame) { st_decoder_free(d); return NULL; }
    // Độ trễ thấp: không giữ khung để sắp xếp lại, giải mã nhiều luồng theo lát.
    d->ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    d->ctx->flags2 |= AV_CODEC_FLAG2_FAST;
    d->ctx->thread_count = 2;
    d->ctx->thread_type = FF_THREAD_SLICE;
    if (avcodec_open2(d->ctx, d->codec, NULL) < 0) { st_decoder_free(d); return NULL; }
    return d;
}

static int convert(STDecoder *d) {
    AVFrame *f = d->frame;
    if (f->width <= 0 || f->height <= 0) return 0;
    if (!d->sws || d->sws_w != f->width || d->sws_h != f->height || d->sws_fmt != f->format) {
        sws_freeContext(d->sws);
        d->sws = sws_getContext(f->width, f->height, (enum AVPixelFormat)f->format, f->width, f->height,
                                AV_PIX_FMT_BGRA, SWS_POINT, NULL, NULL, NULL);
        if (!d->sws) return -1;
        d->sws_w = f->width; d->sws_h = f->height; d->sws_fmt = f->format;
        free(d->bgra);
        d->stride = f->width * 4;
        d->bgra = malloc((size_t)d->stride * f->height);
        if (!d->bgra) return -1;
        d->width = f->width; d->height = f->height;
    }
    uint8_t *dst[4] = { d->bgra, NULL, NULL, NULL };
    int dst_stride[4] = { d->stride, 0, 0, 0 };
    sws_scale(d->sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height, dst, dst_stride);
    return 1;
}

ST_API int st_decoder_decode(STDecoder *d, const uint8_t *buf, size_t size) {
    if (!d || !buf || size == 0) return -1;
    // libchiaki giao trọn một khung (access unit, Annex-B) mỗi lần → gửi thẳng cho decoder, không cần parser.
    if (av_new_packet(d->pkt, (int)size) < 0) return -1;
    memcpy(d->pkt->data, buf, size);
    int got = 0, err = 0;
    if (avcodec_send_packet(d->ctx, d->pkt) < 0) err = 1;
    av_packet_unref(d->pkt);
    for (;;) {
        int r = avcodec_receive_frame(d->ctx, d->frame);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) break;
        if (r < 0) { err = 1; break; }
        if (d->frame->decode_error_flags) err = 1;
        if (convert(d) > 0) got = 1;
        av_frame_unref(d->frame);
    }
    if (got) return 1;
    return err ? -1 : 0;
}

ST_API const uint8_t *st_decoder_frame(STDecoder *d, int *width, int *height, int *stride) {
    if (!d || !d->bgra) { if (width) *width = 0; if (height) *height = 0; if (stride) *stride = 0; return NULL; }
    if (width) *width = d->width;
    if (height) *height = d->height;
    if (stride) *stride = d->stride;
    return d->bgra;
}

ST_API void st_decoder_free(STDecoder *d) {
    if (!d) return;
    sws_freeContext(d->sws);
    avcodec_free_context(&d->ctx);
    av_packet_free(&d->pkt);
    av_frame_free(&d->frame);
    free(d->bgra);
    free(d);
}
