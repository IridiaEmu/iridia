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
