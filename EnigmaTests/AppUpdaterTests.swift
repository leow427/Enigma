import AppKit
import XCTest
@testable import Enigma

/// Stands in for Sparkle, so these tests never check, download or install anything.
@MainActor final class FakeUpdaterBackend: AppUpdaterBackend {
  var automaticallyChecksForUpdates = true
  var automaticallyDownloadsUpdates = true
  var lastUpdateCheckDate: Date?
  private(set) var startCount = 0
  private(set) var checkCount = 0
  func start(reportingTo updater: AppUpdater) { startCount += 1 }
  func checkForUpdates() { checkCount += 1 }
}

@MainActor
final class AppUpdaterTests: XCTestCase {
  func testStartsOnceAndHasNothingPending() {
    let fake = FakeUpdaterBackend()
    let updater = AppUpdater(backend: fake)
    updater.start()
    updater.start()
    XCTAssertEqual(fake.startCount, 1)
    XCTAssertNil(updater.pendingUpdate)
    XCTAssertFalse(updater.canCheckForUpdates)
    updater.backendCanCheckChanged(true)
    XCTAssertTrue(updater.canCheckForUpdates)
  }

  func testReadyUpdateInstallsExactlyOnce() {
    let fake = FakeUpdaterBackend()
    let updater = AppUpdater(backend: fake)
    var installs = 0
    updater.backendUpdateReady(version: "0.10.1") { installs += 1 }
    XCTAssertEqual(updater.pendingUpdate, PendingUpdate(version: "0.10.1", stage: .readyToInstall))
    XCTAssertEqual(updater.pendingUpdate?.menuTitle, "Restart to Update to 0.10.1")
    updater.performPendingUpdate()
    updater.performPendingUpdate()
    XCTAssertEqual(installs, 1)
    XCTAssertEqual(fake.checkCount, 0)
  }

  func testAvailableUpdateHandsBackToSparkle() {
    let fake = FakeUpdaterBackend()
    let updater = AppUpdater(backend: fake)
    updater.backendUpdateAvailable(version: "0.10.1")
    XCTAssertEqual(updater.pendingUpdate?.menuTitle, "Update to 0.10.1 Available…")
    updater.performPendingUpdate()
    XCTAssertEqual(fake.checkCount, 1)
  }

  func testSessionEndClearsAnAvailableUpdate() {
    let fake = FakeUpdaterBackend()
    let updater = AppUpdater(backend: fake)
    updater.backendUpdateAvailable(version: "0.10.1")
    updater.backendSessionEnded()
    XCTAssertNil(updater.pendingUpdate)
    updater.performPendingUpdate()
    XCTAssertEqual(fake.checkCount, 0)
  }

  func testSessionEndKeepsAReadyUpdate() {
    let updater = AppUpdater(backend: FakeUpdaterBackend())
    updater.backendUpdateReady(version: "0.10.1") {}
    updater.backendSessionEnded()
    XCTAssertEqual(updater.pendingUpdate, PendingUpdate(version: "0.10.1", stage: .readyToInstall))
  }

  func testTogglesWriteThroughToTheBackend() {
    let fake = FakeUpdaterBackend()
    let updater = AppUpdater(backend: fake)
    updater.automaticallyChecksForUpdates = false
    updater.automaticallyDownloadsUpdates = false
    XCTAssertFalse(fake.automaticallyChecksForUpdates)
    XCTAssertFalse(fake.automaticallyDownloadsUpdates)
    XCTAssertFalse(updater.automaticallyChecksForUpdates)
    XCTAssertFalse(updater.automaticallyDownloadsUpdates)
  }

  func testLastCheckDateFollowsTheBackend() {
    let fake = FakeUpdaterBackend()
    let updater = AppUpdater(backend: fake)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    fake.lastUpdateCheckDate = date
    updater.backendCheckFinished()
    XCTAssertEqual(updater.lastUpdateCheckDate, date)
  }

  func testVersionText() {
    XCTAssertEqual(AppUpdater.versionText(info: ["CFBundleShortVersionString": "0.10.0", "CFBundleVersion": "2"]), "0.10.0 (2)")
    XCTAssertEqual(AppUpdater.versionText(info: [:]), "Unknown version")
  }

  func testLastCheckedText() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let locale = Locale(identifier: "en_US")
    XCTAssertEqual(AppUpdater.lastCheckedText(nil, now: now, locale: locale), "Not checked yet")
    XCTAssertEqual(AppUpdater.lastCheckedText(now - 300, now: now, locale: locale), "Last checked 5 minutes ago")
  }
}
