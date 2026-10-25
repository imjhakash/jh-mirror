// SPDX-License-Identifier: Apache-2.0
// JH Mirror: small live preview for the macOS menu-bar popover.
#ifndef SC_AW_PREVIEW_H
#define SC_AW_PREVIEW_H

#include "common.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <libavutil/frame.h>

#include "trait/frame_sink.h"

/*
 * Shared file layout (little endian):
 *   0  "AWP1"
 *   8  uint64 sequence (odd while a frame is being written)
 *  16  uint32 width, 20 uint32 height, 24 uint32 stride (bytes)
 *  64  BGRA pixels
 */
#define SC_AW_PREVIEW_MAX_WIDTH 360
#define SC_AW_PREVIEW_MAX_HEIGHT 800
#define SC_AW_PREVIEW_HEADER 64

struct sc_aw_preview {
    struct sc_frame_sink frame_sink; // frame sink trait
    uint8_t *map;
    size_t map_size;
    AVFrame *software;
    int64_t last_frame_us;
};

// Uses $AW_PREVIEW_PATH; returns false (and does nothing) when unset or unavailable.
bool
sc_aw_preview_init(struct sc_aw_preview *preview);

void
sc_aw_preview_destroy(struct sc_aw_preview *preview);

// Frames are converted only while enabled (the popover is visible).
void
sc_aw_preview_set_enabled(bool enabled);

#endif
