# BUILDING

Exact steps to build gc-emu on macOS. Last verified 2026-10-11 on macOS 26.6.2 (Apple M4) with Xcode 27.0 (27A266a).

> For now, the app being built is iCube's app (our baseline). It will be replaced by our own SwiftUI app in Phase 5; these steps will be updated then.

## 1. One-time setup

```sh
# Xcode 27 from the Mac App Store, opened once to accept the license.
# Then the extra Xcode components:
xcodebuild -downloadPlatform iOS                 # iOS 27 Simulator runtime (~8 GB)
xcodebuild -downloadComponent MetalToolchain     # Metal shader compiler (~840 MB), required since Xcode 26

# Build tools
brew install cmake ninja git-lfs pkgconf ccache tuist bartycrouch
git lfs install
```

The repo already contains every submodule. On a fresh clone, run:
```sh
git clone --recurse-submodules <repo> gc-emu
# or, in an existing clone:
git submodule update --init --recursive
```

## 2. Build the emulation core (C++, from source)

Always rebuild the core from source. Never ship the prebuilt `PVlibDolphin.xcframework` that iCube commits.

```sh
cd ~/Projects/gc-emu
# MacPorts (/opt/local) is installed on this Mac. Keep it off PATH so CMake can't pick up its libraries.
env PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  python3 -I BuildiOSXCFramework.py -p OS64 SIMULATORARM64
```
- `OS64` = iPhone/iPad device, `SIMULATORARM64` = Apple Silicon Simulator.
- Output: `build/xcframework/PVlibDolphin.xcframework`.
- A first build takes about 30–60 minutes. Later builds are incremental.

## 3. Generate the Xcode workspace

```sh
cd Source/iOS/App
tuist install
tuist generate --no-open
```
Tuist (`Project.swift`) defines the project. The `.xcworkspace` and `.xcodeproj` are generated and gitignored.

## 4. Build and run in the iOS 27 Simulator

```sh
cd ~/Projects/gc-emu/Source/iOS/App
env PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" xcodebuild \
  -workspace iCube.xcworkspace -scheme "iCube (NJB)" \
  -configuration "Debug (Non-Jailbroken)" \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=27.0" \
  -derivedDataPath ~/Projects/gc-emu/build-dd \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  build

APP="$HOME/Projects/gc-emu/build-dd/Build/Products/Debug (Non-Jailbroken)-iphonesimulator/iCube.app"
xcrun simctl boot "iPhone 17"; open -a Simulator
xcrun simctl install "iPhone 17" "$APP"
xcrun simctl launch "iPhone 17" com.joemattiello.iCube-debug
```
- Use **ad-hoc signing** (`CODE_SIGN_IDENTITY="-"`), not `CODE_SIGNING_ALLOWED=NO`. If the build is unsigned, dyld refuses to load `MoltenVK.framework` and the app crashes at launch.

## 5. Build for your iPhone (free Apple ID)

_To be filled in once the first device build is verified._

## Known issues and fixes

| Symptom | Cause | Fix |
|---|---|---|
| `package product 'PLzmaSDK-product' cannot be used … unsafe build flags` | Xcode 27 rejects unsafeFlags in remote SwiftPM packages. iCube's CI uses Xcode 26.3. | PLzmaSDK removed from `Project.swift` (commit 4661f1d). We lose `.7z`/`.xz` import; `.zip` still works. |
| `cannot execute tool 'metal' due to missing Metal Toolchain` | Xcode 26+ ships the Metal compiler as a separate download | `xcodebuild -downloadComponent MetalToolchain` |
| App crashes at launch: `Library not loaded: @rpath/MoltenVK.framework … Trying to load an unsigned library` | Built with `CODE_SIGNING_ALLOWED=NO` | Use ad-hoc signing (see step 4) |
| `building for iOS Simulator, but linking in … built for iOS` | xcframework has no simulator slice | Rebuild the core with `-p SIMULATORARM64` |
