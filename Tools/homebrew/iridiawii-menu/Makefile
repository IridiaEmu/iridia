# SPDX-License-Identifier: GPL-2.0-or-later
# Iridia Wii system-title test: original Wii program that asks to go to the Wii Menu after
# a few seconds (Iridia must explain and stop, not hang). make -> iridiawii-menu.dol
ifeq ($(strip $(DEVKITPPC)),)
$(error "Set DEVKITPPC (e.g. export DEVKITPPC=/opt/devkitpro/devkitPPC)")
endif
include $(DEVKITPPC)/wii_rules

TARGET  := iridiawii-menu
BUILD   := build-$(TARGET)
CFLAGS  := -O2 -Wall $(MACHDEP) -I$(DEVKITPRO)/libogc/include
LDFLAGS := $(MACHDEP) -Wl,-Map,$(BUILD)/$(TARGET).map
LIBS    := -L$(DEVKITPRO)/libogc/lib/wii -logc -lm

$(TARGET).dol: $(BUILD)/$(TARGET).elf
	elf2dol $< $@

$(BUILD)/$(TARGET).elf: $(BUILD)/main.o
	$(CC) $^ $(LDFLAGS) $(LIBS) -o $@

$(BUILD)/main.o: source/main.c
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf build-* *.dol
.PHONY: clean
