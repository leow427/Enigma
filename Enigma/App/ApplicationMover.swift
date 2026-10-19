import AppKit
import Darwin

/// Installs a copy of Enigma into an Applications folder. Side effects outside the given
/// folders (the Trash, quitting a running copy) are injected so tests can run it in a
/// temporary directory.
struct ApplicationMover {
  enum MoveError: Error, Equatable, LocalizedError {
    /// `replacingExisting` was false and something is already at the destination.
    case destinationExists
    case couldNotCreateFolder(String)
    case couldNotCopy(String)
    /// Quitting or trashing the existing copy failed.
    case couldNotReplace(String)
    case couldNotRename(String)
    case couldNotClearQuarantine(String)

    var errorDescription: String? {
      switch self {
      case .destinationExists: "Applications already has a copy of Enigma."
      case .couldNotCreateFolder: "Enigma couldn't create the Applications folder."
      case .couldNotCopy: "Enigma couldn't copy itself into Applications."
      case .couldNotReplace: "Enigma couldn't move the old copy to the Trash."
      case .couldNotRename: "Enigma couldn't finish moving into Applications."
      case .couldNotClearQuarantine: "Enigma couldn't clear the download flag on the new copy."
      }
    }
  }

  private static let quarantineAttribute = "com.apple.quarantine"

  var fileManager: FileManager = .default
  /// Moves an item to the Trash.
  var trash: (URL) throws -> Void
  /// Quits any running Enigma whose bundle is at the URL and waits briefly for it to exit.
  var quitRunningCopy: (URL) -> Void

  init(
    fileManager: FileManager = .default,
    trash: @escaping (URL) throws -> Void = ApplicationMover.moveToTrash,
    quitRunningCopy: @escaping (URL) -> Void = ApplicationMover.quitRunningApplications
  ) {
    self.fileManager = fileManager
    self.trash = trash
    self.quitRunningCopy = quitRunningCopy
  }

  static func moveToTrash(_ url: URL) throws {
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
  }

  static func quitRunningApplications(at url: URL) {
    guard let identifier = Bundle.main.bundleIdentifier else { return }
    let target = url.resolvingSymlinksInPath().standardizedFileURL
    let current = ProcessInfo.processInfo.processIdentifier
    let copies = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
      $0.processIdentifier != current
        && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target
    }
    for copy in copies {
      copy.terminate()
    }
    let deadline = Date(timeIntervalSinceNow: 5)
    while copies.contains(where: { !$0.isTerminated }), Date() < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    for copy in copies where !copy.isTerminated {
      copy.forceTerminate()
    }
  }

  /// Bundle version of an existing copy at `url` (CFBundleShortVersionString), or nil.
  /// Reads `Info.plist` directly, because `Bundle` caches by path and would miss a replacement.
  func existingVersion(at url: URL) -> String? {
    let plistURL = url.appendingPathComponent("Contents/Info.plist")
    guard let data = fileManager.contents(atPath: plistURL.path),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return plist["CFBundleShortVersionString"] as? String
  }

  /// Installs `source` at `destination`. Throws `MoveError` on failure; the staged copy
  /// is removed if anything before the final rename fails.
  func install(from source: URL, to destination: URL, replacingExisting: Bool) throws {
    let folder = destination.deletingLastPathComponent()
    do {
      try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      throw MoveError.couldNotCreateFolder(error.localizedDescription)
    }

    // Stage in the same folder so the final step is a same-volume rename.
    let staging = folder.appendingPathComponent(".Enigma-\(UUID().uuidString).app", isDirectory: true)
    do {
      do {
        try fileManager.copyItem(at: source, to: staging)
      } catch {
        throw MoveError.couldNotCopy(error.localizedDescription)
      }

      if itemExists(at: destination) {
        guard replacingExisting else { throw MoveError.destinationExists }
        quitRunningCopy(destination)
        do {
          try trash(destination)
        } catch {
          throw MoveError.couldNotReplace(error.localizedDescription)
        }
      }

      do {
        try fileManager.moveItem(at: staging, to: destination)
      } catch {
        throw MoveError.couldNotRename(error.localizedDescription)
      }
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }

    try removeQuarantine(from: destination)
  }

  /// Removes `com.apple.quarantine` from `bundle` and everything inside it, without
  /// following symlinks.
  func removeQuarantine(from bundle: URL) throws {
    try removeQuarantineAttribute(at: bundle)
    guard let enumerator = fileManager.enumerator(
      at: bundle, includingPropertiesForKeys: nil, options: [],
      errorHandler: { _, _ in true })
    else { return }
    for case let item as URL in enumerator {
      try removeQuarantineAttribute(at: item)
    }
  }

  /// Trashes the downloaded original; logs and ignores failures.
  func discardOriginal(_ original: URL?, destination: URL) {
    guard let original else { return }
    let resolvedOriginal = original.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolvedOriginal != resolvedDestination else { return }
    do {
      try trash(original)
    } catch {
      NSLog("Unable to move the original Enigma to the Trash: %@", error.localizedDescription)
    }
  }

  private func itemExists(at url: URL) -> Bool {
    // `attributesOfItem` does not follow a symlink, so a dangling link still counts.
    (try? fileManager.attributesOfItem(atPath: url.path)) != nil
  }

  private func removeQuarantineAttribute(at url: URL) throws {
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return 0 }
      return removexattr(path, Self.quarantineAttribute, XATTR_NOFOLLOW)
    }
    guard result != 0 else { return }
    let code = errno
    guard code != ENOATTR else { return }
    throw MoveError.couldNotClearQuarantine(String(cString: strerror(code)))
  }
}
