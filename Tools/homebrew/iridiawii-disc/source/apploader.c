// SPDX-License-Identifier: GPL-2.0-or-later
//
// Iridia test apploader: an original, minimal Wii apploader for Iridia's own test disc.
//
// The console's boot code (Dolphin's HLE boot, here) loads this to 0x81200000 and calls its entry
// point to get three functions: init, main and close. main is called in a loop; each call asks for one
// read from the disc (destination, length, disc offset in 32-bit words on the Wii) and returns 1, then
// 0 when everything is loaded. close returns the program's entry point. This one reads the disc header
// (for the DOL's position), then the DOL header, then each of the DOL's sections. Everything lives in .data (no .bss) because only the image is loaded.

typedef unsigned int u32;
typedef void (*report_fn)(const char* fmt, ...);

typedef struct
{
  u32 text_offset[7], data_offset[11];
  u32 text_address[7], data_address[11];
  u32 text_size[7], data_size[11];
  u32 bss_address, bss_size, entry;
  u32 pad[7];
} DolHeader;

static DolHeader dol __attribute__((aligned(32), section(".data"))) = {{1}};
static u32 disc_header[0x440 / 4] __attribute__((aligned(32), section(".data"))) = {1};
static int step __attribute__((section(".data"))) = -1;
static u32 dol_offset __attribute__((section(".data"))) = 0;

static void ap_init(report_fn report)
{
  (void)report;
  step = -1;
}

static int ap_main(void** dst, u32* len, u32* offset)
{
  if (step == -1)
  {
    *dst = disc_header;
    *len = sizeof(disc_header);
    *offset = 0;
    step = 0;
    return 1;
  }
  if (step == 0)
  {
    dol_offset = disc_header[0x420 / 4];  // in words
    *dst = &dol;
    *len = sizeof(DolHeader);
    *offset = dol_offset;
    step = 1;
    return 1;
  }
  // Steps 1..18: the 7 text and 11 data sections, skipping empty ones.
  while (step <= 18)
  {
    const int i = step - 1;
    step++;
    const u32 size = i < 7 ? dol.text_size[i] : dol.data_size[i - 7];
    const u32 off = i < 7 ? dol.text_offset[i] : dol.data_offset[i - 7];
    const u32 addr = i < 7 ? dol.text_address[i] : dol.data_address[i - 7];
    if (size == 0)
      continue;
    *dst = (void*)addr;
    *len = size;
    *offset = dol_offset + (off >> 2);
    return 1;
  }
  return 0;
}

static void* ap_close(void)
{
  // Clear the program's .bss, then hand back its entry point.
  volatile unsigned char* p = (volatile unsigned char*)dol.bss_address;
  for (u32 i = 0; i < dol.bss_size; i++)
    p[i] = 0;
  return (void*)dol.entry;
}

__attribute__((section(".text.entry"))) void ap_entry(void (**init)(report_fn),
                                                     int (**main)(void**, u32*, u32*),
                                                     void* (**close)(void))
{
  *init = ap_init;
  *main = ap_main;
  *close = ap_close;
}
