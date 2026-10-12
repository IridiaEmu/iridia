// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: exported entry points to the LLVM profile runtime for PGO training builds.
//
// compiler-rt's profile runtime defines __llvm_profile_write_file / __llvm_profile_set_filename
// with hidden visibility, so the linker can't export them from the PVlibDolphin dylib and the
// app's dlsym() probe (Source/iOS/App/Common/PGOFlush.c) never found them: no profile was set up
// or written. These default-visibility wrappers are compiled ONLY in DOL_PGO=generate builds
// (BuildiOSXCFramework.py defines GCEMU_PGO_GENERATE); in every other build this file is empty.

#ifdef GCEMU_PGO_GENERATE
extern "C" int __llvm_profile_write_file(void);
extern "C" void __llvm_profile_set_filename(const char*);

extern "C" __attribute__((visibility("default"), used)) int gcemu_pgo_write_file(void)
{
  return __llvm_profile_write_file();
}

extern "C" __attribute__((visibility("default"), used)) void gcemu_pgo_set_filename(const char* path)
{
  __llvm_profile_set_filename(path);
}
#endif
