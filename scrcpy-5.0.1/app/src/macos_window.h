// SPDX-License-Identifier: Apache-2.0
#ifndef SC_MACOS_WINDOW_H
#define SC_MACOS_WINDOW_H
#include <SDL3/SDL_video.h>
void sc_macos_window_setup(SDL_Window *);
void sc_macos_window_ready(SDL_Window *);
void sc_macos_window_cleanup(void);
#endif
