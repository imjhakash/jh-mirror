// Exercise the real parser only. No scrcpy/adb/device connection is invoked.
#include "cli.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    assert(argc==2);
    bool direct=!strcmp(argv[1],"direct");
    if (!strcmp(argv[1],"no-device")) unsetenv("JH_CAMERA_DEVICE_UID");
    else setenv("JH_CAMERA_DEVICE_UID", !strcmp(argv[1],"empty-device") ? "" : "7626645E-4425-469E-9D8B-97E0FA59AC75",1);
    struct scrcpy_cli_args args={.opts=scrcpy_options_default};
    char *options[]={"scrcpy","-s","paired","--force-adb-forward","--no-terminal-title",
        !strcmp(argv[1],"display") ? "--video-source=display" : "--video-source=camera",
        "--camera-facing=front","--camera-ar=16:9","--max-size=1280","--camera-fps=30",
        "--video-codec=h264","--video-bit-rate=4M","--no-audio","--no-window","--no-control"};
    bool ok=scrcpy_parse_args(&args,sizeof(options)/sizeof(options[0]),options);
    assert(ok==direct);
    if (direct) {
        assert(args.opts.video && !args.opts.video_playback && !args.opts.window);
        assert(!args.opts.audio && !args.opts.control && !args.opts.record_filename);
        assert(args.opts.video_source==SC_VIDEO_SOURCE_CAMERA);
    }
    return 0;
}
