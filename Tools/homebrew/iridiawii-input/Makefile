# SPDX-License-Identifier: GPL-2.0-or-later
# Iridia Wii input test: original Wii program that shows and logs what the emulated Wii Remote,
# Nunchuk, Classic Controller and GameCube pad report. make -> iridiawii-input.dol
ifeq ($(strip $(DEVKITPPC)),)
$(error "Set DEVKITPPC (e.g. export DEVKITPPC=/opt/devkitpro/devkitPPC)")
endif
include $(DEVKITPPC)/wii_rules

TARGET  := iridiawii-input
BUILD   := build-$(TARGET)
CFLAGS  := -O2 -Wall $(MACHDEP) -I$(DEVKITPRO)/libogc/include
LDFLAGS := $(MACHDEP) -Wl,-Map,$(BUILD)/$(TARGET).map
LIBS    := -L$(DEVKITPRO)/libogc/lib/wii -lwiiuse -lbte -logc -lm

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
