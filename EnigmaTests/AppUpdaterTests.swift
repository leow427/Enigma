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

  func testDebugBuildsRefuseOnlyBackgroundChecks() {
    XCTAssertFalse(SparkleUpdaterBackend.permitsCheck(isBackground: true, isDebugBuild: true))
    XCTAssertTrue(SparkleUpdaterBackend.permitsCheck(isBackground: false, isDebugBuild: true))
    XCTAssertTrue(SparkleUpdaterBackend.permitsCheck(isBackground: true, isDebugBuild: false))
    XCTAssertTrue(SparkleUpdaterBackend.permitsCheck(isBackground: false, isDebugBuild: false))
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

  // MARK: Menu bar

  private func makeMenu(_ fake: FakeUpdaterBackend) -> (AppUpdater, MenuBarController, NSMenu) {
    let updater = AppUpdater(backend: fake)
    let controller = MenuBarController(panelController: SpotlightPanelController(contentView: NSView()), updater: updater)
    let menu = controller.makeMenu()
    controller.menuNeedsUpdate(menu)
    return (updater, controller, menu)
  }

  private func item(_ id: String, in menu: NSMenu) throws -> NSMenuItem {
    try XCTUnwrap(menu.items.first { $0.identifier == NSUserInterfaceItemIdentifier(id) })
  }

  private func perform(_ item: NSMenuItem, in menu: NSMenu) {
    menu.performActionForItem(at: menu.index(of: item))
  }

  func testMenuHidesTheUpdateItemUntilOneIsPending() throws {
    let fake = FakeUpdaterBackend()
    let (updater, controller, menu) = makeMenu(fake)
    XCTAssertTrue(try item("pendingUpdate", in: menu).isHidden)
    let check = try item("checkForUpdates", in: menu)
    XCTAssertEqual(check.title, "Check for Updates…")
    XCTAssertFalse(check.isEnabled)
    updater.backendCanCheckChanged(true)
    controller.menuNeedsUpdate(menu)
    XCTAssertTrue(check.isEnabled)
    perform(check, in: menu)
    XCTAssertEqual(fake.checkCount, 1)
  }

  func testMenuOffersRestartForAReadyUpdate() throws {
    let fake = FakeUpdaterBackend()
    let (updater, controller, menu) = makeMenu(fake)
    var installs = 0
    updater.backendUpdateReady(version: "0.10.1") { installs += 1 }
    controller.menuNeedsUpdate(menu)
    let pending = try item("pendingUpdate", in: menu)
    XCTAssertFalse(pending.isHidden)
    XCTAssertEqual(pending.title, "Restart to Update to 0.10.1")
    perform(pending, in: menu)
    XCTAssertEqual(installs, 1)
    XCTAssertEqual(fake.checkCount, 0)
  }

  func testMenuOffersAnAvailableUpdate() throws {
    let fake = FakeUpdaterBackend()
    let (updater, controller, menu) = makeMenu(fake)
    updater.backendUpdateAvailable(version: "0.10.1")
    controller.menuNeedsUpdate(menu)
    let pending = try item("pendingUpdate", in: menu)
    XCTAssertFalse(pending.isHidden)
    XCTAssertEqual(pending.title, "Update to 0.10.1 Available…")
    perform(pending, in: menu)
    XCTAssertEqual(fake.checkCount, 1)
  }

  func testMenuDropsAnAvailableUpdateWhenTheSessionEnds() throws {
    let (updater, controller, menu) = makeMenu(FakeUpdaterBackend())
    updater.backendUpdateAvailable(version: "0.10.1")
    controller.menuNeedsUpdate(menu)
    XCTAssertFalse(try item("pendingUpdate", in: menu).isHidden)
    updater.backendSessionEnded()
    controller.menuNeedsUpdate(menu)
    XCTAssertTrue(try item("pendingUpdate", in: menu).isHidden)
  }
}
