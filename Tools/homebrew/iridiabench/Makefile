# SPDX-License-Identifier: GPL-2.0-or-later
# IridiaBench: original GameCube CPU benchmark for Iridia's performance work.
#   make SCALE=1|2|4    -> iridiabench-x$(SCALE).dol
ifeq ($(strip $(DEVKITPPC)),)
$(error "Set DEVKITPPC (e.g. export DEVKITPPC=/opt/devkitpro/devkitPPC)")
endif
include $(DEVKITPPC)/gamecube_rules

SCALE   ?= 1
TARGET  := iridiabench-x$(SCALE)
BUILD   := build-x$(SCALE)
CFLAGS  := -O2 -Wall $(MACHDEP) -I$(DEVKITPRO)/libogc/include -DBENCH_SCALE=$(SCALE)
LDFLAGS := $(MACHDEP) -Wl,-Map,$(BUILD)/$(TARGET).map
LIBS    := -L$(DEVKITPRO)/libogc/lib/cube -logc -lm

$(TARGET).dol: $(BUILD)/$(TARGET).elf
	elf2dol $< $@

$(BUILD)/$(TARGET).elf: $(BUILD)/main.o
	$(CC) $^ $(LDFLAGS) $(LIBS) -o $@

$(BUILD)/main.o: source/main.c
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf build-x* iridiabench-x*.dol
.PHONY: clean
