# BENCHMARKS

Before/after numbers for every performance change. Newest at the bottom.

## Method

- **Device:** iPhone 16 Pro (iPhone17,1, A18 Pro), iOS 27.0 (24A435), plugged in, thermal state recorded per run.
- **Build:** Release (Non-Jailbroken), `GCEMU_NO_JIT` (Cached Interpreter, NEON vertex loader), free-team signing.
- **Harness:** benchmark mode (`Source/iOS/App/Common/Swift/GCEmu/GCEmuBenchmark.swift`):
  ```sh
  xcrun devicectl device process launch --device $UDID --terminate-existing \
    --payload-url "dolphinios://play?id=ID-<program>" com.yl4f87nwp8.gcemu.iCube \
    -- -gcemuBench 15 -gcemuBenchWarmup 5 -gcemuBenchLabel <label>
  ```
  - It writes `Documents/Benchmarks/<label>-….json` and quits; raw files are copied to `benchmarks/raw/`.
  - **3 runs per program**, reported as the mean.
- **Primary metric: `maxSpeed`.** This is the speed the emulator could reach with the frame limiter off (1.00 = full speed). It measures headroom even when a program already runs at 100%.
- Secondary: `speed` (actual), FPS, frame-time 1% low (200 Hz frame-time sampling from optimization #1 on; earlier runs sampled at 20 Hz).
- **Workloads (homebrew only, private testing):**
  - `gx-triangle`: minimal GX
  - `gx-gxSprites`: many sprites
  - `gx-neheGX-lesson06`: textured 3D
  - All three are 50 Hz programs.
- Limitation: these barely load the emulated CPU, so they mainly measure fixed per-frame overhead. Interpreter work needs real games (the user's own dumps), to be added.
- **Profiling:** `xcrun xctrace record --template 'Time Profiler' --device <hw UDID> --all-processes`, then `scripts/profile_summary.py` (atos-symbolicated, with "attributed to our code" view).

## Baseline (2026-10-11, commit a163cc2 + benchmark mode)

| Program | speed | maxSpeed (mean of 3) | maxSpeed range | FPS | thermal |
|---|---|---|---|---|---|
| gx-triangle | 1.000 | **1.901** | 1.876–1.922 (2.4%) | 50.0 | nominal |
| gx-gxSprites | 1.000 | **1.775** | 1.761–1.782 (1.2%) | 50.0 | nominal |
| gx-neheGX-lesson06 | 1.000 | **1.898** | 1.826–2.041 (11.4%) | 50.0 | nominal |

### Baseline profile: top 10 hotspots
Recorded during gxSprites, 15 s, iCube process, 7.29 s CPU sampled.

| # | Where | Share of iCube CPU | Notes |
|---|---|---|---|
| 1 | `Common::StallSignpost::IntervalGuard` (os_signpost → libsystem_trace/kernel) | ~19% | iCube stall-instrumentation markers, live in release builds |
| 2 | `Fifo::FifoManager::FlushGpu` (inlined signpost around the GPU-flush wait) | ~19% | same markers |
| 3 | `CoreTiming::CoreTimingManager::SleepUntil` (kernel sleep) | ~5% | expected: throttling while ahead of real time |
| 4 | Metal/IOGPU command submission (IOKit) | ~7% | GPU driver work |
| 5 | `Common::GetHash64_ARMv8_CRC32` | ~4% | texture/vertex hashing |
| 6 | Audio IO thread (AURemoteIO) | ~6% | audio output |
| 7 | CoreMotion thread | ~3% | motion sensor polling (only needed for Wii pointers) |
| 8 | `Metal::StateTracker::BeginRenderPass` / `StagingTexture::CopyFromTexture` | ~2% | render passes, EFB/XFB readback |
| 9 | `CommandProcessor::SetCPStatusFromGPU` | ~1% | CPU/GPU sync |
| 10 | Interpreter (`frspx`, `CachedInterpreter::LoadStoreFast*`) | ~3% | the actual PowerPC work (tiny in homebrew) |

Thread split: CPU thread 47%, Video thread 23%, workqueues 18.5%, audio 6%, CoreMotion 3%, main 2%.

## Optimizations

### 1. Compile out stall signposts; stall metrics off by default
- Change: `GCEMU_STALL_SIGNPOSTS` must be defined to build the os_signpost markers (default: no-ops). `MAIN_STALL_METRICS` defaults to false (debug-only counters).
- Caveat: Instruments enables these signposts while it records, so part of the profile share above is the profiler's own observer effect. The benchmark (no Instruments) shows the real-world effect.
- Measured with the 200 Hz frame-time sampler, which itself costs a little CPU, so this slightly understates the gain.
- Result (3 runs each; `scripts/bench_compare.py benchmarks/raw base opt1`):

| Program | maxSpeed before | after | change | speed | 1% low (ms) before → after |
|---|---|---|---|---|---|
| gx-triangle | 1.901 | **5.661** | **+197.8%** | 1.000 | 23.05 → 23.59 |
| gx-gxSprites | 1.775 | **4.570** | **+157.5%** | 1.000 | 23.89 → 25.08 |
| gx-neheGX-lesson06 | 1.898 | **5.233** | **+175.7%** | 1.000 | 23.10 → 23.46 |

- Why so large: the markers log to a custom os_log category ("com.icube.dol.stall"/"wait"). Apple keeps custom-category signposts **enabled by default** and records them to the in-memory log store whether or not Instruments is attached, so every throttle sleep, thread sleep and GPU-flush wait paid for os_signpost_id_generate + two interval calls.
- Frame pacing and actual speed are unchanged.

### 2. No motion-sensor polling for GameCube games
- Change: iCube enabled 200 Hz accelerometer and gyro polling (plus 60 Hz device motion) whenever the touch controls appeared, for the Wii Remote IR pointer. Now Wii-only (`EmulationScreen.swift`).
- Result (`bench_compare.py … opt1 opt2`): **no measurable speed change** (−4.1% to +4.5%, within this round's 2–11% run-to-run spread). Expected: CoreMotion runs on its own thread and core.
- Kept for **battery/heat**: the CoreMotion thread (≈3% of the process's CPU) is gone from the profile.

### 3. Compile the core for A13+ and tune for A18 (was `-mcpu=apple-a10`)
- Change: `BuildiOSXCFramework.py` uses `-mcpu=apple-a13 -mtune=apple-a18`. iOS 26, our minimum, only runs on A13 and newer, so ARMv8.4 (LSE atomics, RCPC, dot-product, FP16) is safe for every supported device. Full core rebuild (1,207 files).
- Result (`bench_compare.py … opt2 opt3`; new session after a break, device cooled):

| Program | opt2 | opt3 | change |
|---|---|---|---|
| gx-triangle | 5.738 | 5.794 | +1.0% |
| gx-gxSprites | 4.774 | 4.642 | −2.8% |
| gx-neheGX-lesson06 | 5.020 | 5.356 | +6.7% |

- **No measurable change** on homebrew (all within noise). These programs barely execute interpreter code, which is where newer instructions help. Kept (no regression; correct baseline); re-measure with real-game workloads.

### New workload: IridiaBench (our own CPU benchmark, `Tools/homebrew/iridiabench`)
- An original GPL program we own. Each frame does a fixed, game-like CPU workload (libogc paired-single matrix/vector math, a bytecode VM, strided array, linked-list and memcpy traffic), then draws 16 quads and waits for vsync. `SCALE` multiplies the work.
- Probe (1 run each): x1 2.38, x2 3.17, x4 2.54 (not CPU-bound; per-frame GPU sync dominates); **x16 1.24** (1% low 40 ms); **x32 1.03, speed 0.95** (CPU-bound). x16/x32 are the interpreter workloads from here on.
- **CPU-thread profile at x32:** FP and paired-single handlers ≈50% (`fmulsx` 9%, `ps_madd` 8.7%, `ps_muls0` 5.4%, `ps_mul` 4.6%, `ps_sum0` 4.1%, `NI_madd_msub` 4%, `fnmsubsx`, `fmaddsx`, `faddsx`…). `CachedInterpreter::LoadStoreFast` 16.6%, then micro-op pairs, block linking and branches.

### 4. iCube's off-by-default Cached Interpreter options (A/B, not adopted)
- iCube ships these opt-in flags marked "default OFF pending on-device A/B": DeadFprfElim, SpecializedFpArith, SpecializedFpLs, SpecializedPsq, PsqFastPath (and others).
- Tested by editing `Dolphin.ini [Core]` on device (`scripts/cir_ab.sh`, `scripts/cir_ab_interleaved.sh`).

| Variant (iridiabench-x16) | maxSpeed | vs baseline | note |
|---|---|---|---|
| baseline (sequential) | 1.105 | | thermal fair |
| CIRDeadFprfElim | 1.101 | −0.4% | fair/serious |
| CIRSpecializedFpArith | 1.095 | −0.9% | serious |
| baseline (interleaved, 45 s cool-down) | 1.175 | | serious |
| all five FP/PSQ flags together (interleaved) | 1.167 | −0.7% | serious |

- **No measurable gain**, so they stay off. Caveat: the phone reached "serious" thermal state during these runs (CPU throttled). The interleaved method keeps the comparison fair, but absolute numbers are lower than cool-device runs (x16 probe 1.24).
- Method note: sustained heavy runs heat the phone within ~5 minutes. Run A/B interleaved, with cool-downs, and record thermal state.

### 5. Branchy fast paths for the float rounding and classification helpers
- Finding (disassembly of `Interpreter::fmulsx`): clang if-converted `Force25Bit` (multiply-operand rounding, used by 13 FP/PS handlers) and `ClassifyFloat`/`ClassifyDouble` (FPRF after nearly every FP op). Every op computed the rare subnormal/NaN/inf paths too and then picked a result with `csel`.
- Change:
  - Common case first, with the rare cases behind a real branch. An empty `asm volatile("")` in the rare path stops the if-conversion and emits no instruction. `[[unlikely]]` alone was ignored, and a cold out-of-line helper made the handlers non-leaf (register save/restore), which gave back part of the gain.
  - `Interpreter_FPUtils.h` (Force25Bit), `Common/FloatUtils.cpp` (Classify*).
  - The `Force25Bit` hot path is now 6 instructions (was ~20 with the clz/shift subnormal math), and `fmulsx` stays a leaf.
- Correctness: bit-identical by construction, verified on the Mac against the original code:
  - Force25Bit: edge cases + 10^8 random patterns, 112,503,180 checked, 0 mismatches.
  - ClassifyFloat: **all 2^32 values**, 0 mismatches.
  - ClassifyDouble: 300,000,040 patterns, 0 mismatches.
- Result (`scripts/build_ab.sh`, interleaved A/B, 3 rounds, 45 s cool-down, iridiabench-x16):

| Build | maxSpeed | spread | change | thermal |
|---|---|---|---|---|
| A (before) | 1.208 | 1.3% | | fair/nominal |
| B (after) | **1.260** | 1.7% | **+4.3%** | fair/nominal |

### 6. Call-free NEON fast path for the 11 paired-single handlers (tried, reverted)
- Finding: `Interpreter::ps_madd` (and its siblings) saved and restored six register pairs on every call, because the NEON fast path shared a function with the scalar, validate and profiler code, which make calls.
- Experiment: a templated, call-free `PsNeonFast<Kind>` (the same guards and NEON math) and each original body moved, unchanged, into a `noinline ..._Full` that the handler tail-calls on a guard failure. The disassembly confirmed the prologue was gone.
- Result (interleaved A/B, 3 rounds, iridiabench-x16): 1.270 → 1.279, **+0.8%, within the 1.5–1.7% spread**.
- **Reverted:** no measurable gain, and staying close to iCube's code keeps merges easy. The register save/restore turned out to be cheap next to the rest of each op.

### 7. Full (monolithic) LTO instead of ThinLTO (tried, not adopted)
- Experiment: `DOL_FULL_LTO=1 BuildiOSXCFramework.py` (2,001 compile units with `-flto`, CMake IPO off).
- Result (interleaved A/B, 3 rounds, iridiabench-x16): 1.265 → 1.269, **+0.3%, within noise**.
- Not adopted: no measurable gain, and the build is much slower. ThinLTO stays the default.

### 8. Graphics API: Metal (direct) vs Vulkan (MoltenVK)
- Interleaved A/B via `GFXBackend` in Dolphin.ini (3 rounds each):

| Program | Metal | Vulkan | Vulkan vs Metal |
|---|---|---|---|
| gx-gxSprites | **4.707** (0.6%) | 4.411 (0.7%) | **−6.3%** |
| gx-neheGX-lesson06 | **5.317** (1.2%) | 5.139 (3.4%) | **−3.3%** |

- **Metal stays the default.**
- Graphics defaults were reviewed and kept (iCube's measured choices): Hybrid Ubershaders (no compile stutter), shaders precompiled before boot, native resolution, skip EFB access, deferred EFB copies, async present.

### Memory loads/stores (`CachedInterpreter::LoadStoreFast`, ~17% of the CPU thread): reviewed, no change
- Already a direct path: one `s_logical_pages[ea >> BAT_INDEX_SHIFT]` table load, an alignment check, a byte swap, and a `musttail` to the cold path. No cheap win without architectural changes (e.g. a fastmem-style host mapping).

### Profile after #1 and #2 (gxSprites, 15 s)
- Total iCube CPU: **6.36 s** (was 7.29 s) at the same 100% speed.
- Signpost and CoreMotion costs are gone.
- Threads: CPU 31%, Video 27%, Audio IO 20%, workqueues 19%, main 2%.

| # | Where | Share | Next step |
|---|---|---|---|
| 1 | `Common::GetHash64_ARMv8_CRC32` | ~7% | texture-cache hash sampling (accuracy vs speed) |
| 2 | `Mixer::MixerFifo::Mix` (audio thread) | ~8% | audio resampling cost; "lower audio quality" option |
| 3 | Metal render passes / staging copies / encoder flushes | ~3% | EFB/XFB copy path |
| 4 | `CommandProcessor::SetCPStatusFromGPU` | ~1.4% | CPU/GPU sync |
| 5 | Input expression evaluation (`ControlExpression`, `InputReference`) | ~1.5% | precompute; move to our lock-free pad state |
| 6 | Interpreter (`CachedInterpreter::LoadStoreFast*`, `frspx`) | small in homebrew | needs real-game workloads |
