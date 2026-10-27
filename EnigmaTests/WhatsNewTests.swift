import Foundation
import XCTest
@testable import Enigma

@MainActor
final class WhatsNewTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!

  private let allNotes = ["0.12.0", "0.11.0", "0.10.1", "0.10.0", "0.9.0"]
    .map { ReleaseNote(version: $0, markdown: "# Enigma \($0)") }

  override func setUp() {
    super.setUp()
    suiteName = "WhatsNewTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func launch(_ version: String, build: String, notes: [ReleaseNote]? = nil) -> WhatsNew {
    WhatsNew(version: version, build: build, notes: notes ?? allNotes, defaults: defaults)
  }

  private func seen(build: String, version: String) {
    defaults.set(build, forKey: WhatsNew.lastSeenBuildKey)
    defaults.set(version, forKey: WhatsNew.lastSeenVersionKey)
  }

  func testAFreshInstallShowsNothingAndRemembersItsBuild() {
    let whatsNew = launch("0.11.0", build: "4")
    XCTAssertFalse(whatsNew.showsButton)
    XCTAssertEqual(whatsNew.notes, [])
    XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenBuildKey), "4")
    XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenVersionKey), "0.11.0")

    defaults.set(true, forKey: WelcomeSetup.completedKey)
    XCTAssertFalse(launch("0.11.0", build: "4").showsButton, "Finishing setup later doesn't turn it on")
    let update = launch("0.12.0", build: "5")
    XCTAssertTrue(update.showsButton, "The next update does")
    XCTAssertEqual(update.notes.map(\.version), ["0.12.0"])
  }

  func testAnExistingUserWithNoSavedBuildSeesOnlyTheCurrentVersion() {
    defaults.set(true, forKey: WelcomeSetup.completedKey)
    let whatsNew = launch("0.11.0", build: "4")
    XCTAssertTrue(whatsNew.showsButton)
    XCTAssertEqual(whatsNew.notes.map(\.version), ["0.11.0"])
    XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenBuildKey), "0", "Only a place before the notes is kept")
    XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenVersionKey), "0.10.1")
    let again = launch("0.11.0", build: "4")
    XCTAssertTrue(again.showsButton, "It stays until opened")
    XCTAssertEqual(again.notes.map(\.version), ["0.11.0"])
  }

  func testAnExistingUsersUnopenedNotesCarryIntoTheNextUpdate() {
    defaults.set(true, forKey: WelcomeSetup.completedKey)
    XCTAssertTrue(launch("0.11.0", build: "4").showsButton)
    XCTAssertEqual(launch("0.12.0", build: "5").notes.map(\.version), ["0.12.0", "0.11.0"])
  }

  func testAnExistingUsersFirstNotesWithNothingOlderStillCarryOver() {
    defaults.set(true, forKey: WelcomeSetup.completedKey)
    let notes = ["0.9.0", "0.10.0"].map { ReleaseNote(version: $0, markdown: "") }
    XCTAssertTrue(launch("0.9.0", build: "1", notes: notes).showsButton)
    XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenVersionKey), "0")
    XCTAssertEqual(launch("0.10.0", build: "2", notes: notes).notes.map(\.version), ["0.10.0", "0.9.0"])
  }

  func testAnUpdateShowsEveryVersionSinceTheLastOneSeenNewestFirst() {
    seen(build: "2", version: "0.10.0")
    let whatsNew = launch("0.12.0", build: "5")
    XCTAssertTrue(whatsNew.showsButton)
    XCTAssertEqual(whatsNew.notes.map(\.version), ["0.12.0", "0.11.0", "0.10.1"],
                   "Skipped versions are included; the one seen before and older aren't")
  }

  func testNotesNewerThanTheRunningVersionAreLeftOut() {
    seen(build: "3", version: "0.10.1")
    XCTAssertEqual(launch("0.11.0", build: "4").notes.map(\.version), ["0.11.0"])
  }

  func testVersionsCompareByNumberNotText() {
    let notes = ["0.9.0", "0.9.10", "0.10.0"].map { ReleaseNote(version: $0, markdown: "") }
    seen(build: "9", version: "0.9.2")
    XCTAssertEqual(launch("0.10.0", build: "10", notes: notes).notes.map(\.version), ["0.10.0", "0.9.10"])
    XCTAssertTrue(ReleaseNote.isNewer("10", than: "9"), "Build numbers compare as numbers too")
  }

  func testOpeningRetiresTheButtonForThatVersion() {
    seen(build: "3", version: "0.10.1")
    let whatsNew = launch("0.11.0", build: "4")
    whatsNew.open()
    XCTAssertFalse(whatsNew.showsButton)
    XCTAssertEqual(whatsNew.notes.map(\.version), ["0.11.0"], "The sheet still has the notes")
    XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenBuildKey), "4")
    XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenVersionKey), "0.11.0")
    XCTAssertFalse(launch("0.11.0", build: "4").showsButton, "Gone for good after a relaunch")
  }

  func testAnUnopenedButtonCarriesItsVersionsIntoTheNextUpdate() {
    seen(build: "2", version: "0.10.0")
    XCTAssertTrue(launch("0.11.0", build: "4").showsButton)
    XCTAssertEqual(launch("0.12.0", build: "5").notes.map(\.version), ["0.12.0", "0.11.0", "0.10.1"])
  }

  func testTheSameOrAnOlderBuildShowsNothingAndKeepsTheNewerOneSeen() {
    seen(build: "4", version: "0.11.0")
    XCTAssertFalse(launch("0.11.0", build: "4").showsButton)
    XCTAssertFalse(launch("0.10.1", build: "3").showsButton, "Going back a version shows nothing")
    XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenBuildKey), "4")
    XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenVersionKey), "0.11.0")
  }

  func testANewerBuildWithNoNewNotesShowsNothingAndCountsAsSeen() {
    seen(build: "4", version: "0.11.0")
    XCTAssertFalse(launch("0.11.0", build: "5").showsButton, "A rebuild of the same version")
    XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenBuildKey), "5")

    defaults.set(true, forKey: WelcomeSetup.completedKey)
    defaults.removeObject(forKey: WhatsNew.lastSeenBuildKey)
    XCTAssertFalse(launch("0.13.0", build: "6").showsButton, "No notes for the running version")
    XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenBuildKey), "6")
    XCTAssertFalse(launch("0.13.0", build: "6", notes: []).showsButton)
  }

  func testTheButtonIsLabelledWithTheNewestVersionItShows() {
    defaults.set(true, forKey: WelcomeSetup.completedKey)
    XCTAssertEqual(launch("0.11.0", build: "4").accessibilityLabel, "What's new in Enigma 0.11.0")
    seen(build: "3", version: "0.10.1")
    let withoutItsOwnNote = launch("0.11.1", build: "5")
    XCTAssertEqual(withoutItsOwnNote.notes.map(\.version), ["0.11.0"])
    XCTAssertEqual(withoutItsOwnNote.accessibilityLabel, "What's new in Enigma 0.11.0")
  }

  func testWithoutDefaultsNothingIsReadOrRemembered() {
    let standard = UserDefaults.standard
    let saved = [WhatsNew.lastSeenBuildKey, WhatsNew.lastSeenVersionKey].map { standard.object(forKey: $0) }
    let inert = WhatsNew(version: "999.0.0", build: "999999", notes: allNotes, defaults: nil)
    XCTAssertFalse(inert.showsButton, "With no defaults it's a fresh install every time")
    inert.open()
    XCTAssertEqual([WhatsNew.lastSeenBuildKey, WhatsNew.lastSeenVersionKey].map { standard.object(forKey: $0) as? String },
                   saved.map { $0 as? String }, "It never falls back to the standard defaults")
  }

  func testNotesLoadFromAFolderAndSkipOtherFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for version in ["0.9.0", "0.10.0", "0.10.1"] {
      try "# Enigma \(version)\n".write(to: folder.appendingPathComponent("\(version).md"), atomically: true,
                                        encoding: .utf8)
    }
    try "x".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
    try "draft".write(to: folder.appendingPathComponent("0.12.0-draft.md"), atomically: true, encoding: .utf8)
    try "draft".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    let notes = ReleaseNote.load(from: folder)
    XCTAssertEqual(Set(notes.map(\.version)), ["0.10.1", "0.10.0", "0.9.0"])
    XCTAssertEqual(notes.first { $0.version == "0.10.1" }?.markdown, "# Enigma 0.10.1\n")
    XCTAssertEqual(ReleaseNote.load(from: folder.appendingPathComponent("missing")), [])
    XCTAssertEqual(ReleaseNote.load(from: nil), [])
  }

  func testTheAppBundlesTheNotesForItsOwnVersion() throws {
    let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    let notes = ReleaseNote.load(from: ReleaseNote.bundledDirectory)
    let note = try XCTUnwrap(notes.first { $0.version == version },
                             "docs/release-notes/\(version).md is copied into the app")
    XCTAssertTrue(note.markdown.hasPrefix("# Enigma \(version)"))
    XCTAssertGreaterThan(notes.count, 1, "Earlier versions come too, for anyone who skipped one")
  }

  func testTheTopBarShowsWhileTheSidebarIsUpOnlyForWhatsNew() {
    XCTAssertTrue(EnigmaTopBar.isShown(isSidebarVisible: false, hasWhatsNew: false))
    XCTAssertTrue(EnigmaTopBar.isShown(isSidebarVisible: false, hasWhatsNew: true))
    XCTAssertTrue(EnigmaTopBar.isShown(isSidebarVisible: true, hasWhatsNew: true))
    XCTAssertFalse(EnigmaTopBar.isShown(isSidebarVisible: true, hasWhatsNew: false))
  }
}
