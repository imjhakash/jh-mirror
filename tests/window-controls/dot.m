#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <SDL3/SDL.h>
#include <assert.h>
#include <stdio.h>
#include "macos_window.h"
#undef MIN
#undef MAX
#include "events.h"
void sc_aw_preview_set_enabled(bool enabled) { (void)enabled; }
bool sc_push_event_impl(uint32_t type, void *ptr, const char *name) {
    (void)name; SDL_Event event={0}; event.type=type; event.user.data1=ptr; return SDL_PushEvent(&event);
}
int main(void) {
    setenv("AW_PHONE_TOOLS","1",1);
    assert(SDL_Init(SDL_INIT_VIDEO)); [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; [NSApp finishLaunching];
    SDL_Window *window=SDL_CreateWindow("JH Mirror corner check",360,620,SDL_WINDOW_BORDERLESS); assert(window);
    SDL_Renderer *renderer=SDL_CreateRenderer(window,NULL); assert(renderer);
    sc_macos_window_setup(window); SDL_ShowWindow(window);
    NSWindow *native=(__bridge NSWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(window),SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,NULL);
    NSButton *dot=nil;
    for (NSView *view in native.contentView.subviews) if ([view isKindOfClass:NSClassFromString(@"AWToolsDot")]) dot=(NSButton *)view;
    assert(dot && [dot.toolTip isEqualToString:@"Expand Phone Tools"]);
    assert(dot.frame.size.width==28 && dot.frame.size.height==26 && !dot.bordered);
    assert(dot.layer.sublayers.count==0); // Just the drawn arrow: no dot, halo, border or animation layers.
    assert(fabs(NSMaxX(dot.frame)-(native.contentView.bounds.size.width-6))<1);
    NSView *hit=[native.contentView hitTest:NSMakePoint(NSMidX(dot.frame),NSMidY(dot.frame))]; assert(hit==dot || [hit isDescendantOf:dot]);
    [dot performClick:nil];
    SDL_SetWindowSize(window,440,720);
    uint64_t start=SDL_GetTicks(); bool checked=false, pulse=false, quit=false;
    while (SDL_GetTicks()-start<5000 && !quit) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type==SC_EVENT_TOOL_KEEP_ACTIVE) pulse=true;
            if (event.type==SDL_EVENT_QUIT) quit=true;
        }
        if (!checked && SDL_GetTicks()-start>700) {
            assert(dot.state==NSControlStateValueOn && [dot.toolTip isEqualToString:@"Collapse Phone Tools"]);
            assert(fabs(NSMaxX(dot.frame)-(native.contentView.bounds.size.width-6))<1);
            puts("PASS: corner hit target, parent toggle signal, visibility label and resize anchoring"); fflush(stdout); checked=true;
        }
        SDL_SetRenderDrawColor(renderer,38,60,86,255); SDL_RenderClear(renderer); SDL_RenderPresent(renderer); SDL_Delay(10);
    }
    assert(checked && pulse && quit);
    sc_macos_window_cleanup(); SDL_DestroyRenderer(renderer); SDL_DestroyWindow(window); SDL_Quit();
    puts("PASS: parent activity command reaches SDL; closing parent pipe quits the helper"); return 0;
}
