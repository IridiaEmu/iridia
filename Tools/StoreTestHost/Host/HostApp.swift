// SPDX-License-Identifier: GPL-2.0-or-later
// Empty host app: StoreKitTest needs tests to run inside an app with a bundle identifier.
import SwiftUI

@main
struct StoreTestHostApp: App {
  var body: some Scene { WindowGroup { Text("IridiaStore test host") } }
}
