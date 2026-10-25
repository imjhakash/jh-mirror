// Drives the real preview sink (aw_preview.c) with synthetic frames.
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libavutil/frame.h>
#include "aw_preview.h"

static AVFrame *frame(int format, int w, int h, int y, int u, int v) {
    AVFrame *f = av_frame_alloc();
    f->format = format; f->width = w; f->height = h;
    assert(av_frame_get_buffer(f, 0) == 0);
    for (int row = 0; row < h; ++row) memset(f->data[0] + row * f->linesize[0], y, w);
    for (int row = 0; row < h / 2; ++row) {
        if (format == AV_PIX_FMT_NV12) {
            for (int x = 0; x < w / 2; ++x) { f->data[1][row * f->linesize[1] + 2 * x] = u; f->data[1][row * f->linesize[1] + 2 * x + 1] = v; }
        } else {
            memset(f->data[1] + row * f->linesize[1], u, w / 2);
            memset(f->data[2] + row * f->linesize[2], v, w / 2);
        }
    }
    return f;
}

static uint64_t seq(struct sc_aw_preview *p) { uint64_t s; memcpy(&s, p->map + 8, 8); return s; }
static uint32_t u32(struct sc_aw_preview *p, int offset) { uint32_t v; memcpy(&v, p->map + offset, 4); return v; }

int main(int argc, char **argv) {
    assert(argc == 2);
    setenv("AW_PREVIEW_PATH", argv[1], 1);
    struct sc_aw_preview p;
    assert(sc_aw_preview_init(&p));
    assert(!memcmp(p.map, "AWP1", 4));
    const struct sc_frame_sink_ops *ops = p.frame_sink.ops;

    AVFrame *big = frame(AV_PIX_FMT_NV12, 1080, 2340, 128, 128, 128);
    ops->push(&p.frame_sink, big);
    assert(seq(&p) == 0 && "nothing is converted until the popover enables the preview");

    sc_aw_preview_set_enabled(true);
    ops->push(&p.frame_sink, big);
    assert(seq(&p) == 2);
    assert(u32(&p, 16) == 360 && u32(&p, 20) == 780 && "downscaled to fit 360x800, aspect kept");
    ops->push(&p.frame_sink, big);
    assert(seq(&p) == 2 && "throttled to ~12 fps");

    usleep(100000);
    AVFrame *red = frame(AV_PIX_FMT_YUV420P, 64, 128, 63, 102, 240); // BT.709 limited-range red
    ops->push(&p.frame_sink, red);
    assert(seq(&p) == 4 && u32(&p, 16) == 64 && u32(&p, 20) == 128 && u32(&p, 24) == 256);
    const uint8_t *px = p.map + 64 + 10 * 256 + 4 * 10;
    assert(px[2] > 240 && px[1] < 20 && px[0] < 20 && px[3] == 255 && "BGRA red");

    sc_aw_preview_set_enabled(false);
    usleep(100000);
    ops->push(&p.frame_sink, big);
    assert(seq(&p) == 4 && "disabled again: no work");

    av_frame_free(&big); av_frame_free(&red);
    sc_aw_preview_destroy(&p);
    puts("writer ok");
    return 0;
}
