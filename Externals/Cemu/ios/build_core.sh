#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Iridia: builds the Wii U core (Cemu, interpreter only, no JIT) for iOS as one dynamic framework,
# build/xcframework/IridiaCafeCore.xcframework, which the app embeds like PVlibDolphin.
#   Externals/Cemu/ios/build_core.sh [iphoneos|iphonesimulator|all]      (default: all)
#
# Libraries: the vcpkg packages in vcpkg.json, built with the triplets in ios/triplets (iOS 26.0 minimum), in Externals/Cemu/ios/vcpkg_installed/<platform>/<triplet>/. To build them:
#   VCPKG_ROOT=<vcpkg checkout> Externals/Cemu/ios/build_core.sh deps
#
# The framework exports only the bridge classes (CemuBridge, CemuTitle, CemuPerf), so the core's own copies of
# fmt, zlib, zstd, libpng and the rest never meet Dolphin's. The no-JIT check runs on every framework built.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CEMU="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$CEMU/../.." && pwd)"
OUT="$ROOT/build/xcframework"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"   # keep MacPorts (/opt/local) out
MIN_IOS=26.0   # the app's minimum
TARGETS="CemuIOSBridge CemuCafe CemuCommon CemuComponents CemuConfig CemuInput CemuAudio CemuUtil CemuResource imguiImpl ih264d zarchive"
CEMU_LIBS="src/libCemuIOSBridge.a src/Cafe/libCemuCafe.a src/Common/libCemuCommon.a src/Cemu/libCemuComponents.a
  src/config/libCemuConfig.a src/input/libCemuInput.a src/audio/libCemuAudio.a src/util/libCemuUtil.a
  src/resource/libCemuResource.a src/imgui/libimguiImpl.a"
OTHER_LIBS="dependencies/ih264d/libih264d.a dependencies/ZArchive/libzarchive.a"
VCPKG_LIBS="boost_atomic boost_chrono boost_container boost_context boost_date_time boost_filesystem boost_nowide
  boost_program_options boost_random boost_system boost_thread crypto curl fmt glslang glslang-default-resource-limits
  GenericCodeGen MachineIndependent OSDependent SPIRV png16 pugixml ssl z zip zstd"
FRAMEWORKS="Metal QuartzCore GameController Security SystemConfiguration CFNetwork AudioToolbox AVFoundation Foundation UIKit"

triplet() { [[ $1 == iphoneos ]] && echo arm64-ios-release || echo arm64-ios-simulator-release; }

deps() {
  : "${VCPKG_ROOT:?set VCPKG_ROOT to a vcpkg checkout}"
  for p in iphoneos iphonesimulator; do
    "$VCPKG_ROOT/vcpkg" install --x-manifest-root="$HERE" --overlay-triplets="$HERE/triplets" \
      --triplet "$(triplet $p)" --x-install-root="$HERE/vcpkg_installed/$p"
  done
}

build_platform() {
  local p="$1" t; t="$(triplet "$p")"
  local vi="$HERE/vcpkg_installed/$p/$t"
  [[ -d "$vi/lib" ]] || { echo "missing $vi (run: VCPKG_ROOT=... $0 deps)" >&2; exit 1; }
  local bd="$CEMU/build-$p"
  local sysroot=(); [[ $p == iphonesimulator ]] && sysroot=(-DCMAKE_OSX_SYSROOT=iphonesimulator)
  cmake -S "$CEMU" -B "$bd" -G Ninja -DCMAKE_SYSTEM_NAME=iOS ${sysroot[@]+"${sysroot[@]}"} \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MACOSX_BUNDLE=OFF -DENABLE_VCPKG=OFF -DCMAKE_PREFIX_PATH="$vi" -DCMAKE_FIND_ROOT_PATH="$vi" \
    -DENABLE_WXWIDGETS=OFF -DENABLE_SDL=OFF -DENABLE_HIDAPI=OFF -DENABLE_LIBUSB=OFF -DENABLE_VULKAN=OFF \
    -DENABLE_OPENGL=OFF -DENABLE_METAL=ON -DENABLE_DISCORD_RPC=OFF -DENABLE_CUBEB=OFF \
    -DCEMU_NO_JIT=ON -DCEMU_TBI=ON -DIRIDIA_SHIP=ON > "$bd.configure.log" 2>&1 \
    || { tail -30 "$bd.configure.log"; exit 1; }
  # shellcheck disable=SC2086
  cmake --build "$bd" --target $TARGETS > "$bd.build.log" 2>&1 || { grep -E "error:" "$bd.build.log" | head -20; exit 1; }

  # Link everything into one dynamic library inside a framework.
  local fw="$bd/fw/IridiaCafeCore.framework"
  mkdir -p "$fw/Headers" "$fw/Modules"
  local sdk; sdk="$(xcrun --sdk "$p" --show-sdk-path)"
  local target; [[ $p == iphoneos ]] && target="arm64-apple-ios$MIN_IOS" || target="arm64-apple-ios$MIN_IOS-simulator"
  local args=()
  for l in $CEMU_LIBS; do args+=(-Wl,-force_load,"$bd/$l"); done
  for l in $OTHER_LIBS; do args+=("$bd/$l"); done
  for l in $VCPKG_LIBS; do args+=("-l$l"); done
  for f in $FRAMEWORKS; do args+=(-framework "$f"); done
  printf '%s\n' '_OBJC_CLASS_$_CemuBridge' '_OBJC_METACLASS_$_CemuBridge' '_OBJC_CLASS_$_CemuTitle' \
    '_OBJC_METACLASS_$_CemuTitle' '_OBJC_CLASS_$_CemuPerf' '_OBJC_METACLASS_$_CemuPerf' > "$bd/exports.txt"
  xcrun clang++ -target "$target" -isysroot "$sdk" -dynamiclib -O3 -flto=thin \
    -install_name @rpath/IridiaCafeCore.framework/IridiaCafeCore \
    -Wl,-exported_symbols_list,"$bd/exports.txt" -Wl,-dead_strip -L"$vi/lib" "${args[@]}" -lc++ \
    -Wl,-object_path_lto,"$bd/lto.o" -o "$fw/IridiaCafeCore"
  xcrun dsymutil "$fw/IridiaCafeCore" -o "$bd/fw/IridiaCafeCore.framework.dSYM" >/dev/null 2>&1 || true
  xcrun strip -x "$fw/IridiaCafeCore"

  cp "$CEMU/src/ios_bridge/CemuBridge.h" "$fw/Headers/"
  printf '#import <IridiaCafeCore/CemuBridge.h>\n' > "$fw/Headers/IridiaCafeCore.h"
  printf 'framework module IridiaCafeCore {\n  umbrella header "IridiaCafeCore.h"\n  export *\n  module * { export * }\n}\n' \
    > "$fw/Modules/module.modulemap"
  # Cemu's data: translations, the Noto shared fonts (SIL OFL) and the per-game profiles.
  mkdir -p "$fw/CemuData"
  rsync -a --delete "$CEMU/bin/resources/" "$fw/CemuData/resources/"
  rsync -a --delete "$CEMU/bin/gameProfiles/" "$fw/CemuData/gameProfiles/"
  local plat; [[ $p == iphoneos ]] && plat=iPhoneOS || plat=iPhoneSimulator
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>IridiaCafeCore</string>
	<key>CFBundleIdentifier</key><string>app.iridia.cafecore</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>IridiaCafeCore</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$plat</string></array>
	<key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict>
</plist>
PLIST
  "$HERE/verify_no_jit.sh" "$fw/IridiaCafeCore"
}

WHAT="${1:-all}"
case "$WHAT" in
  deps) deps; exit 0 ;;
  iphoneos|iphonesimulator) build_platform "$WHAT" ;;
  all) build_platform iphoneos; build_platform iphonesimulator ;;
  *) echo "usage: $0 [iphoneos|iphonesimulator|all|deps]" >&2; exit 2 ;;
esac

mkdir -p "$OUT"
fws=()
for p in iphoneos iphonesimulator; do
  [[ -d "$CEMU/build-$p/fw/IridiaCafeCore.framework" ]] && fws+=(-framework "$CEMU/build-$p/fw/IridiaCafeCore.framework")
done
mkdir -p "$ROOT/.trash"
[[ -d "$OUT/IridiaCafeCore.xcframework" ]] && mv "$OUT/IridiaCafeCore.xcframework" "$ROOT/.trash/IridiaCafeCore.xcframework.$(date +%s)"
xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/IridiaCafeCore.xcframework" >/dev/null
echo "built $OUT/IridiaCafeCore.xcframework"
