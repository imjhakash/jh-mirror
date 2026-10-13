// SPDX-License-Identifier: Apache-2.0
#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include "macos_window.h"
#undef MIN
#undef MAX
#include "events.h"

static id drag_monitor;
static id quit_key_monitor;

// Tells the launcher this exit was requested by the user, so it must not reopen the window.
static void announce_user_close(void) {
    if (!getenv("AW_PHONE_TOOLS")) return;
    puts("AW_CLOSE_REQUESTED"); fflush(stdout);
}
static NSMutableArray *observers;
static SDL_Window *phone_sdl_window;
static NSWindow *phone_window;
static NSView *window_controls;

@interface AWWindowDot : NSButton
@end
@implementation AWWindowDot
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSColor *color = self.tag == 0 ? NSColor.systemRedColor : NSColor.systemYellowColor;
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(self.bounds, 4, 4)] fill];
    if (self.highlighted) {
        [NSColor.labelColor setStroke];
        NSBezierPath *mark = [NSBezierPath bezierPath];
        mark.lineWidth = 1;
        [mark moveToPoint:NSMakePoint(7, 10)];
        [mark lineToPoint:NSMakePoint(13, 10)];
        if (self.tag == 0) {
            [mark removeAllPoints];
            [mark moveToPoint:NSMakePoint(7, 7)]; [mark lineToPoint:NSMakePoint(13, 13)];
            [mark moveToPoint:NSMakePoint(7, 13)]; [mark lineToPoint:NSMakePoint(13, 7)];
        }
        [mark stroke];
    }
}
@end

@interface AWWindowControls : NSVisualEffectView
- (void)closePhone:(id)sender;
- (void)minimizePhone:(id)sender;
@end
@implementation AWWindowControls
- (void)closePhone:(id)sender { (void)sender; announce_user_close(); sc_push_event(SDL_EVENT_QUIT); }
- (void)minimizePhone:(id)sender { (void)sender; if (phone_sdl_window) SDL_MinimizeWindow(phone_sdl_window); }
@end

static void report_frame(void) {
    if (!phone_window || !getenv("AW_PHONE_TOOLS")) return;
    NSRect f = phone_window.frame;
    printf("AW_FRAME:{\"x\":%.2f,\"y\":%.2f,\"width\":%.2f,\"height\":%.2f,\"visible\":%s,\"active\":%s,\"minimized\":%s}\n",
        f.origin.x, f.origin.y, f.size.width, f.size.height,
        phone_window.visible && !phone_window.miniaturized ? "true" : "false",
        phone_window.keyWindow ? "true" : "false", phone_window.miniaturized ? "true" : "false");
    fflush(stdout);
}

void sc_macos_window_setup(SDL_Window *sdl_window) {
    NSWindow *window = (NSWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(sdl_window),
        SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    if (!window || phone_window == window) return;
    phone_window = window;
    phone_sdl_window = sdl_window;
    if (!(window.styleMask & NSWindowStyleMaskTitled)) {
        window.styleMask |= NSWindowStyleMaskMiniaturizable;
        AWWindowControls *controls = [[AWWindowControls alloc] initWithFrame:
            NSMakeRect(6, window.contentView.bounds.size.height - 34, 48, 28)];
        controls.material = NSVisualEffectMaterialHUDWindow;
        controls.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        controls.state = NSVisualEffectStateActive;
        controls.wantsLayer = YES;
        controls.layer.cornerRadius = 8;
        controls.layer.masksToBounds = YES;
        controls.autoresizingMask = NSViewMinYMargin;
        for (NSInteger i = 0; i < 2; ++i) {
            AWWindowDot *dot = [[AWWindowDot alloc] initWithFrame:NSMakeRect(2 + i * 24, 4, 20, 20)];
            dot.tag = i; dot.bordered = NO; dot.target = controls;
            dot.action = i == 0 ? @selector(closePhone:) : @selector(minimizePhone:);
            dot.toolTip = i == 0 ? @"Close phone window" : @"Minimize phone window";
            [dot setAccessibilityLabel:dot.toolTip];
            [controls addSubview:dot];
#if !__has_feature(objc_arc)
            [dot release];
#endif
        }
        window_controls = controls;
        [window.contentView addSubview:controls];
        drag_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
            handler:^NSEvent *(NSEvent *event) {
                if (event.window != window) return event;
                NSPoint point = [window.contentView convertPoint:event.locationInWindow fromView:nil];
                if (window_controls && NSPointInRect(point, window_controls.frame)) return event;
                NSSize size = window.contentView.bounds.size;
                BOOL border = point.x < 6 || point.y < 6 || point.x >= size.width - 6 || point.y >= size.height - 6;
                if (border || (event.modifierFlags & NSEventModifierFlagOption)) {
                    [window performWindowDragWithEvent:event];
                    return nil;
                }
                return event;
            }];
    }
    if (!getenv("AW_PHONE_TOOLS")) return;
    quit_key_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        if (mods == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers isEqualToString:@"q"]) announce_user_close();
        return event;
    }];
    observers = [[NSMutableArray alloc] init];
    NSArray *names = @[ NSWindowDidMoveNotification, NSWindowDidResizeNotification,
        NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
        NSWindowDidMiniaturizeNotification, NSWindowDidDeminiaturizeNotification ];
    for (NSString *name in names) {
        id observer = [[NSNotificationCenter defaultCenter] addObserverForName:name object:window
            queue:nil usingBlock:^(NSNotification *note) { (void)note; report_frame(); }];
        [observers addObject:observer];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ report_frame(); });
    // Commands arrive only over our parent's inherited stdin pipe; no public IPC endpoint.
    struct termios settings;
    if (tcgetattr(STDIN_FILENO, &settings) == 0) {
        settings.c_lflag &= ~(ECHO | ECHONL);
        tcsetattr(STDIN_FILENO, TCSANOW, &settings);
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        char line[256];
        while (fgets(line, sizeof(line), stdin)) {
            if (!strcmp(line, "AW_COMMAND:get-clipboard\n")) sc_push_event(SC_EVENT_TOOL_CLIPBOARD_GET);
            else if (!strcmp(line, "AW_COMMAND:set-clipboard\n")) sc_push_event(SC_EVENT_TOOL_CLIPBOARD_SET);
            else if (!strcmp(line, "AW_COMMAND:hide\n") || !strcmp(line, "AW_COMMAND:show\n")) {
                bool hide = !strcmp(line, "AW_COMMAND:hide\n");
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!phone_sdl_window) return;
                    if (hide) SDL_HideWindow(phone_sdl_window);
                    else { SDL_RestoreWindow(phone_sdl_window); SDL_ShowWindow(phone_sdl_window); SDL_RaiseWindow(phone_sdl_window); }
                    report_frame();
                });
            }
        }
    });
}
void sc_macos_window_ready(SDL_Window *window) {
    // Retry after SDL shows the window; some renderers defer the native window.
    sc_macos_window_setup(window);
    if (getenv("AW_PHONE_TOOLS")) {
        puts("AW_READY"); fflush(stdout); report_frame();
    }
}
void sc_macos_window_cleanup(void) {
    if (drag_monitor) { [NSEvent removeMonitor:drag_monitor]; drag_monitor = nil; }
    if (quit_key_monitor) { [NSEvent removeMonitor:quit_key_monitor]; quit_key_monitor = nil; }
    for (id observer in observers) [[NSNotificationCenter defaultCenter] removeObserver:observer];
#if !__has_feature(objc_arc)
    [observers release];
#endif
    observers = nil;
    [window_controls removeFromSuperview];
#if !__has_feature(objc_arc)
    [window_controls release];
#endif
    window_controls = nil;
    phone_window = nil;
    phone_sdl_window = NULL;
}
