// SPDX-License-Identifier: GPL-2.0-or-later
// Iridia Wii system-title test. Counts 180 frames, then asks IOS to launch the Wii Menu, which
// Iridia doesn't include. Iridia should show its message and stop the game.
#include <gccore.h>
#include <stdio.h>

int main(void)
{
  VIDEO_Init();
  GXRModeObj* mode = VIDEO_GetPreferredMode(NULL);
  void* xfb = MEM_K0_TO_K1(SYS_AllocateFramebuffer(mode));
  console_init(xfb, 20, 20, mode->fbWidth, mode->xfbHeight, mode->fbWidth * VI_DISPLAY_PIX_SZ);
  VIDEO_Configure(mode);
  VIDEO_SetNextFramebuffer(xfb);
  VIDEO_SetBlack(false);
  VIDEO_Flush();
  printf("Iridia Wii system-title test: going to the Wii Menu in 3 seconds\n");
  for (int i = 0; i < 180; i++)
    VIDEO_WaitVSync();
  // Straight to ES (WII_LaunchTitle first looks up the title's ticket, which isn't there).
  static tikview view ATTRIBUTE_ALIGN(32);
  const s32 result = ES_LaunchTitle(0x0000000100000002ULL, &view);
  printf("WII_LaunchTitle returned %d\n", result);
  for (;;)
    VIDEO_WaitVSync();
  return 0;
}
