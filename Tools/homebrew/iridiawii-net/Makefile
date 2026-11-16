# SPDX-License-Identifier: GPL-2.0-or-later
# Iridia Wii offline test: original Wii program that tries to bring up the network and logs
# what happens (Iridia must answer "no network" without hanging). make -> iridiawii-net.dol
ifeq ($(strip $(DEVKITPPC)),)
$(error "Set DEVKITPPC (e.g. export DEVKITPPC=/opt/devkitpro/devkitPPC)")
endif
include $(DEVKITPPC)/wii_rules

TARGET  := iridiawii-net
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
