// SPDX-License-Identifier: GPL-2.0-or-later

import Testing

@testable import IridiaPerformance

@Suite struct DeviceTierTests {
  @Test func iPhoneChips() {
    #expect(DeviceInfo(model: "iPhone12,1").chip == .a(13, pro: false))  // iPhone 11
    #expect(DeviceInfo(model: "iPhone12,8").chip == .a(13, pro: false))  // SE 2
    #expect(DeviceInfo(model: "iPhone13,2").chip == .a(14, pro: false))  // iPhone 12
    #expect(DeviceInfo(model: "iPhone14,7").chip == .a(15, pro: false))  // iPhone 14
    #expect(DeviceInfo(model: "iPhone15,2").chip == .a(16, pro: false))  // iPhone 14 Pro
    #expect(DeviceInfo(model: "iPhone16,1").chip == .a(17, pro: true))  // iPhone 15 Pro
    #expect(DeviceInfo(model: "iPhone17,1").chip == .a(18, pro: true))  // iPhone 16 Pro (the user's)
    #expect(DeviceInfo(model: "iPhone17,3").chip == .a(18, pro: false))  // iPhone 16
    #expect(DeviceInfo(model: "iPhone18,1").chip == .a(19, pro: true))  // iPhone 17 Pro
  }

  @Test func tiers() {
    #expect(DeviceInfo(model: "iPhone12,1").tier == .entry)
    #expect(DeviceInfo(model: "iPhone13,2").tier == .entry)
    #expect(DeviceInfo(model: "iPhone14,5").tier == .mid)
    #expect(DeviceInfo(model: "iPhone15,4").tier == .mid)
    #expect(DeviceInfo(model: "iPhone16,1").tier == .high)
    #expect(DeviceInfo(model: "iPhone17,1").tier == .high)
    #expect(DeviceInfo(model: "iPhone18,3").tier == .ultra)
    #expect(DeviceInfo(model: "iPad16,3").tier == .ultra)  // M4 iPad Pro
    #expect(DeviceInfo(model: "iPad13,4").tier == .high)  // M1 iPad Pro
    #expect(DeviceInfo(model: "iPad13,18").tier == .entry)  // iPad 10 (A14)
    #expect(DeviceInfo(model: "arm64").tier == .ultra)  // Simulator
    #expect(DeviceInfo(model: "iPhone99,9").tier == .ultra)  // future iPhones are fast
    #expect(DeviceInfo(model: "garbage").tier == .mid)
  }
}

@Suite struct PresetTests {
  @Test func nativeResolutionByDefaultOnOlderDevices() {
    #expect(PerformanceProfile.recommended(tier: .entry, mode: .balanced).internalResolution == 1)
    #expect(PerformanceProfile.recommended(tier: .mid, mode: .balanced).internalResolution == 1)
    #expect(PerformanceProfile.recommended(tier: .high, mode: .balanced).internalResolution == 2)
  }

  @Test func powerModesNeverRaiseCost() {
    for tier in DeviceTier.allCases {
      let bal = PerformanceProfile.recommended(tier: tier, mode: .balanced)
      for mode in [PowerMode.batterySaver, .maxPerformance] {
        let p = PerformanceProfile.recommended(tier: tier, mode: mode)
        #expect(p.internalResolution <= bal.internalResolution)
        #expect(p.maxAnisotropyLog2 <= bal.maxAnisotropyLog2)
        #expect(p.viSkip || !bal.viSkip)
      }
    }
  }

  @Test func settingsUseDolphinKeys() {
    let s = PerformanceProfile.recommended(tier: .high, mode: .balanced).settings
    #expect(s[.internalResolution] == "2")
    #expect(s[.shaderCompilationMode] == "2")
    #expect(s[.viSkip] == "False")
    #expect(EmulatorSetting.internalResolution.description == "GFX/Settings/InternalResolution")
  }

  @Test func stepDownReachesAFloor() {
    var p: PerformanceProfile? = PerformanceProfile.recommended(tier: .ultra, mode: .balanced)
    var steps = 0
    while let next = p?.steppedDown() { p = next; steps += 1; #expect(steps < 20) }
    #expect(p == PerformanceProfile(internalResolution: 1, shaderMode: .asyncSkipDrawing, maxAnisotropyLog2: 0, viSkip: true))
  }
}

@Suite struct ThermalGovernorTests {
  let base = PerformanceProfile.recommended(tier: .high, mode: .balanced)  // 2×, 4× AF, hybrid

  @Test func stepsDownWhenSeriousAndRecoversSlowly() {
    var g = ThermalGovernor(base: base, recoveryDelay: 60)
    #expect(g.update(level: .nominal, now: 0) == .none)
    guard case .apply(let p1) = g.update(level: .serious, now: 10) else { Issue.record("expected step"); return }
    #expect(p1.internalResolution == 1)
    #expect(g.steps == 1)
    // Cooling down: nothing until the recovery delay has passed.
    #expect(g.update(level: .fair, now: 20) == .none)
    #expect(g.update(level: .fair, now: 70) == .none)
    #expect(g.update(level: .nominal, now: 81) == .apply(base))
    #expect(g.steps == 0)
  }

  @Test func criticalDropsToFloorAndWarns() {
    var g = ThermalGovernor(base: base)
    guard case .applyAndWarn(let p) = g.update(level: .critical, now: 0) else { Issue.record("expected warn"); return }
    #expect(p.steppedDown() == nil)
    #expect(p.internalResolution == 1 && p.viSkip)
  }

  @Test func heatResetsRecoveryTimer() {
    var g = ThermalGovernor(base: base, recoveryDelay: 60)
    _ = g.update(level: .serious, now: 0)
    _ = g.update(level: .nominal, now: 10)
    _ = g.update(level: .serious, now: 50)  // hot again: second step, timer reset
    #expect(g.steps == 2)
    #expect(g.update(level: .nominal, now: 60) == .none)
    #expect(g.update(level: .nominal, now: 100) == .none)
    if case .apply = g.update(level: .nominal, now: 121) {} else { Issue.record("expected one step back") }
    #expect(g.steps == 1)
  }

  @Test func neverExceedsBase() {
    var g = ThermalGovernor(base: base, recoveryDelay: 1)
    for t in 0..<10 { _ = g.update(level: .nominal, now: Double(t)) }
    #expect(g.current == base)
  }
}

@Suite struct SpeedHackTests {
  @Test func catalogIsWellFormed() {
    let ids = SpeedHack.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    for h in SpeedHack.all {
      #expect(Set(h.on.keys) == Set(h.off.keys), "\(h.id) must set and reset the same keys")
      #expect(!h.detail.isEmpty)
      if h.risk == .high { #expect(!h.defaultOn, "\(h.id): high-risk hacks are never on by default") }
    }
  }
}
