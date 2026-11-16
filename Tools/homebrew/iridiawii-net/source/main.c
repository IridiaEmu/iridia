// SPDX-License-Identifier: GPL-2.0-or-later
// Iridia Wii offline test. Calls net_init() and a DNS lookup, then keeps counting frames, and writes
// the results to /tmp/iridia_net.txt on the NAND every 60 frames (host: Wii/tmp/iridia_net.txt).
#include <gccore.h>
#include <network.h>
#include <stdio.h>
#include <string.h>

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
  VIDEO_WaitVSync();
  ISFS_Initialize();

  printf("Iridia Wii offline test\n");
  const s32 init = net_init();
  const struct hostent* host = init >= 0 ? net_gethostbyname("example.com") : NULL;
  const s32 sock = net_socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
  printf("net_init %d, dns %s, socket %d\n", init, host ? "found" : "none", sock);

  for (u32 frames = 1;; frames++)
  {
    VIDEO_WaitVSync();
    if (frames % 60 == 0)
    {
      static char buf[256] ATTRIBUTE_ALIGN(32);
      const int n = snprintf(buf, sizeof(buf), "frames=%u net_init=%d dns=%s socket=%d\n", frames,
                             init, host ? "found" : "none", sock);
      ISFS_Delete("/tmp/iridia_net.txt");
      ISFS_CreateFile("/tmp/iridia_net.txt", 0, 3, 3, 3);
      const s32 fd = ISFS_Open("/tmp/iridia_net.txt", ISFS_OPEN_WRITE);
      if (fd >= 0)
      {
        ISFS_Write(fd, buf, n);
        ISFS_Close(fd);
      }
    }
  }
  return 0;
}
