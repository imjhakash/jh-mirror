#ifndef SC_AW_CAMERA_SINK_H
#define SC_AW_CAMERA_SINK_H
#include "trait/frame_sink.h"

// The CoreMediaIO connection is owned by the video decoder thread.
struct sc_aw_camera_sink {
    struct sc_frame_sink frame_sink;
    void *context;
};
bool sc_aw_camera_sink_init(struct sc_aw_camera_sink *camera);
void sc_aw_camera_sink_destroy(struct sc_aw_camera_sink *camera);
#endif
