// The Objective-C functions the Apple TV's Swift calls (project_tv.yml points SWIFT_OBJC_BRIDGING_HEADER here)
#pragma once

// TVPlayers.m: after Play on the settings screen (TVLauncher.swift), asks who is playing when several play, gives controllers back to the game and starts it (done)
void dm_tv_start(void *settings_view_controller, void *root_view_controller, void (*done)(void));
