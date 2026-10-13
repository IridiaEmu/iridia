// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: a tiny in-app sampling profiler for when Instruments can't reach the device. Test hook
// only: `-gcemuProfile <seconds>` (with a -gcemuBench run) samples one thread's program counter about
// 1,000 times a second and writes "<image> <offset> <count>" lines to Benchmarks/profile-<label>.txt.
// scripts/symbolize_profile.py turns the offsets into function names with atos on the Mac.

import Darwin
import Foundation

enum GCEmuProfiler {
  /// Starts sampling the thread named `threadName` (default Dolphin's emulated CPU thread).
  static func startIfRequested(label: String, threadName: String = "CPU thread") {
    let seconds = UserDefaults.standard.double(forKey: "gcemuProfile")
    guard seconds > 0 else { return }
    let thread = Thread {
      guard let target = findThread(named: threadName) else {
        NSLog("[GCEmuProfile] no thread named %@", threadName)
        return
      }
      var counts: [UInt: Int] = [:]
      var callers: [UInt: Int] = [:]
      let end = Date().addingTimeInterval(seconds)
      var samples = 0
      while Date() < end {
        if thread_suspend(target) == KERN_SUCCESS {
          var state = arm_thread_state64_t()
          var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
          let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
              thread_get_state(target, ARM_THREAD_STATE64, $0, &count)
            }
          }
          thread_resume(target)
          if kr == KERN_SUCCESS {
            counts[UInt(state.__pc), default: 0] += 1
            callers[UInt(state.__lr), default: 0] += 1
            samples += 1
          }
        }
        usleep(1000)
      }
      write(counts: counts, callers: callers, samples: samples, label: label)
    }
    thread.name = "gcemu.profiler"
    thread.qualityOfService = .utility
    thread.start()
  }

  private static func findThread(named name: String) -> thread_act_t? {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return nil }
    var found: thread_act_t?
    for i in 0..<Int(count) {
      var info = thread_extended_info_data_t()
      var n = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
      let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { thread_info(list[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &n) }
      }
      let threadName = withUnsafeBytes(of: info.pth_name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
      if kr == KERN_SUCCESS, found == nil, threadName == name { found = list[i] } else { mach_port_deallocate(mach_task_self_, list[i]) }
    }
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    return found
  }

  /// "<kind> <image> 0x<offset> <count>", kind = pc (where it was) or lr (who called a leaf).
  private static func write(counts: [UInt: Int], callers: [UInt: Int], samples: Int, label: String) {
    var lines = ["# samples \(samples)"]
    for (kind, table) in [("pc", counts), ("lr", callers)] {
      for (addr, n) in table.sorted(by: { $0.value > $1.value }) {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: addr), &info) != 0, let base = info.dli_fbase, let file = info.dli_fname else {
          lines.append("\(kind) ? 0x\(String(addr, radix: 16)) \(n)")
          continue
        }
        let image = (String(cString: file) as NSString).lastPathComponent
        lines.append("\(kind) \(image) 0x\(String(addr - UInt(bitPattern: base), radix: 16)) \(n)")
      }
    }
    let dir = URL(fileURLWithPath: UserFolderUtil.getUserFolder(), isDirectory: true).appendingPathComponent("Benchmarks", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let safe = label.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("profile-\(safe).txt"), atomically: true, encoding: .utf8)
    NSLog("[GCEmuProfile] %d samples written", samples)
  }
}
