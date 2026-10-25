// SPDX-License-Identifier: Apache-2.0
#include "aw_preview.h"

#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixfmt.h>
#include <libavutil/time.h>

#include "util/log.h"

#define DOWNCAST(SINK) container_of(SINK, struct sc_aw_preview, frame_sink)
#define FRAME_INTERVAL_US 80000 // ~12 fps is plenty for a preview

static atomic_bool enabled;

void
sc_aw_preview_set_enabled(bool value) {
    atomic_store(&enabled, value);
}

static inline uint8_t
clamp_u8(int value) {
    return value < 0 ? 0 : value > 255 ? 255 : (uint8_t) value;
}

static bool
sc_aw_preview_frame_sink_open(struct sc_frame_sink *sink, const AVCodecContext *ctx,
                              const struct sc_stream_session *session) {
    (void) sink; (void) ctx; (void) session;
    return true;
}

static void
sc_aw_preview_frame_sink_close(struct sc_frame_sink *sink) {
    (void) sink;
}

static enum sc_sink_result
sc_aw_preview_frame_sink_push(struct sc_frame_sink *sink, const AVFrame *frame) {
    struct sc_aw_preview *preview = DOWNCAST(sink);
    if (!atomic_load(&enabled) || !preview->map) {
        return SC_SINK_OK;
    }
    int64_t now = av_gettime_relative();
    if (now - preview->last_frame_us < FRAME_INTERVAL_US) {
        return SC_SINK_OK;
    }
    preview->last_frame_us = now;

    const AVFrame *src = frame;
    if (frame->hw_frames_ctx) {
        // Hardware (VideoToolbox) frames are downloaded only at preview rate.
        av_frame_unref(preview->software);
        if (av_hwframe_transfer_data(preview->software, frame, 0) < 0) {
            return SC_SINK_OK;
        }
        src = preview->software;
    }
    bool nv12 = src->format == AV_PIX_FMT_NV12;
    bool planar = src->format == AV_PIX_FMT_YUV420P || src->format == AV_PIX_FMT_YUVJ420P;
    if ((!nv12 && !planar) || src->width <= 0 || src->height <= 0) {
        return SC_SINK_OK;
    }

    int w = src->width, h = src->height;
    double scale = (double) SC_AW_PREVIEW_MAX_WIDTH / w;
    if ((double) SC_AW_PREVIEW_MAX_HEIGHT / h < scale) {
        scale = (double) SC_AW_PREVIEW_MAX_HEIGHT / h;
    }
    if (scale > 1) {
        scale = 1;
    }
    uint32_t ow = (uint32_t) (w * scale), oh = (uint32_t) (h * scale);
    if (!ow || !oh) {
        return SC_SINK_OK;
    }
    uint32_t stride = ow * 4;

    _Atomic uint64_t *seq = (_Atomic uint64_t *) (preview->map + 8);
    atomic_fetch_add_explicit(seq, 1, memory_order_acq_rel); // odd: writing
    uint8_t *out = preview->map + SC_AW_PREVIEW_HEADER;
    for (uint32_t y = 0; y < oh; ++y) {
        int sy = (int) ((int64_t) y * h / oh);
        int sy2 = sy + 1 < h ? sy + 1 : sy;
        const uint8_t *row = src->data[0] + (ptrdiff_t) sy * src->linesize[0];
        const uint8_t *row2 = src->data[0] + (ptrdiff_t) sy2 * src->linesize[0];
        int cy = sy / 2;
        uint8_t *dst = out + (size_t) y * stride;
        for (uint32_t x = 0; x < ow; ++x) {
            int sx = (int) ((int64_t) x * w / ow);
            int sx2 = sx + 1 < w ? sx + 1 : sx;
            // A 2x2 luma average softens aliasing on downscaled text.
            int luma = (row[sx] + row[sx2] + row2[sx] + row2[sx2] + 2) / 4;
            int cx = sx / 2, u, v;
            if (nv12) {
                const uint8_t *uv = src->data[1] + (ptrdiff_t) cy * src->linesize[1] + cx * 2;
                u = uv[0]; v = uv[1];
            } else {
                u = src->data[1][(ptrdiff_t) cy * src->linesize[1] + cx];
                v = src->data[2][(ptrdiff_t) cy * src->linesize[2] + cx];
            }
            // BT.709 limited range → RGB (fixed point, 8 fractional bits)
            int c = 298 * (luma - 16), d = u - 128, e = v - 128;
            dst[4 * x + 0] = clamp_u8((c + 541 * d + 128) >> 8);           // B
            dst[4 * x + 1] = clamp_u8((c - 55 * d - 136 * e + 128) >> 8);  // G
            dst[4 * x + 2] = clamp_u8((c + 459 * e + 128) >> 8);           // R
            dst[4 * x + 3] = 255;
        }
    }
    memcpy(preview->map + 16, &ow, 4);
    memcpy(preview->map + 20, &oh, 4);
    memcpy(preview->map + 24, &stride, 4);
    atomic_fetch_add_explicit(seq, 1, memory_order_acq_rel); // even: complete
    return SC_SINK_OK;
}

bool
sc_aw_preview_init(struct sc_aw_preview *preview) {
    memset(preview, 0, sizeof(*preview));
    const char *path = getenv("AW_PREVIEW_PATH");
    if (!path || !*path) {
        return false;
    }
    preview->map_size = SC_AW_PREVIEW_HEADER
        + (size_t) SC_AW_PREVIEW_MAX_WIDTH * SC_AW_PREVIEW_MAX_HEIGHT * 4;
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0 || ftruncate(fd, (off_t) preview->map_size) < 0) {
        if (fd >= 0) {
            close(fd);
        }
        LOGW("Preview unavailable");
        return false;
    }
    void *map = mmap(NULL, preview->map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) {
        LOGW("Preview unavailable");
        return false;
    }
    preview->map = map;
    memcpy(preview->map, "AWP1", 4);
    preview->software = av_frame_alloc();
    if (!preview->software) {
        munmap(preview->map, preview->map_size);
        preview->map = NULL;
        return false;
    }
    static const struct sc_frame_sink_ops ops = {
        .open = sc_aw_preview_frame_sink_open,
        .close = sc_aw_preview_frame_sink_close,
        .push = sc_aw_preview_frame_sink_push,
    };
    preview->frame_sink.ops = &ops;
    return true;
}

void
sc_aw_preview_destroy(struct sc_aw_preview *preview) {
    if (preview->map) {
        munmap(preview->map, preview->map_size);
        preview->map = NULL;
    }
    av_frame_free(&preview->software);
}
