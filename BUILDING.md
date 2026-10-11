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

One-time setup:
1. Add your Apple ID in Xcode > Settings > Accounts.
2. Connect the iPhone by cable, unlock it, and tap **Trust**.
3. On the iPhone, enable Settings > Privacy & Security > **Developer Mode** (it restarts).
4. Find your Personal Team ID. Xcode caches it after sign-in:
   ```sh
   plutil -convert xml1 -o - ~/Library/Preferences/com.apple.dt.Xcode.plist | grep -A1 '<key>teamID</key>' | grep -oE '>[A-Z0-9]{10}<' | tr -d '<>'
   ```
   `-allowProvisioningUpdates` makes xcodebuild create the Apple Development certificate and the profiles automatically.

Free accounts can't use the memory-limit entitlements or iCube's App Group, so generate in **free-team mode**. It uses `Project/Entitlements/FreeTeam.entitlements` and leaves out the thumbnail and Quick Look extensions:
```sh
TEAM=YL4F87NWP8                      # your Personal Team ID
PREFIX=com.yl4f87nwp8.gcemu          # any reverse-DNS prefix unique to you
cd ~/Projects/gc-emu/Source/iOS/App
TUIST_GCEMU_FREE_TEAM=1 TUIST_GCEMU_BUNDLE_PREFIX=$PREFIX tuist generate --no-open

UDID=$(xcrun devicectl list devices | grep physical | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
env PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" xcodebuild \
  -workspace iCube.xcworkspace -scheme "iCube (NJB)" \
  -configuration "Release (Non-Jailbroken)" -destination "id=$UDID" \
  -derivedDataPath ~/Projects/gc-emu/build-dd \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic build

APP="$HOME/Projects/gc-emu/build-dd/Build/Products/Release (Non-Jailbroken)-iphoneos/iCube.app"
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" $PREFIX.iCube
```
The first launch fails with "profile has not been explicitly trusted". On the iPhone, go to Settings > General > **VPN & Device Management**, tap your Apple ID, then **Trust**.

**Free-account limits:** apps expire after **7 days**, so rebuild and reinstall to renew them. There's also a cap of 3 sideloaded apps per device. These limits disappear with the paid Developer Program (Phase 9).

Controls Lab (Apps/ControlsLab) works the same way: `tuist generate`, then build with `GCEMU_TEAM=$TEAM GCEMU_BUNDLE_PREFIX=$PREFIX -allowProvisioningUpdates`.

## 6. No-JIT guarantee (always run before shipping)

`GCEMU_NO_JIT` is **ON by default** (root `CMakeLists.txt`) and is also defined for the app (`Project.swift`). It removes:
- the PowerPC JIT (JitArm64), the vertex-loader JIT (VertexLoaderARM64) and the ARM64 code emitter;
- every executable-memory, `MAP_JIT`, TXM, LuckNoTXM, Legacy and ptrace path (`MemoryUtil_iOS*.cpp` and JITMemoryTracker are swapped for `MemoryUtil_iOS_NoJIT.cpp`, and the API is undeclared);
- the app's JIT layer (`Common/Jit/**`, JitAcquisitionService), the "Waiting for JIT" prompt, StikDebug, and the LLDB/broker scripts.

`Common::CodeBlock` refuses to compile an executable block, so a code generator can't be linked back in by accident. The CPU runs the Cached Interpreter, and vertices use the NEON loader.

Verify any build:
```sh
scripts/verify_no_jit.sh path/to/App.app          # release: also fails on get-task-allow
scripts/verify_no_jit.sh --dev path/to/App.app    # development-signed device builds
scripts/verify_no_jit.sh path/to/App.ipa
```
It checks entitlements, imported symbols, defined symbols and strings, the core's `gcemu-no-jit-v1` marker, and bundled files. Exit code 0 means PASS.

## Known issues and fixes

| Symptom | Cause | Fix |
|---|---|---|
| `package product 'PLzmaSDK-product' cannot be used … unsafe build flags` | Xcode 27 rejects unsafeFlags in remote SwiftPM packages. iCube's CI uses Xcode 26.3. | PLzmaSDK removed from `Project.swift` (commit 4661f1d). We lose `.7z`/`.xz` import; `.zip` still works. |
| `cannot execute tool 'metal' due to missing Metal Toolchain` | Xcode 26+ ships the Metal compiler as a separate download | `xcodebuild -downloadComponent MetalToolchain` |
| App crashes at launch: `Library not loaded: @rpath/MoltenVK.framework … Trying to load an unsigned library` | Built with `CODE_SIGNING_ALLOWED=NO` | Use ad-hoc signing (see step 4) |
| `Personal development teams … do not support the Extended Virtual Addressing and Increased Debugging Memory Limit capabilities` | Free accounts can't use these entitlements | Generate with `TUIST_GCEMU_FREE_TEAM=1` (step 5) |
| `An Application Group with Identifier 'group.com.joemattiello.icube' is not available` | That App Group belongs to iCube's developer | Free-team mode drops it; the app falls back to standard defaults |
| `building for iOS Simulator, but linking in … built for iOS` | xcframework has no simulator slice | Rebuild the core with `-p SIMULATORARM64` |
