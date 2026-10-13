// SPDX-License-Identifier: GPL-2.0-or-later
import ObjectiveC
import XCTest

/// gc-emu: Iridia has no telemetry. iCube's Sentry crash and performance reporting (which sent data to
/// iCube's Sentry account) was removed in Phase 7, and the privacy manifest and App Store privacy label
/// say no data is collected. This keeps it that way: the tests run hosted in the app, so any Sentry
/// class showing up here means the SDK got linked back in.
final class NoTelemetryTests: XCTestCase {
  func testSentryIsNotLinked() {
    for name in ["SentrySDK", "SentryEvent", "SentryClient", "PrivateSentrySDKOnly"] {
      XCTAssertNil(NSClassFromString(name), "\(name) is linked into the app: telemetry must stay out")
    }
  }
}
