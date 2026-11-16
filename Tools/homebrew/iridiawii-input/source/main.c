// SPDX-License-Identifier: GPL-2.0-or-later
//
// Iridia Wii input test: an original Wii program for checking Iridia's Wii controls.
//
// It shows, and once a second writes to the NAND file /tmp/iridia_input.txt, what the emulated
// controllers report:
//   - Wii Remote 1: buttons (held now and ever pressed), pointer (IR) position and whether it is
//     on screen, orientation (roll/pitch from the accelerometer, i.e. tilt), and the largest
//     acceleration seen (a shake reads well above 1 g),
//   - the extension: Nunchuk (stick, C, Z) or Classic Controller (buttons, both sticks),
//   - GameCube controller port 1, for Wii games that accept one.
// The host side reads the file from Dolphin's NAND folder (Wii/tmp). Plain text on a dark
// background; nothing flashes. HOME on the Wii Remote or START on the GameCube pad exits.

#include <gccore.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <wiiuse/wpad.h>

static void* xfb;
static GXRModeObj* rmode;

static const char* ext_name(int type)
{
  switch (type)
  {
  case WPAD_EXP_NONE: return "none";
  case WPAD_EXP_NUNCHUK: return "nunchuk";
  case WPAD_EXP_CLASSIC: return "classic";
  default: return "other";
  }
}

int main(void)
{
  VIDEO_Init();
  WPAD_Init();
  PAD_Init();
  rmode = VIDEO_GetPreferredMode(NULL);
  xfb = MEM_K0_TO_K1(SYS_AllocateFramebuffer(rmode));
  console_init(xfb, 20, 20, rmode->fbWidth, rmode->xfbHeight, rmode->fbWidth * VI_DISPLAY_PIX_SZ);
  VIDEO_Configure(rmode);
  VIDEO_SetNextFramebuffer(xfb);
  VIDEO_SetBlack(FALSE);
  VIDEO_Flush();
  VIDEO_WaitVSync();
  if (rmode->viTVMode & VI_NON_INTERLACE)
    VIDEO_WaitVSync();

  WPAD_SetDataFormat(WPAD_CHAN_0, WPAD_FMT_BTNS_ACC_IR);
  WPAD_SetVRes(WPAD_CHAN_0, rmode->fbWidth, rmode->xfbHeight);
  ISFS_Initialize();

  u32 ever_wpad = 0, ever_ext = 0, ever_gc = 0;
  float max_g = 0.0f, min_roll = 999, max_roll = -999, min_pitch = 999, max_pitch = -999;
  int ir_valid_frames = 0, frames = 0;
  float ir_min_x = 9999, ir_max_x = -9999, ir_min_y = 9999, ir_max_y = -9999;
  int nun_min_x = 255, nun_max_x = 0, nun_min_y = 255, nun_max_y = 0;
  int cc_lmin_x = 64, cc_lmax_x = 0, cc_rmin_x = 64, cc_rmax_x = 0;
  int ext_type_seen = 0;
  char text[1536];

  while (1)
  {
    WPAD_ScanPads();
    PAD_ScanPads();
    WPADData* d = WPAD_Data(WPAD_CHAN_0);
    const u32 held = WPAD_ButtonsHeld(WPAD_CHAN_0);
    const u16 gc = PAD_ButtonsHeld(0);
    ever_wpad |= held & 0xFFFF;
    ever_ext |= held & 0xFFFF0000;
    ever_gc |= gc;
    frames++;

    if (d->ir.valid)
    {
      ir_valid_frames++;
      if (d->ir.x < ir_min_x) ir_min_x = d->ir.x;
      if (d->ir.x > ir_max_x) ir_max_x = d->ir.x;
      if (d->ir.y < ir_min_y) ir_min_y = d->ir.y;
      if (d->ir.y > ir_max_y) ir_max_y = d->ir.y;
    }
    const float g = sqrtf(d->gforce.x * d->gforce.x + d->gforce.y * d->gforce.y +
                          d->gforce.z * d->gforce.z);
    if (g > max_g) max_g = g;
    if (d->orient.roll < min_roll) min_roll = d->orient.roll;
    if (d->orient.roll > max_roll) max_roll = d->orient.roll;
    if (d->orient.pitch < min_pitch) min_pitch = d->orient.pitch;
    if (d->orient.pitch > max_pitch) max_pitch = d->orient.pitch;

    ext_type_seen |= 1 << (d->exp.type & 7);
    if (d->exp.type == WPAD_EXP_NUNCHUK)
    {
      const int x = d->exp.nunchuk.js.pos.x, y = d->exp.nunchuk.js.pos.y;
      if (x < nun_min_x) nun_min_x = x;
      if (x > nun_max_x) nun_max_x = x;
      if (y < nun_min_y) nun_min_y = y;
      if (y > nun_max_y) nun_max_y = y;
    }
    else if (d->exp.type == WPAD_EXP_CLASSIC)
    {
      const int lx = d->exp.classic.ljs.pos.x, rx = d->exp.classic.rjs.pos.x;
      if (lx < cc_lmin_x) cc_lmin_x = lx;
      if (lx > cc_lmax_x) cc_lmax_x = lx;
      if (rx < cc_rmin_x) cc_rmin_x = rx;
      if (rx > cc_rmax_x) cc_rmax_x = rx;
    }

    if ((frames % 60) == 0)
    {
      const int n = snprintf(
          text, sizeof(text),
          "frames %d\n"
          "wpad_status %d ext %s ext_seen_mask %d\n"
          "buttons_held %08x ever_wpad %08x ever_ext %08x\n"
          "ir_valid_frames %d ir_now %d %.0f %.0f ir_x %.0f..%.0f ir_y %.0f..%.0f\n"
          "roll %.0f..%.0f pitch %.0f..%.0f now %.0f %.0f\n"
          "gforce_now %.2f max_g %.2f\n"
          "nunchuk_x %d..%d nunchuk_y %d..%d\n"
          "classic_lx %d..%d classic_rx %d..%d\n"
          "gc_held %04x ever_gc %04x\n",
          frames, d->err, ext_name(d->exp.type), ext_type_seen, held, ever_wpad, ever_ext,
          ir_valid_frames, d->ir.valid, d->ir.x, d->ir.y, ir_min_x, ir_max_x, ir_min_y, ir_max_y,
          min_roll, max_roll, min_pitch, max_pitch, d->orient.roll, d->orient.pitch, g, max_g,
          nun_min_x, nun_max_x, nun_min_y, nun_max_y, cc_lmin_x, cc_lmax_x, cc_rmin_x, cc_rmax_x,
          gc, ever_gc);
      printf("\x1b[2;0H%s", text);
      ISFS_Delete("/tmp/iridia_input.txt");
      ISFS_CreateFile("/tmp/iridia_input.txt", 0, 3, 3, 3);
      const s32 fd = ISFS_Open("/tmp/iridia_input.txt", ISFS_OPEN_WRITE);
      if (fd >= 0)
      {
        static char buf[1536] ATTRIBUTE_ALIGN(32);
        memcpy(buf, text, n);
        ISFS_Write(fd, buf, n);
        ISFS_Close(fd);
      }
    }

    if ((held & WPAD_BUTTON_HOME) || (gc & PAD_BUTTON_START))
      break;
    VIDEO_WaitVSync();
  }
  ISFS_Deinitialize();
  return 0;
}
