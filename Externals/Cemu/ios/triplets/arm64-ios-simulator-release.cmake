# Iridia: vcpkg's community triplet with the app's minimum iOS version (26.0), so no library needs a newer iOS.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_SYSROOT iphonesimulator)

set(VCPKG_BUILD_TYPE release)
set(VCPKG_OSX_DEPLOYMENT_TARGET 26.0)
# curl finds pipe2 in the iOS 27 SDK, but it only exists on iOS 27 and later.
if(PORT STREQUAL "curl")
  set(VCPKG_CMAKE_CONFIGURE_OPTIONS -DHAVE_PIPE2=0)
endif()
