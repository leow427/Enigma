import XCTest
@testable import Enigma

final class InstallLocationTests: XCTestCase {
  private var temporaryDirectory: URL?

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    temporaryDirectory = nil
  }

  /// Builds a file URL without consulting the file system, so results do not depend on this Mac.
  private func url(_ path: String) -> URL {
    URL(filePath: path, directoryHint: .notDirectory)
  }

  private let translocatedPath = "/private/var/folders/ab/xyz/T/AppTranslocation/1234/d/Enigma.app"

  private func context(
    bundle: String,
    translocated: Bool = false,
    original: String? = nil,
    writable: Bool = true,
    dontAsk: Bool = false,
    debug: Bool = false,
    home: String = "/Users/friend"
  ) -> InstallLocationContext {
    InstallLocationContext(
      bundleURL: url(bundle),
      isTranslocated: translocated,
      originalURL: original.map(url),
      homeDirectory: URL(filePath: home, directoryHint: .isDirectory),
      systemApplicationsIsWritable: writable,
      dontAskAgain: dontAsk,
      isDebugBuild: debug
    )
  }

  private var systemDestination: InstallLocationDecision {
    .move(destination: url("/Applications/Enigma.app"), inHomeFolder: false)
  }

  // MARK: decide

  func testDebugBuildStays() {
    XCTAssertEqual(
      InstallLocation.decide(context(bundle: "/Users/friend/Downloads/Enigma.app", debug: true)), .stay)
  }

  func testDontAskAgainStays() {
    XCTAssertEqual(
      InstallLocation.decide(context(bundle: translocatedPath, translocated: true, dontAsk: true)), .stay)
  }

  func testInSystemApplicationsStays() {
    XCTAssertEqual(InstallLocation.decide(context(bundle: "/Applications/Enigma.app")), .stay)
  }

  func testInApplicationsSubfolderStays() {
    XCTAssertEqual(InstallLocation.decide(context(bundle: "/Applications/Utilities/Enigma.app")), .stay)
  }

  func testInHomeApplicationsStays() {
    XCTAssertEqual(InstallLocation.decide(context(bundle: "/Users/friend/Applications/Enigma.app")), .stay)
  }

  func testDownloadsMovesToSystemApplications() {
    XCTAssertEqual(
      InstallLocation.decide(context(bundle: "/Users/friend/Downloads/Enigma.app")), systemDestination)
  }

  func testDownloadsWithoutWriteAccessMovesToHomeApplications() {
    XCTAssertEqual(
      InstallLocation.decide(context(bundle: "/Users/friend/Downloads/Enigma.app", writable: false)),
      .move(destination: url("/Users/friend/Applications/Enigma.app"), inHomeFolder: true))
  }

  func testRenamedBundleMovesAsEnigmaApp() {
    XCTAssertEqual(
      InstallLocation.decide(context(bundle: "/Users/friend/Downloads/Enigma 2.app")), systemDestination)
  }

  func testTranslocatedWithOriginalInApplicationsReopensInPlace() {
    XCTAssertEqual(
      InstallLocation.decide(context(
        bundle: translocatedPath, translocated: true, original: "/Applications/Enigma.app")),
      .reopenInPlace(original: url("/Applications/Enigma.app")))
  }

  func testTranslocatedWithOriginalInDownloadsMoves() {
    XCTAssertEqual(
      InstallLocation.decide(context(
        bundle: translocatedPath, translocated: true, original: "/Users/friend/Downloads/Enigma.app")),
      systemDestination)
  }

  func testTranslocatedWithUnknownOriginalMoves() {
    XCTAssertEqual(
      InstallLocation.decide(context(bundle: translocatedPath, translocated: true)), systemDestination)
  }

  // MARK: isInApplicationsFolder

  func testTranslocatedBundleIsNeverInApplications() {
    let home = URL(filePath: "/Users/friend", directoryHint: .isDirectory)
    XCTAssertFalse(InstallLocation.isInApplicationsFolder(
      URL(fileURLWithPath: translocatedPath), homeDirectory: home))
    XCTAssertFalse(InstallLocation.isInApplicationsFolder(
      URL(fileURLWithPath: "/var/folders/ab/xyz/T/AppTranslocation/1234/d/Enigma.app"), homeDirectory: home))
    XCTAssertEqual(
      InstallLocation.decide(context(bundle: translocatedPath)), systemDestination)
  }

  func testApplicationsPrefixMustBeAWholeComponent() {
    let home = URL(filePath: "/Users/friend", directoryHint: .isDirectory)
    XCTAssertFalse(InstallLocation.isInApplicationsFolder(
      URL(fileURLWithPath: "/ApplicationsFoo/Enigma.app"), homeDirectory: home))
    XCTAssertFalse(InstallLocation.isInApplicationsFolder(
      URL(fileURLWithPath: "/Applications"), homeDirectory: home))
    XCTAssertTrue(InstallLocation.isInApplicationsFolder(
      URL(fileURLWithPath: "/applications/Enigma.app"), homeDirectory: home))
  }

  func testSymlinkedHomeFolderResolves() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("InstallLocationTests-\(UUID().uuidString)", isDirectory: true)
    temporaryDirectory = root
    let real = root.appendingPathComponent("real", isDirectory: true)
    let link = root.appendingPathComponent("link")
    try fileManager.createDirectory(
      at: real.appendingPathComponent("Applications/Enigma.app", isDirectory: true),
      withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: link, withDestinationURL: real)

    XCTAssertTrue(InstallLocation.isInApplicationsFolder(
      link.appendingPathComponent("Applications/Enigma.app"), homeDirectory: real))
    XCTAssertTrue(InstallLocation.isInApplicationsFolder(
      real.appendingPathComponent("Applications/Enigma.app"), homeDirectory: link))
  }

  // MARK: age

  func testExistingCopyAge() {
    XCTAssertEqual(InstallLocation.age(ofExisting: "0.10.0", comparedTo: "0.10.1"), .older)
    XCTAssertEqual(InstallLocation.age(ofExisting: "0.10.1", comparedTo: "0.10.1"), .same)
    XCTAssertEqual(InstallLocation.age(ofExisting: "0.10.2", comparedTo: "0.10.1"), .newer)
    XCTAssertEqual(InstallLocation.age(ofExisting: "0.10", comparedTo: "0.10.0"), .same)
    XCTAssertEqual(InstallLocation.age(ofExisting: "0.9.12", comparedTo: "0.10.0"), .older)
    XCTAssertEqual(InstallLocation.age(ofExisting: nil, comparedTo: "0.10.1"), .unknown)
    XCTAssertEqual(InstallLocation.age(ofExisting: "beta", comparedTo: "0.10.1"), .unknown)
  }

  // MARK: Alert text

  func testAlertTexts() {
    XCTAssertEqual(InstallLocationAlertText.moveOffer(inHomeFolder: false), .init(
      title: "Move Enigma to Applications?",
      message: "Enigma can only update itself from the Applications folder. It will move there and reopen.",
      confirmButton: "Move to Applications", cancelButton: "Not Now"))
    XCTAssertEqual(InstallLocationAlertText.moveOffer(inHomeFolder: true), .init(
      title: "Move Enigma to Applications?",
      message: "Enigma can only update itself from an Applications folder. It will move to the Applications folder in your home folder and reopen.",
      confirmButton: "Move to Applications", cancelButton: "Not Now"))
    XCTAssertEqual(InstallLocationAlertText.reopenOffer, .init(
      title: "Reopen Enigma from Applications?",
      message: "macOS is running Enigma from a temporary copy, so it can't update itself. Enigma will reopen from Applications.",
      confirmButton: "Reopen", cancelButton: "Not Now"))

    let olderOrSame = InstallLocationAlertText(
      title: "Replace the Enigma in Applications?",
      message: "Applications already has Enigma 0.10.0. The old copy goes to the Trash.",
      confirmButton: "Replace", cancelButton: "Cancel")
    XCTAssertEqual(
      InstallLocationAlertText.replace(existingVersion: "0.10.0", runningVersion: "0.10.1", age: .older),
      olderOrSame)
    XCTAssertEqual(
      InstallLocationAlertText.replace(existingVersion: "0.10.0", runningVersion: "0.10.0", age: .same),
      olderOrSame)
    XCTAssertEqual(
      InstallLocationAlertText.replace(existingVersion: "0.10.2", runningVersion: "0.10.1", age: .newer),
      .init(
        title: "Replace the Enigma in Applications?",
        message: "Applications already has a newer Enigma (0.10.2). Replacing it installs 0.10.1. The old copy goes to the Trash.",
        confirmButton: "Replace", cancelButton: "Cancel"))
    let unknown = InstallLocationAlertText(
      title: "Replace the Enigma in Applications?",
      message: "Applications already has a copy of Enigma. The old copy goes to the Trash.",
      confirmButton: "Replace", cancelButton: "Cancel")
    XCTAssertEqual(
      InstallLocationAlertText.replace(existingVersion: "beta", runningVersion: "0.10.1", age: .unknown),
      unknown)
    XCTAssertEqual(
      InstallLocationAlertText.replace(existingVersion: nil, runningVersion: "0.10.1", age: .older),
      unknown)

    XCTAssertEqual(InstallLocationAlertText.failure(reason: "The disk is full."), .init(
      title: "Enigma couldn't move to Applications",
      message: "The disk is full. Drag Enigma into Applications in Finder instead.",
      confirmButton: "OK", cancelButton: ""))
  }
}
