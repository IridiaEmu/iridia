// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// gc-emu: the "Import Games" picker. Apple's picker opens on its Recents tab, which is a query of
/// iOS's Spotlight file index; when that index is stale or rebuilding (common on iOS 26/27), Recents
/// spins on "Loading" forever and nothing an app does changes that. Setting `directoryURL` makes the
/// picker open on Browse instead, which reads folders directly and always works. Every file type is
/// allowed; the type is checked after picking so game files never show greyed out.
@objc final class GameFilePicker: NSObject, UIDocumentPickerDelegate {
  private static var active: GameFilePicker?
  private let onPick: ([URL]) -> Void

  private init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

  static func present(onPick: @escaping ([URL]) -> Void) {
    guard active == nil, let presenter = topViewController() else { return }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
    picker.allowsMultipleSelection = true
    picker.shouldShowFileExtensions = true
    picker.directoryURL = URL(fileURLWithPath: UserFolderUtil.getSoftwareFolder(), isDirectory: true)
    let delegate = GameFilePicker(onPick: onPick)
    picker.delegate = delegate
    active = delegate
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    GameFilePicker.active = nil
    if !urls.isEmpty { onPick(urls) }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    GameFilePicker.active = nil
  }

  private static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
    var top = scene?.keyWindow?.rootViewController
    while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
    return top
  }
}
#endif
