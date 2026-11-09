// The in-game menu on Apple TV: none. On iPhone and iPad, GameMenu.swift builds a UIMenu that the touch gamepad's gear button opens (DmGamepad.m), with the controller
// layout and the launcher settings the running game takes at once. That Swift needs the iOS launcher model (LauncherSettings.swift) and orientation APIs tvOS does
// not have (DmHostingController.swift), so project_tv.yml leaves both out, as it leaves out Launcher.swift. tvOS has no touch gamepad either (DmGamepad.m hides its
// controls there): its settings are chosen before the game starts, on the settings screen (TVPlayers.m). DmGamepad.m still asks for the menu, so this gives it none.
#include <stddef.h>

void *dm_game_menu(void) { return NULL; }   // DmGamepad.m: CFBridgingRelease(NULL) is nil, a button without a menu
