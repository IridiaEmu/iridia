// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
/// `showValidation` is a parameter, not state: search builds the model with `true` so the validators are searchable.
enum PerformanceTuningModelBuilder {
  typealias Apply = (PerformanceTuningChange) -> Void

  static func make(state: PerformanceTuningState, showValidation: Bool, apply: @escaping Apply) -> MenuModel {
    var sections = [cpuOptions(state, apply)]
    if state.showEngineOpts {
      sections.append(engineOptimizations(state, apply))
      sections.append(validation(state, showValidation, apply))
    } else {
      sections.append(MenuSection(id: "engine-optimizations-hint", header: L("Engine Optimizations"), items: [
        SettingsRow.action("engine-optimizations-hint", L("Select a Cached Interpreter engine"),
                           L("Select Cached Interpreter or Cached Interpreter (IR) as the CPU engine above to configure optimizations. The plain Interpreter and JIT engines don't use these."),
                           enabled: false, run: {}),
      ]))
    }
    if state.showCIROpts {
      sections.append(MenuSection(id: "diagnostics", header: L("Diagnostics"), items: [
        flagRow("cir-profiler", L("CIR Hot-Block Profiler"), .cirProfile, state, apply,
                L("For developers: records where CPU time goes. Restart the game, play the slow part, then use Copy State.")),
      ]))
    }
    sections.append(MenuSection(id: "clock-override", header: L("Clock Override"), items: [
      flagRow("cpu-clock-enabled", L("Enable Emulated CPU Clock Override"), .cpuClockEnabled, state, apply,
              L("Changes the GameCube CPU's speed. Higher can smooth out some games but costs speed. Anything other than 100% can break games."),
              enabled: state.cpuClockOverride == .none),
      percentStepper("cpu-clock-percent", L("Emulated CPU Clock"), state.cpuClockPercent, on: state.cpuClockEnabled, override: state.cpuClockOverride,
                     L("The emulated CPU's clock as a percentage of normal. Only used while the override above is enabled."),
                     set: { apply(.cpuClockPercent($0)) }),
    ]))
    sections.append(MenuSection(id: "vbi-override", header: L("Override VBI Frequency"), items: [
      flagRow("vbi-enabled", L("Enable VBI Frequency Override"), .vbiEnabled, state, apply,
              L("Changes the game's frame rate. Lower is easier on your device. Higher can look smoother but may speed up gameplay."),
              enabled: state.vbiOverride == .none),
      percentStepper("vbi-percent", L("VBI Frequency"), state.vbiPercent, on: state.vbiEnabled, override: state.vbiOverride,
                     L("The emulated video-interface frequency as a percentage of normal. Only used while the override above is enabled."),
                     set: { apply(.vbiPercent($0)) }),
    ]))
    return MenuModel(sections: sections)
  }

  // MARK: Sections

  private static func cpuOptions(_ state: PerformanceTuningState, _ apply: @escaping Apply) -> MenuSection {
    let engines = state.jitAvailable ? CpuEngine.allCases : [.interpreter, .cachedInterpreter, .cachedInterpreterIR]
    return MenuSection(
      id: "cpu-options", header: L("CPU Options"),
      footer: state.jitAvailable
        ? L("These options control the emulated GameCube CPU, which is almost always what limits speed in Iridia.")
        : L("Iridia always uses the Cached Interpreter. The emulated CPU is almost always what limits speed, so these options matter more than graphics settings."),
      items: [
        SettingsRow.cycle("cpu-engine", L("CPU Emulation Engine"), engines.map { ($0.label, $0) }, state.effectiveEngine,
              state.jitAvailable
                ? L("Cached Interpreter is fast. The plain Interpreter is the most accurate but far too slow for normal play.")
                : L("Iridia uses the Cached Interpreter, the fastest engine allowed on the App Store."),
              set: { apply(.cpuEngine($0)) }),
        flagRow("mmu", L("Enable MMU"), .mmu, state, apply,
                L("Needed by a few games, such as some Star Wars titles, but slows everything down. Only turn on for a game that needs it.")),
        flagRow("adaptive-clock", L("Adaptive Clock (auto VI/CPU)"), .adaptiveClock, state, apply,
                L("Slows the emulated CPU a little when a game can't keep up, instead of stuttering. Experimental. Takes effect the next time you start a game.")),
        SettingsRow.cycle("vertex-loader", L("Vertex Loader"), VertexLoaderMode.allCases.map { ($0.label, $0.rawValue) }, state.vertexLoaderMode,
              L("Leave on NEON SIMD, the fastest. Takes effect the next time you start a game."),
              set: { apply(.vertexLoaderMode($0)) }),
        flagRow("pause-on-panic", L("Pause on Panic"), .pauseOnPanic, state, apply,
                L("Pauses the game with a message when the emulator hits an internal error. For debugging.")),
        flagRow("accurate-cpu-cache", L("Accurate CPU Cache (slower)"), .writeBackCache, state, apply,
                L("More accurate, but noticeably slower. Only for the few games that need it.")),
        flagRow("bypass-icache", L("Bypass Instruction Cache"), .disableICache, state, apply,
                L("Slightly faster, but can cause bugs in some games.")),
        flagRow("ci-prefetch", L("CachedInterpreter Prefetch (Apple Silicon)"), .cachedInterpreterPrefetch, state, apply,
                L("Experimental. Slower on current iPhones. Takes effect the next time you start a game.")),
        flagRow("neon-texture-decode", L("NEON Texture Decoder"), .neonTextureDecode, state, apply,
                L("Faster texture decoding. Takes effect the next time you start a game.")),
        flagRow("dcbz-hack", L("DCBZ Hack"), .lowDCBZ, state, apply,
                L("Can speed up a few games but breaks others. Only use it if you know a game needs it.")),
        flagRow("relaxed-idle", L("Relaxed Idle Loop Detection"), .relaxedIdleDetection, state, apply,
                L("Skips more of the time games spend waiting. Saves CPU and battery, and very rarely affects timing.")),
        flagRow("ff-ctr-idle", L("Fast-Forward CTR Idle Loops"), .fastForwardCtrIdle, state, apply,
                L("Skips another kind of waiting loop. Saves CPU, but may affect timing in a few games.")),
        flagRow("sync-on-skip-idle", L("Sync on Skip Idle"), .syncOnSkipIdle, state, apply,
                L("Keeps graphics in step when Iridia skips waiting loops. Turning it off is slightly faster but can cause glitches.")),
      ])
  }

  private static func engineOptimizations(_ state: PerformanceTuningState, _ apply: @escaping Apply) -> MenuSection {
    var items = [
      SettingsRow.destination("performance-ab", L("Performance A/B & Snapshots"),
                              L("Save and compare settings, for testing speed changes."),
                              view: AnyView(PerformanceABView().padBackNavigation())),
      SettingsRow.action("reset-optimizations", L("Reset Optimizations to Recommended"),
                         L("Puts every option below back to its default. Takes effect the next time you start a game."),
                         run: { apply(.resetOptimizationsToRecommended) }),
      // Shared: honored by BOTH the Cached Interpreter and the IR engine.
      flagRow("pic-load-store", L("PIC Load/Store"), .cirPicLoadStore, state, apply,
              L("Faster memory access. A large speed-up in many games. Takes effect the next time you start a game."), recommended: true),
      flagRow("specialized-ops", L("Specialized Ops"), .cirSpecializedOps, state, apply,
              L("Faster handling of common instructions. Takes effect the next time you start a game."), recommended: true),
      flagRow("block-linking", L("Block Linking"), .cirBlockLinking, state, apply,
              L("The biggest single speed-up. Takes effect the next time you start a game."), recommended: true),
      flagRow("dynamic-links", L("Dynamic Links"), .cirDynLinking, state, apply,
              L("Builds on Block Linking for a big speed-up in games like Wind Waker. Takes effect the next time you start a game."), recommended: true),
      flagRow("neon-paired-single-math", L("NEON Paired-Single Math"), .cirPsNeon, state, apply,
              L("Does some 3D maths two values at a time. Helps a few games. Takes effect the next time you start a game."), recommended: true),
    ]
    if state.showCIROpts {
      items += [
        flagRow("cir-fp-load-store-specialization", L("FP Load/Store Specialization"), .cirSpecializedFpLs, state, apply,
                L("Experimental. May help 3D-heavy games. Takes effect the next time you start a game.")),
        flagRow("cir-paired-single-load-store-specialization", L("Paired-Single Load/Store Specialization"), .cirSpecializedPsq, state, apply,
                L("Experimental. May help some 3D games. Takes effect the next time you start a game.")),
        flagRow("cir-fp-paired-single-arithmetic-specialization", L("FP / Paired-Single Arithmetic Specialization"), .cirSpecializedFpArith, state, apply,
                L("Experimental. May help 3D-heavy games. Takes effect the next time you start a game.")),
        flagRow("cir-micro-op-fusion", L("Micro-Op Fusion"), .cirMicroOpFusion, state, apply,
                L("Handles several simple instructions at once. Takes effect the next time you start a game."), recommended: true),
        flagRow("cir-dead-flag-elimination", L("Dead Flag Elimination"), .cirDeadFlagElim, state, apply,
                L("Experimental. Usually makes no difference. Takes effect the next time you start a game.")),
        flagRow("cir-dead-fprf-elimination", L("Dead FPRF Elimination"), .cirDeadFprfElim, state, apply,
                L("Experimental. Usually slower. Takes effect the next time you start a game.")),
        flagRow("cir-paired-single-float-fast-path", L("Paired-Single Float Fast-Path"), .cirPsqFastPath, state, apply,
                L("Experimental. May help some 3D games. Takes effect the next time you start a game.")),
        flagRow("cir-store-loop-memset-fast-path", L("Store-Loop (memset) Fast-Path"), .cirStoreLoopFF, state, apply,
                L("Experimental. Usually slower. Takes effect the next time you start a game.")),
        flagRow("cir-cache-management-loop-fast-forward", L("Cache-Management Loop Fast-Forward"), .cirCacheLoopFF, state, apply,
                L("Experimental. Usually makes no difference. Takes effect the next time you start a game.")),
      ]
    }
    if state.showIROpts {
      items += [
        flagRow("ir-constant-address-fusion", L("Constant-Address Fusion"), .cirIrConstFusion, state, apply,
                L("Experimental, IR engine only. Takes effect the next time you start a game.")),
        flagRow("ir-micro-op-fusion", L("Micro-Op Fusion"), .cirIrMicroOpFusion, state, apply,
                L("Experimental, IR engine only. Takes effect the next time you start a game.")),
        flagRow("ir-dead-cr-flag-elimination", L("Dead CR-Flag Elimination"), .cirIrDeadFlagElim, state, apply,
                L("Experimental, IR engine only. Takes effect the next time you start a game.")),
      ]
    }
    return MenuSection(
      id: "engine-optimizations", header: L("Engine Optimizations"),
      footer: state.showIROpts
        ? L("Speed options for the IR engine. The ones marked Recommended are on by default and should stay on. The others are experimental.")
        : L("Speed options for the CPU engine. The ones marked Recommended are on by default and should stay on. The others are experimental."),
      items: items)
  }

  /// Re-runs each optimisation against the reference interpreter. Each row is disabled until its parent optimisation is
  /// ON, so the "requires X" relationship is enforced, not just documented.
  private static func validation(_ state: PerformanceTuningState, _ showValidation: Bool, _ apply: @escaping Apply) -> MenuSection {
    var items = [
      SettingsRow.toggle("show-validation", L("Show Validation Options"), showValidation,
                         L("Shows checks that confirm each option gives correct results. Much slower. For developers."),
                         set: { apply(.showValidation($0)) }),
    ]
    if showValidation {
      items.append(validateRow("validate-neon-paired-single-math", L("NEON Paired-Single Math: Validate"), .cirPsNeonValidate, parent: .cirPsNeon, state, apply,
                               L("Double-runs each NEON paired-single op against the scalar computation and asserts both lanes are bit-identical. Requires NEON Paired-Single Math ON.")))
      if state.showCIROpts {
        items += [
          validateRow("cir-validate-specialized-ops", L("Specialized Ops: Validate"), .cirSpecializedOpsValidate, parent: .cirSpecializedOps, state, apply,
                      L("Double-runs every specialized op against the generic interpreter and flags any divergence. Requires Specialized Ops ON.")),
          validateRow("cir-validate-block-linking", L("Block Linking: Validate"), .cirBlockLinkingValidate, parent: .cirBlockLinking, state, apply,
                      L("Re-resolves each linked block through the dispatcher and flags stale or wrong-target links. Requires Block Linking ON.")),
          validateRow("cir-validate-micro-op-fusion", L("Micro-Op Fusion: Validate"), .cirMicroOpFusionValidate, parent: .cirMicroOpFusion, state, apply,
                      L("Runs the real interpreter alongside each fused block and flags any divergence in registers, flags, or condition codes. Requires Micro-Op Fusion ON.")),
          validateRow("cir-validate-dead-flag-elimination", L("Dead Flag Elimination: Validate"), .cirDeadFlagElimValidate, parent: .cirDeadFlagElim, state, apply,
                      L("Double-runs every eliminated op (flag computed vs skipped) and flags any divergence in a live condition field. Requires Dead Flag Elimination ON.")),
          validateRow("cir-validate-dead-fprf-elimination", L("Dead FPRF Elimination: Validate"), .cirDeadFprfElimValidate, parent: .cirDeadFprfElim, state, apply,
                      L("Double-runs every eliminated FP op (FPRF computed vs skipped) and flags any divergence in a result register or non-FPRF FPSCR bit. Requires Dead FPRF Elimination ON.")),
          validateRow("cir-validate-paired-single-float-fast-path", L("Paired-Single Float Fast-Path: Validate"), .cirPsqFastPathValidate, parent: .cirPsqFastPath, state, apply,
                      L("For every psq op that takes the fast path, derives the result both ways and flags any divergence (a mis-handled type, scale, or single-vs-paired case). Requires Paired-Single Float Fast-Path ON.")),
          validateRow("cir-validate-store-loop-fast-path", L("Store-Loop Fast-Path: Validate"), .cirStoreLoopFFValidate, parent: .cirStoreLoopFF, state, apply,
                      L("Runs the real per-store loop on a snapshot and asserts the filled memory and post-loop registers match the bulk fill. Requires Store-Loop Fast-Path ON.")),
          validateRow("cir-validate-cache-loop-fast-forward", L("Cache-Loop Fast-Forward: Validate"), .cirCacheLoopFFValidate, parent: .cirCacheLoopFF, state, apply,
                      L("Runs the real per-line cache loop on a snapshot and asserts the post-loop registers and CTR match the fast-forward. Requires Cache-Management Loop Fast-Forward ON.")),
        ]
      }
      if state.showIROpts {
        items += [
          validateRow("ir-validate-pic-load-store", L("PIC Load/Store: Validate"), .cirIrPicLoadStoreValidate, parent: .cirPicLoadStore, state, apply,
                      L("For every load/store that takes the PIC fast path, runs the plain interpreter access on a snapshot and asserts the loaded register / stored memory / update-form writeback are bit-identical. Requires PIC Load/Store ON.")),
          validateRow("ir-validate-specialized-ops", L("Specialized Ops: Validate"), .cirIrSpecializedOpsValidate, parent: .cirSpecializedOps, state, apply,
                      L("Dual-runs each specialized op vs the plain interpreter op and asserts bit-identical state. Requires Specialized Ops ON.")),
          validateRow("ir-validate-constant-address-fusion", L("Constant-Address Fusion: Validate"), .cirIrConstFusionValidate, parent: .cirIrConstFusion, state, apply,
                      L("For every fused pair, runs the original two ops and asserts the destination register matches the precomputed constant. Requires Constant-Address Fusion ON.")),
          validateRow("ir-validate-micro-op-fusion", L("Micro-Op Fusion: Validate"), .cirIrMicroOpFusionValidate, parent: .cirIrMicroOpFusion, state, apply,
                      L("For every fused run, runs the ops un-fused and asserts the resulting registers match. Requires Micro-Op Fusion ON.")),
          validateRow("ir-validate-dead-cr-flag-elimination", L("Dead CR-Flag Elimination: Validate"), .cirIrDeadFlagElimValidate, parent: .cirIrDeadFlagElim, state, apply,
                      L("Double-runs every eliminated op (CR computed vs skipped) and asserts the live CR fields match. Requires Dead CR-Flag Elimination ON.")),
        ]
      }
    }
    return MenuSection(id: "validation", header: L("Correctness Validation (developer, slow)"), items: items)
  }

  // MARK: Rows

  /// A Bool setting: its value is read from the snapshot through the flag, and a change emits that same flag.
  private static func flagRow(_ id: String, _ title: String, _ flag: PerformanceTuningFlag, _ state: PerformanceTuningState,
                              _ apply: @escaping Apply, _ description: String,
                              recommended: Bool = false, enabled: Bool = true) -> MenuItem {
    SettingsRow.toggle(id, title, state[keyPath: flag.keyPath], description, enabled: enabled,
                       badge: recommended ? L("Recommended") : nil, set: { apply(.flag(flag, $0)) })
  }

  /// A validation toggle, disabled until the optimisation it checks (`parent`) is ON.
  private static func validateRow(_ id: String, _ title: String, _ flag: PerformanceTuningFlag, parent: PerformanceTuningFlag,
                                  _ state: PerformanceTuningState, _ apply: @escaping Apply, _ description: String) -> MenuItem {
    flagRow(id, title, flag, state, apply, description, enabled: state[keyPath: parent.keyPath])
  }

  /// A clock percentage. While the adaptive clock or the game drives the key, the control is disabled and badged: a
  /// value set here would not apply until the override clears.
  private static func percentStepper(_ id: String, _ title: String, _ percent: Int, on: Bool, override: DOLConfigOverride,
                                     _ description: String, set: @escaping (Int) -> Void) -> MenuItem {
    SettingsRow.stepper(id, title, Double(percent), range: PerformanceTuningLimits.clockPercentRange, step: 1,
                        format: { "\(Int($0))%" }, description,
                        enabled: on && override == .none, badge: ConfigOverrideBadge.title(for: override), set: { set(Int($0)) })
  }
}
