# Iridia: performance evaluation (2026-10-12)

**What it is:** a GameCube emulator for iPhone, forked from iCube/Dolphin, built for the App Store with **no JIT**. The CPU runs on Dolphin's Cached Interpreter. `scripts/verify_no_jit.sh` passes on the current build: no JIT backends or code emitters, no executable-memory entitlements, no W^X/icache calls, and the core carries the `GCEMU_NO_JIT` build marker. The only flag on the dev build is `get-task-allow`, which Xcode's development signing adds and App Store signing removes.

**Test device:** iPhone 16 Pro (A18 Pro), iOS 27.0. Graphics run on Metal.

## Real game: Twilight Princess (USA), the user's own dump
| Test | Result |
|---|---|
| Ordon, live profile while playing | Full speed. Emulated CPU thread ~37–53% busy (it finishes each frame early and waits). |
| Ordon, resolution sweep from a save state | **Full speed (30 fps) at every resolution:** 1x 640×528 (2.42× headroom), 3x (2.02×), 5x (1.75×), 8x 5120×4224 (1.58×) |
| Thermal | Stays "fair" in short runs. About 20 minutes of sustained load reaches "serious". |
| Not yet measured | Hyrule Field and Castle Town (expected to be the heaviest areas) |

Headroom = how fast it could run with the frame limiter off (1.0 = just full speed).

## Optimizations and what each one did
Measured with interleaved A/B runs and cool-downs.

| Change | Effect |
|---|---|
| Compiled out iCube's stall signposts (os_log markers live in release builds) | **+158–198%** headroom on homebrew |
| Branchy fast paths for float rounding/classification (bit-identical, verified on all 2^32 floats) | +4.3% on CPU-bound benchmark |
| Profile-guided optimization (PGO) | +3.3–4.9% on all workloads |
| Metal instead of Vulkan/MoltenVK | Metal 3.3–6.3% faster (kept) |
| Audio mixer skips 9 unused streams (bit-identical output) | Audio thread CPU −67% in Twilight Princess |
| No motion-sensor polling for GameCube games | Battery and heat only |
| Tried and rejected (within noise) | Full LTO (+0.3%), call-free NEON paired-singles (+0.8%), iCube's experimental CIR FP flags (−0.4 to −0.9%), A13 target flags (neutral, kept) |

## Where the time goes now
- **Emulated CPU (interpreter):** ~70–78% of app CPU. The hot code is memory loads/stores (`LoadStoreFast`, ~8–10%), paired-single math and block linking.
- **Graphics thread:** ~14–18%.
- **Audio:** ~3% after the mixer fix (was ~13%).
- **Limit:** without JIT the emulated CPU is the bottleneck. GPU cost only shows at high resolutions.

## Caveats
- Only one commercial game has been measured, in one light area.
- Most A/B numbers come from homebrew and our own CPU benchmark (IridiaBench).
- Single device (iPhone 16 Pro); older phones are untested.
