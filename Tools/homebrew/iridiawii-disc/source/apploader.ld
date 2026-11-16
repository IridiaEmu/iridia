/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Iridia test apploader: one flat image at 0x81200000, entry first. */
ENTRY(ap_entry)
SECTIONS
{
  . = 0x81200000;
  .text : { *(.text.entry) *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) *(.sdata*) *(.sbss*) *(.bss*) }
  /DISCARD/ : { *(.comment) *(.eh_frame*) }
}
