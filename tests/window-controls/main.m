#import <Cocoa/Cocoa.h>
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include "macos_window.h"
bool sc_push_event_impl(uint32_t type, void *ptr, const char *name) {
    (void)name; SDL_Event event = {0}; event.type = type; event.user.data1 = ptr;
    return SDL_PushEvent(&event);
}
int main(void) {
    freopen("/private/tmp/android-wireless-window-check.log", "w", stdout);
    setenv("AW_PHONE_TOOLS", "1", 1);
    if (!SDL_Init(SDL_INIT_VIDEO)) return 1;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
    SDL_Window *window = SDL_CreateWindow("Window controls check", 360, 620, SDL_WINDOW_BORDERLESS);
    if (!window) return 2;
    SDL_Renderer *renderer = SDL_CreateRenderer(window, NULL);
    sc_macos_window_setup(window);
    SDL_ShowWindow(window); SDL_RaiseWindow(window);
    [NSApp activateIgnoringOtherApps:YES];
    uint64_t until = SDL_GetTicks() + 120000, restore = 0;
    bool running = true;
    while (running && SDL_GetTicks() < until) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_EVENT_QUIT) { printf("WINDOW_TEST:close\n"); fflush(stdout); running = false; }
            if (e.type == SDL_EVENT_WINDOW_MINIMIZED) { printf("WINDOW_TEST:minimized\n"); fflush(stdout); restore = SDL_GetTicks() + 1000; }
        }
        if (restore && SDL_GetTicks() >= restore) { SDL_RestoreWindow(window); SDL_RaiseWindow(window); restore = 0; }
        SDL_SetRenderDrawColor(renderer, 38, 60, 86, 255); SDL_RenderClear(renderer); SDL_RenderPresent(renderer);
        SDL_Delay(10);
    }
    sc_macos_window_cleanup(); SDL_DestroyRenderer(renderer); SDL_DestroyWindow(window); SDL_Quit();
    return 0;
}
