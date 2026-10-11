// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import GCControlsCore

@Suite struct PadStateTests {
  @Test func packRoundTrip() {
    let s = PadState(
      buttons: [.a, .z, .dpadUp], triggerL: 12, triggerR: 255,
      stickX: 0, stickY: 255, cStickX: 77, cStickY: 200)
    #expect(PadState(packed: s.packed) == s)
  }

  @Test func buttonBitsMatchDolphin() {
    #expect(GCButtons.a.rawValue == 0x0100)
    #expect(GCButtons.start.rawValue == 0x1000)
    #expect(GCButtons.z.rawValue == 0x0010)
    #expect(GCButtons.dpadLeft.rawValue == 0x0001)
  }

  @Test func mergeTakesUnionAndStrongestStick() {
    var t = PadState.neutral
    t.buttons = [.a]; t.stickX = 200; t.triggerL = 40
    var p = PadState.neutral
    p.buttons = [.b]; p.stickX = 130; p.cStickY = 10; p.triggerL = 90
    let m = PadState(packed: PadState.merge(t.packed, p.packed))
    #expect(m.buttons == [.a, .b])
    #expect(m.stickX == 200)
    #expect(m.cStickY == 10)
    #expect(m.triggerL == 90)
  }

  @Test func storeIsPerPlayerAndClampsBadIndex() {
    let store = PadStateStore()
    var s = PadState.neutral
    s.buttons = [.start]
    store.publish(s, player: 2, source: .physical)
    #expect(PadState(packed: store.read(player: 2)).buttons == [.start])
    #expect(store.read(player: 0) == PadState.neutralPacked)
    #expect(store.read(player: 9) == PadState.neutralPacked)
    store.publish(s, player: -1, source: .touch)  // ignored, no crash
  }
}

@Suite struct AnalogTests {
  @Test func deadZoneHasNoJump() {
    let s = AnalogSettings(deadZone: 0.2, sensitivity: 1)
    #expect(AnalogMath.shape(x: 0.19, y: 0, s).x == 0)
    let justPast = AnalogMath.shape(x: 0.21, y: 0, s).x
    #expect(justPast > 0 && justPast < 0.05)
    #expect(abs(AnalogMath.shape(x: 1, y: 0, s).x - 1) < 1e-9)
  }

  @Test func outputStaysInUnitCircle() {
    let s = AnalogSettings(deadZone: 0, sensitivity: 2)
    let v = AnalogMath.shape(x: 1, y: 1, s)
    #expect((v.x * v.x + v.y * v.y).squareRoot() <= 1.0000001)
  }

  @Test func axisBytes() {
    #expect(AnalogMath.axisByte(0) == 128)
    #expect(AnalogMath.axisByte(1) == 255)
    #expect(AnalogMath.axisByte(-1) == 1)
    #expect(AnalogMath.triggerByte(1) == 255)
    #expect(AnalogMath.triggerByte(-3) == 0)
  }

  @Test func dpadEightWay() {
    #expect(AnalogMath.dpad(x: 1, y: 0) == [.dpadRight])
    #expect(AnalogMath.dpad(x: 0, y: 1) == [.dpadUp])
    #expect(AnalogMath.dpad(x: 0.7, y: 0.7) == [.dpadRight, .dpadUp])
    #expect(AnalogMath.dpad(x: -0.7, y: -0.7) == [.dpadLeft, .dpadDown])
    #expect(AnalogMath.dpad(x: 0.1, y: 0.1) == [])
  }
}

@Suite struct SkinTests {
  @Test func builtinsValidateAndRoundTrip() throws {
    for skin in BuiltinSkins.all {
      try skin.validate()
      let back = try ControllerSkin.decode(try skin.encoded())
      #expect(back == skin)
    }
  }

  @Test func builtinsCoverEveryInput() {
    for o in SkinOrientation.allCases {
      let inputs = Set(BuiltinSkins.default.layout(o).items.map(\.input))
      for r in SkinInput.required { #expect(inputs.contains(r), "\(o) missing \(r)") }
    }
  }

  @Test func builtinItemsDontOverlap() {
    for o in SkinOrientation.allCases {
      let items = BuiltinSkins.default.layout(o).items
      for (i, a) in items.enumerated() {
        for b in items[(i + 1)...] {
          let overlap = a.frame.x < b.frame.x + b.frame.width && b.frame.x < a.frame.x + a.frame.width
            && a.frame.y < b.frame.y + b.frame.height && b.frame.y < a.frame.y + a.frame.height
          #expect(!overlap, "\(o): \(a.id) overlaps \(b.id)")
        }
      }
    }
  }

  @Test func rejectsMissingInputs() throws {
    var skin = BuiltinSkins.default
    skin.portrait.items.removeAll { $0.input == .cStick }
    #expect(throws: SkinError.missingInputs(.portrait, [.cStick])) { try skin.validate() }
  }

  @Test func rejectsMissingImageAndDuplicates() {
    var skin = BuiltinSkins.default
    skin.portrait.items[0].image = "nope"
    #expect(throws: SkinError.missingImage("nope")) { try skin.validate() }
    skin = BuiltinSkins.default
    skin.landscape.items.append(skin.landscape.items[0])
    #expect(throws: SkinError.duplicateItemID(skin.landscape.items[0].id)) { try skin.validate() }
  }

  @Test func rejectsFutureVersion() {
    var skin = BuiltinSkins.default
    skin.formatVersion = 99
    #expect(throws: SkinError.unsupportedVersion(99)) { try skin.validate() }
  }

  @Test func overridesMoveScaleAndReset() throws {
    let base = BuiltinSkins.default.portrait
    let a = try #require(base.items.first { $0.id == "a" })
    let o = LayoutOverrides(items: ["a": ItemOverride(dx: 10, dy: -5, scale: 2, opacity: 0.5)], opacity: 0.7)
    let applied = o.apply(to: base)
    let a2 = try #require(applied.items.first { $0.id == "a" })
    #expect(a2.frame.width == a.frame.width * 2)
    #expect(abs(a2.frame.midX - (a.frame.midX + 10)) < 1e-9)
    #expect(abs(a2.frame.midY - (a.frame.midY - 5)) < 1e-9)
    #expect(applied.defaultOpacity == 0.7)
    #expect(o.itemOpacity("a") == 0.5)
    #expect(LayoutOverrides().apply(to: base) == base)

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = LayoutOverrideStore(directory: dir)
    store.save(o, skin: "s", orientation: .portrait)
    #expect(store.load(skin: "s", orientation: .portrait) == o)
    store.reset(skin: "s", orientation: .portrait)
    #expect(store.load(skin: "s", orientation: .portrait).isEmpty)
  }
}

@Suite struct SmartMappingTests {
  @Test func detection() {
    #expect(ControllerFamily.detect(productCategory: "Xbox One", vendorName: "Xbox Wireless Controller", hasRightStick: true, hasAnalogTriggers: true) == .xbox)
    #expect(ControllerFamily.detect(productCategory: "DualSense", vendorName: nil, hasRightStick: true, hasAnalogTriggers: true) == .dualSense)
    #expect(ControllerFamily.detect(productCategory: "DualShock 4", vendorName: nil, hasRightStick: true, hasAnalogTriggers: true) == .dualShock)
    #expect(ControllerFamily.detect(productCategory: "Switch Pro Controller", vendorName: nil, hasRightStick: true, hasAnalogTriggers: false) == .switchPro)
    #expect(ControllerFamily.detect(productCategory: "Nintendo Switch Joy-Con (L/R)", vendorName: nil, hasRightStick: true, hasAnalogTriggers: false) == .joyConPair)
    #expect(ControllerFamily.detect(productCategory: "Nintendo Switch Joy-Con (L)", vendorName: nil, hasRightStick: false, hasAnalogTriggers: false) == .joyConSingle)
    #expect(ControllerFamily.detect(productCategory: "MFi", vendorName: "Backbone One", hasRightStick: true, hasAnalogTriggers: true) == .backbone)
    #expect(ControllerFamily.detect(productCategory: "Something", vendorName: nil, hasRightStick: true, hasAnalogTriggers: true) == .generic)
  }

  @Test func byPositionIsSameEverywhere() {
    for f in ControllerFamily.allCases where f != .joyConSingle {
      let p = SmartMapping.profile(for: f, style: .byPosition).profile
      #expect(p.target(for: .buttonSouth) == .a)
      #expect(p.target(for: .buttonWest) == .b)
      #expect(p.target(for: .buttonEast) == .x)
      #expect(p.target(for: .buttonNorth) == .y)
      #expect(p.target(for: .leftStick) == .mainStick)
      #expect(p.target(for: .rightStick) == .cStick)
      #expect(p.target(for: .rightShoulder) == .z)
      #expect(p.target(for: .leftTrigger) == .l)
      #expect(p.target(for: .rightTrigger) == .r)
      #expect(p.target(for: .buttonMenu) == .start)
      #expect(p.target(for: .buttonOptions) == .appMenu)
    }
  }

  @Test func byLabelSwitchUsesPrintedLetters() {
    let (p, applied) = SmartMapping.profile(for: .switchPro, style: .byLabel)
    #expect(applied == .byLabel)
    #expect(p.target(for: .buttonEast) == .a)  // printed A is on the right
    #expect(p.target(for: .buttonSouth) == .b)
    #expect(p.target(for: .buttonNorth) == .x)
    #expect(p.target(for: .buttonWest) == .y)
  }

  @Test func byLabelXboxAndReportedLabels() {
    let x = SmartMapping.profile(for: .xbox, style: .byLabel).profile
    #expect(x.target(for: .buttonSouth) == .a)
    #expect(x.target(for: .buttonEast) == .b)
    // Runtime-reported letters win over the family assumption.
    let labels = FaceLabels.from(letters: ["A": .buttonEast, "B": .buttonSouth, "X": .buttonNorth, "Y": .buttonWest])
    let g = SmartMapping.profile(for: .generic, style: .byLabel, labels: labels).profile
    #expect(g.target(for: .buttonEast) == .a)
    #expect(FaceLabels.from(letters: ["A": .buttonEast]) == nil)
  }

  @Test func byLabelFallsBackOnPlayStation() {
    let (p, applied) = SmartMapping.profile(for: .dualSense, style: .byLabel)
    #expect(applied == .byPosition)
    #expect(p.target(for: .buttonSouth) == .a)
  }

  @Test func singleJoyCon() {
    let p = SmartMapping.profile(for: .joyConSingle, style: .byPosition).profile
    #expect(p.target(for: .leftShoulder) == .l)
    #expect(p.target(for: .rightShoulder) == .r)
    #expect(p.target(for: .rightStick) == .none)
  }

  @Test func mapperAnalogTriggersAndClick() {
    let m = SmartMapping.profile(for: .xbox, style: .byPosition).profile.compiled()
    var s = PhysicalSnapshot()
    s[.leftTrigger] = 0.5
    s[.rightTrigger] = 1.0
    s[.buttonSouth] = 1
    s[.buttonOptions] = 1
    s.leftStick = (1, 0)
    let (st, menu) = PhysicalMapper.map(s, m)
    #expect(st.triggerL == AnalogMath.triggerByte(0.5))
    #expect(!st.buttons.contains(.l))
    #expect(st.triggerR == 255 && st.buttons.contains(.r))
    #expect(st.buttons.contains(.a))
    #expect(menu)
    #expect(st.stickX == 255 && st.stickY == 128)
  }

  @Test func storeResolutionOrderAndReset() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MappingProfileStore(directory: dir)
    #expect(store.resolve(family: .xbox, gameID: nil).source == .smart(.byPosition))

    store.setStyle(.byLabel, for: .switchPro)
    #expect(MappingProfileStore(directory: dir).style(for: .switchPro) == .byLabel)  // persisted
    #expect(store.resolve(family: .switchPro, gameID: nil).source == .smart(.byLabel))

    var custom = SmartMapping.profile(for: .xbox, style: .byPosition).profile
    custom.bindings[.leftShoulder] = .z
    store.save(custom, family: .xbox)
    let r1 = store.resolve(family: .xbox, gameID: "GALE01")
    #expect(r1.source == .custom && r1.profile.isCustom)
    #expect(r1.profile.target(for: .leftShoulder) == .z)

    var perGame = custom
    perGame.bindings[.buttonSouth] = .b
    store.save(perGame, family: .xbox, gameID: "GALE01")
    #expect(store.resolve(family: .xbox, gameID: "GALE01").source == .gameOverride)
    #expect(store.resolve(family: .xbox, gameID: "OTHER").source == .custom)

    store.reset(family: .xbox)
    store.reset(family: .xbox, gameID: "GALE01")
    #expect(store.resolve(family: .xbox, gameID: "GALE01").source == .smart(.byPosition))
  }
}
