// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: App Store (GCEMU_NO_JIT) build of the iOS memory utilities.
//
// Deliberately empty. With GCEMU_NO_JIT the executable-memory API (AllocateExecutableMemory,
// the W^X toggles, and the Legacy / LuckNoTXM / LuckTXM debugger and TXM paths) is not
// declared in MemoryUtil.h, and CodeBlock refuses to instantiate executable blocks. Anything
// that still needs JIT memory therefore fails to compile instead of shipping. The iOS
// implementations those builds used (MemoryUtil_iOS*.cpp, JITMemoryTracker) aren't compiled.
// Plain pages (AllocateMemoryPages etc.) come from MemoryUtil.cpp as on every platform.

// Build-flavor marker checked by scripts/verify_no_jit.sh: proves the shipped core was
// compiled with GCEMU_NO_JIT (exported and `used`, so dead-stripping keeps it).
extern "C" __attribute__((used, visibility("default"))) const char gcemu_core_flavor[] = "gcemu-no-jit-v1";
