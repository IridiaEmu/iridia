#pragma once

#include <boost/predef/os.h>
#if BOOST_OS_IOS
// Iridia Wii U app: iOS is Darwin like macOS; the core's macOS paths (POSIX, Mach, Metal) apply. The few
// AppKit-specific pieces check TARGET_OS_IPHONE / IOS themselves.
#undef BOOST_OS_MACOS
#define BOOST_OS_MACOS BOOST_OS_IOS
#endif
#include <cstdint>

#if BOOST_OS_WINDOWS
#include "Common/windows/platform.h"
#elif BOOST_OS_LINUX || BOOST_OS_BSD
#if BOOST_OS_LINUX
#include <byteswap.h>
#elif BOOST_OS_BSD
#include <endian.h>
#endif
#include <X11/Xlib.h>
#include <X11/extensions/Xrender.h>
#include <X11/Xutil.h>
#include "Common/unix/platform.h"
#elif BOOST_OS_MACOS
#include <libkern/OSByteOrder.h>
#include "Common/unix/platform.h"
#endif
