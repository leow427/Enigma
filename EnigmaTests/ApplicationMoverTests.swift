import Darwin
import XCTest
@testable import Enigma

/// Records what the mover asks for. Its Trash is a folder inside the test's temporary directory.
private final class MoverRecorder {
  let trashFolder: URL
  var trashed: [URL] = []
  var quit: [URL] = []
  var events: [String] = []
  var trashError: Error?

  init(trashFolder: URL) {
    self.trashFolder = trashFolder
  }

  func mover() -> ApplicationMover {
    ApplicationMover(
      trash: { [self] url in
        events.append("trash")
        if let trashError { throw trashError }
        trashed.append(url)
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
          at: url, to: trashFolder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
      },
      quitRunningCopy: { [self] url in
        events.append("quit")
        quit.append(url)
      })
  }
}

private struct FakeTrashError: Error {}

final class ApplicationMoverTests: XCTestCase {
  private var root: URL!
  private var recorder: MoverRecorder!
  private let quarantine = "com.apple.quarantine"

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ApplicationMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    recorder = MoverRecorder(trashFolder: root.appendingPathComponent("Trash", isDirectory: true))
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
    root = nil
    recorder = nil
  }

  // MARK: Helpers

  private func makeBundle(at url: URL, version: String) throws {
    let fileManager = FileManager.default
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    try fileManager.createDirectory(
      at: contents.appendingPathComponent("MacOS", isDirectory: true), withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleShortVersionString": version, "CFBundleIdentifier": "test.enigma"],
      format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
    try Data("enigma".utf8).write(to: contents.appendingPathComponent("MacOS/Enigma"))

    let framework = contents.appendingPathComponent("Frameworks/Fake.framework", isDirectory: true)
    let versionA = framework.appendingPathComponent("Versions/A", isDirectory: true)
    try fileManager.createDirectory(at: versionA, withIntermediateDirectories: true)
    try Data("fake".utf8).write(to: versionA.appendingPathComponent("Fake"))
    try fileManager.createSymbolicLink(
      atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
    try fileManager.createSymbolicLink(
      atPath: framework.appendingPathComponent("Fake").path, withDestinationPath: "Versions/Current/Fake")
  }

  private func setQuarantine(_ url: URL) {
    let value = Array("0081;00000000;Safari;".utf8)
    let result = setxattr(url.path, quarantine, value, value.count, 0, XATTR_NOFOLLOW)
    XCTAssertEqual(result, 0, "setxattr failed for \(url.path)")
  }

  private func hasQuarantine(_ url: URL) -> Bool {
    let size = getxattr(url.path, quarantine, nil, 0, 0, XATTR_NOFOLLOW)
    if size == -1 {
      XCTAssertEqual(errno, ENOATTR)
      return false
    }
    return true
  }

  private func contents(of folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
  }

  private func stagingItems(in folder: URL) throws -> [String] {
    try contents(of: folder).filter { $0.hasPrefix(".Enigma-") }
  }

  private var applications: URL { root.appendingPathComponent("Applications", isDirectory: true) }
  private var destination: URL { applications.appendingPathComponent("Enigma.app", isDirectory: true) }
  private var downloadedBundle: URL {
    root.appendingPathComponent("Downloads/Enigma.app", isDirectory: true)
  }

  // MARK: install

  func testInstallCreatesMissingParentFolder() throws {
    try makeBundle(at: downloadedBundle, version: "0.10.1")
    let destination = root.appendingPathComponent("home/Applications/Enigma.app", isDirectory: true)
    let mover = recorder.mover()

    try mover.install(from: downloadedBundle, to: destination, replacingExisting: false)

    XCTAssertEqual(mover.existingVersion(at: destination), "0.10.1")
  }

  func testInstallWithoutExistingCopyLeavesOnlyEnigmaApp() throws {
    try makeBundle(at: downloadedBundle, version: "0.10.1")
    try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

    try recorder.mover().install(from: downloadedBundle, to: destination, replacingExisting: false)

    XCTAssertEqual(try contents(of: applications), ["Enigma.app"])
    XCTAssertTrue(recorder.quit.isEmpty)
    XCTAssertTrue(recorder.trashed.isEmpty)
  }

  func testRenamedSourceInstallsAsEnigmaApp() throws {
    let source = root.appendingPathComponent("Downloads/Enigma 2.app", isDirectory: true)
    try makeBundle(at: source, version: "0.10.1")
    let mover = recorder.mover()

    try mover.install(from: source, to: destination, replacingExisting: false)

    XCTAssertEqual(try contents(of: applications), ["Enigma.app"])
    XCTAssertEqual(mover.existingVersion(at: destination), "0.10.1")
  }

  func testInstallReplacesExistingCopyAfterQuittingAndTrashing() throws {
    try makeBundle(at: destination, version: "0.10.0")
    try makeBundle(at: downloadedBundle, version: "0.10.1")
    let mover = recorder.mover()

    try mover.install(from: downloadedBundle, to: destination, replacingExisting: true)

    XCTAssertEqual(recorder.quit, [destination])
    XCTAssertEqual(recorder.trashed, [destination])
    XCTAssertEqual(recorder.events, ["quit", "trash"])
    XCTAssertEqual(mover.existingVersion(at: destination), "0.10.1")
    XCTAssertEqual(try stagingItems(in: applications), [])
  }

  func testInstallRefusesExistingCopyWhenNotReplacing() throws {
    try makeBundle(at: destination, version: "0.10.0")
    try makeBundle(at: downloadedBundle, version: "0.10.1")
    let mover = recorder.mover()

    XCTAssertThrowsError(try mover.install(from: downloadedBundle, to: destination, replacingExisting: false)) {
      XCTAssertEqual($0 as? ApplicationMover.MoveError, .destinationExists)
    }
    XCTAssertEqual(mover.existingVersion(at: destination), "0.10.0")
    XCTAssertEqual(try stagingItems(in: applications), [])
    XCTAssertTrue(recorder.quit.isEmpty)
    XCTAssertTrue(recorder.trashed.isEmpty)
  }

  func testTrashFailureKeepsExistingCopy() throws {
    try makeBundle(at: destination, version: "0.10.0")
    try makeBundle(at: downloadedBundle, version: "0.10.1")
    recorder.trashError = FakeTrashError()
    let mover = recorder.mover()

    XCTAssertThrowsError(try mover.install(from: downloadedBundle, to: destination, replacingExisting: true)) {
      guard case .couldNotReplace = $0 as? ApplicationMover.MoveError else {
        return XCTFail("Expected couldNotReplace, got \($0)")
      }
    }
    XCTAssertEqual(mover.existingVersion(at: destination), "0.10.0")
    XCTAssertEqual(try stagingItems(in: applications), [])
  }

  func testCopyFailureLeavesNoStagingItem() throws {
    try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    let missing = root.appendingPathComponent("Downloads/Missing.app", isDirectory: true)

    XCTAssertThrowsError(try recorder.mover().install(from: missing, to: destination, replacingExisting: false)) {
      guard case .couldNotCopy = $0 as? ApplicationMover.MoveError else {
        return XCTFail("Expected couldNotCopy, got \($0)")
      }
    }
    XCTAssertEqual(try contents(of: applications), [])
  }

  // MARK: Quarantine

  func testInstallClearsQuarantine() throws {
    try makeBundle(at: downloadedBundle, version: "0.10.1")
    let binary = "Contents/MacOS/Enigma"
    let frameworkBinary = "Contents/Frameworks/Fake.framework/Versions/A/Fake"
    setQuarantine(downloadedBundle)
    setQuarantine(downloadedBundle.appendingPathComponent(binary))
    setQuarantine(downloadedBundle.appendingPathComponent(frameworkBinary))
    XCTAssertTrue(hasQuarantine(downloadedBundle))

    try recorder.mover().install(from: downloadedBundle, to: destination, replacingExisting: false)

    XCTAssertFalse(hasQuarantine(destination))
    XCTAssertFalse(hasQuarantine(destination.appendingPathComponent(binary)))
    XCTAssertFalse(hasQuarantine(destination.appendingPathComponent(frameworkBinary)))
    let current = destination.appendingPathComponent("Contents/Frameworks/Fake.framework/Versions/Current")
    let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
    XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
  }

  func testRemoveQuarantineToleratesItemsWithoutTheAttribute() throws {
    try makeBundle(at: downloadedBundle, version: "0.10.1")
    XCTAssertNoThrow(try recorder.mover().removeQuarantine(from: downloadedBundle))
  }

  // MARK: existingVersion

  func testExistingVersion() throws {
    try makeBundle(at: destination, version: "0.10.0")
    let mover = recorder.mover()
    XCTAssertEqual(mover.existingVersion(at: destination), "0.10.0")
    XCTAssertNil(mover.existingVersion(at: root.appendingPathComponent("Nowhere.app", isDirectory: true)))

    let noPlist = root.appendingPathComponent("NoPlist.app", isDirectory: true)
    try FileManager.default.createDirectory(
      at: noPlist.appendingPathComponent("Contents/MacOS", isDirectory: true), withIntermediateDirectories: true)
    XCTAssertNil(mover.existingVersion(at: noPlist))
  }

  // MARK: discardOriginal

  func testDiscardOriginalTrashesIt() throws {
    try makeBundle(at: downloadedBundle, version: "0.10.1")
    recorder.mover().discardOriginal(downloadedBundle, destination: destination)
    XCTAssertEqual(recorder.trashed, [downloadedBundle])
    XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedBundle.path))
  }

  func testDiscardOriginalSkipsNilAndDestination() throws {
    try makeBundle(at: destination, version: "0.10.1")
    let mover = recorder.mover()
    mover.discardOriginal(nil, destination: destination)
    mover.discardOriginal(destination, destination: destination)
    XCTAssertTrue(recorder.trashed.isEmpty)
    XCTAssertTrue(recorder.events.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
  }

  func testDiscardOriginalSwallowsTrashErrors() throws {
    try makeBundle(at: downloadedBundle, version: "0.10.1")
    recorder.trashError = FakeTrashError()
    recorder.mover().discardOriginal(downloadedBundle, destination: destination)
    XCTAssertTrue(FileManager.default.fileExists(atPath: downloadedBundle.path))
  }
}
