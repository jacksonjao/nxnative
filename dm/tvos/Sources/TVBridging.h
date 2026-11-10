// The Objective-C functions the Apple TV's Swift calls (dm/tvos/tools/prepare_project.py points SWIFT_OBJC_BRIDGING_HEADER here)
#pragma once

// front_tv.m: after Play on the settings screen (TVLauncher.swift), takes the screen away, gives controllers back to the game and starts it (done)
void dm_tv_start(void *settings_view_controller, void *root_view_controller, void (*done)(void));
