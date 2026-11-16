# SPDX-License-Identifier: GPL-2.0-or-later
# IridiaBench: original GameCube CPU benchmark for Iridia's performance work.
#   make SCALE=1|2|4                -> iridiabench-x$(SCALE).dol (GameCube)
#   make PLATFORM=wii SCALE=16      -> iridiabench-wii-x16.dol (same workload, Wii mode)
#   make PLATFORM=wii MEM2=1 ...    -> iridiabench-wii-mem2-x16.dol (memory kernel data in MEM2)
#   make PLATFORM=wii WPAD=1 ...    -> iridiabench-wii-wpad-x16.dol (also reads the Wii Remote every frame)
#   make FREERUN=1 ...              -> iridiabench-free-x16.dol / iridiabench-wii-free-x16.dol (no vsync
#                                      wait: pure CPU throughput, compare host time per frame)
#   ./build_all.sh                  -> every variant the Mac A/Bs use
ifeq ($(strip $(DEVKITPPC)),)
$(error "Set DEVKITPPC (e.g. export DEVKITPPC=/opt/devkitpro/devkitPPC)")
endif

SCALE    ?= 1
PLATFORM ?= cube
MEM2     ?= 0
WPAD     ?= 0
FREERUN  ?= 0
ifeq ($(PLATFORM),wii)
include $(DEVKITPPC)/wii_rules
ifeq ($(MEM2),1)
TARGET  := iridiabench-wii-mem2-x$(SCALE)
else ifeq ($(WPAD),1)
TARGET  := iridiabench-wii-wpad-x$(SCALE)
else ifeq ($(FREERUN),1)
TARGET  := iridiabench-wii-free-x$(SCALE)
else
TARGET  := iridiabench-wii-x$(SCALE)
endif
LIBDIR  := wii
else
include $(DEVKITPPC)/gamecube_rules
ifeq ($(FREERUN),1)
TARGET  := iridiabench-free-x$(SCALE)
else
TARGET  := iridiabench-x$(SCALE)
endif
LIBDIR  := cube
endif
BUILD   := build-$(TARGET)
CFLAGS  := -O2 -Wall $(MACHDEP) -I$(DEVKITPRO)/libogc/include -DBENCH_SCALE=$(SCALE) -DBENCH_MEM2=$(MEM2) -DBENCH_WPAD=$(WPAD) -DBENCH_FREERUN=$(FREERUN)
LDFLAGS := $(MACHDEP) -Wl,-Map,$(BUILD)/$(TARGET).map
LIBS    := -L$(DEVKITPRO)/libogc/lib/$(LIBDIR) -logc -lm
ifeq ($(WPAD),1)
LIBS    := -L$(DEVKITPRO)/libogc/lib/$(LIBDIR) -lwiiuse -lbte -logc -lm
endif

$(TARGET).dol: $(BUILD)/$(TARGET).elf
	elf2dol $< $@

$(BUILD)/$(TARGET).elf: $(BUILD)/main.o
	$(CC) $^ $(LDFLAGS) $(LIBS) -o $@

$(BUILD)/main.o: source/main.c
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf build-* iridiabench-*.dol
.PHONY: clean
