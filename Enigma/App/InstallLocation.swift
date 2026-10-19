import Foundation

/// Everything the install-location decision depends on, gathered by `MoveToApplicationsPrompt`.
struct InstallLocationContext: Equatable {
  /// `Bundle.main.bundleURL`; may be a translocated path.
  var bundleURL: URL
  var isTranslocated: Bool
  /// The bundle's real location when translocated and the system reports it; else nil.
  var originalURL: URL?
  var homeDirectory: URL
  var systemApplicationsIsWritable: Bool
  var dontAskAgain: Bool
  var isDebugBuild: Bool
}

enum InstallLocationDecision: Equatable {
  case stay
  /// Translocated, but the original already sits in an Applications folder.
  case reopenInPlace(original: URL)
  case move(destination: URL, inHomeFolder: Bool)
}

/// How an Enigma already at the destination compares with the running one.
enum ExistingCopyAge: Equatable { case older, same, newer, unknown }

/// Decides whether Enigma should offer to move into Applications. Pure: no AppKit,
/// no file-system writes, no globals.
enum InstallLocation {
  static let dontAskAgainKey = "installLocation.dontAskToMove"
  static let systemApplicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)
  private static let bundleName = "Enigma.app"

  static func decide(_ context: InstallLocationContext) -> InstallLocationDecision {
    if context.isDebugBuild || context.dontAskAgain { return .stay }
    if !context.isTranslocated,
      isInApplicationsFolder(context.bundleURL, homeDirectory: context.homeDirectory) {
      return .stay
    }
    if context.isTranslocated, let original = context.originalURL,
      isInApplicationsFolder(original, homeDirectory: context.homeDirectory) {
      return .reopenInPlace(original: original)
    }
    let inHomeFolder = !context.systemApplicationsIsWritable
    return .move(
      destination: destination(inHomeFolder: inHomeFolder, homeDirectory: context.homeDirectory),
      inHomeFolder: inHomeFolder)
  }

  /// Where Enigma installs; always named `Enigma.app`, whatever the running bundle is called.
  static func destination(inHomeFolder: Bool, homeDirectory: URL) -> URL {
    let folder = inHomeFolder
      ? homeDirectory.appending(path: "Applications", directoryHint: .isDirectory)
      : systemApplicationsFolder
    return folder.appending(path: bundleName, directoryHint: .notDirectory)
  }

  /// True when `url` is inside `/Applications` or `<home>/Applications`.
  static func isInApplicationsFolder(_ url: URL, homeDirectory: URL) -> Bool {
    let candidate = resolvedComponents(url)
    let folders = [
      systemApplicationsFolder,
      homeDirectory.appendingPathComponent("Applications", isDirectory: true),
    ]
    return folders.contains { folder in
      let prefix = resolvedComponents(folder)
      guard candidate.count > prefix.count else { return false }
      return zip(prefix, candidate).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
    }
  }

  private static func resolvedComponents(_ url: URL) -> [String] {
    url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
  }

  /// Compares dotted numeric versions ("0.10.2" vs "0.10.1"); nil or non-numeric → .unknown.
  static func age(ofExisting existing: String?, comparedTo running: String) -> ExistingCopyAge {
    guard let existing, let lhs = numericParts(existing), let rhs = numericParts(running) else {
      return .unknown
    }
    let count = max(lhs.count, rhs.count)
    let paddedLHS = lhs + Array(repeating: 0, count: count - lhs.count)
    let paddedRHS = rhs + Array(repeating: 0, count: count - rhs.count)
    if paddedLHS == paddedRHS { return .same }
    return paddedLHS.lexicographicallyPrecedes(paddedRHS) ? .older : .newer
  }

  private static func numericParts(_ version: String) -> [Int]? {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    let numbers = parts.compactMap { Int($0) }
    guard !parts.isEmpty, numbers.count == parts.count else { return nil }
    return numbers
  }
}

/// The wording of every alert the move shows. An empty `cancelButton` means one button.
struct InstallLocationAlertText: Equatable {
  var title: String
  var message: String
  var confirmButton: String
  var cancelButton: String

  static func moveOffer(inHomeFolder: Bool) -> Self {
    Self(
      title: "Move Enigma to Applications?",
      message: inHomeFolder
        ? "Enigma can only update itself from an Applications folder. It will move to the Applications folder in your home folder and reopen."
        : "Enigma can only update itself from the Applications folder. It will move there and reopen.",
      confirmButton: "Move to Applications",
      cancelButton: "Not Now")
  }

  static let reopenOffer = Self(
    title: "Reopen Enigma from Applications?",
    message: "macOS is running Enigma from a temporary copy, so it can't update itself. Enigma will reopen from Applications.",
    confirmButton: "Reopen",
    cancelButton: "Not Now")

  static func replace(existingVersion: String?, runningVersion: String, age: ExistingCopyAge) -> Self {
    let message: String
    switch (existingVersion, age) {
    case (let existing?, .older), (let existing?, .same):
      message = "Applications already has Enigma \(existing). The old copy goes to the Trash."
    case (let existing?, .newer):
      message = "Applications already has a newer Enigma (\(existing)). Replacing it installs \(runningVersion). The old copy goes to the Trash."
    default:
      message = "Applications already has a copy of Enigma. The old copy goes to the Trash."
    }
    return Self(
      title: "Replace the Enigma in Applications?",
      message: message,
      confirmButton: "Replace",
      cancelButton: "Cancel")
  }

  static func failure(reason: String) -> Self {
    Self(
      title: "Enigma couldn't move to Applications",
      message: "\(reason) Drag Enigma into Applications in Finder instead.",
      confirmButton: "OK",
      cancelButton: "")
  }
}
