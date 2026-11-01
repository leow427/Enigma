import Foundation
import os

/// Enigma's event log (F12): what the app did, never what anyone wrote. Each event goes to the
/// unified log and to a small rolling file in ~/Library/Logs/Enigma, so a bug report can include
/// earlier launches (`OSLogStore` reads only the current one). Never pass chat text, model output,
/// prompts, queries, URLs, file paths, or an error's description: errors log their domain and code.
final class EnigmaLog: Sendable {
  static let shared = EnigmaLog(
    directory: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/Enigma", isDirectory: true),
    // The test host is the installed app: keep its events out of the owner's log.
    writesFile: !TestHost.isActive)

  let fileURL: URL
  let previousFileURL: URL
  private let writesFile: Bool
  private let maximumFileSize: Int
  private let queue = DispatchQueue(label: "Enigma.event-log", qos: .utility)
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.leow427.AISpotlight", category: "events")

  /// Past `maximumFileSize` the file becomes the previous one, replacing the one before.
  init(directory: URL, writesFile: Bool, maximumFileSize: Int = 256 * 1024) {
    fileURL = directory.appendingPathComponent("Enigma.log")
    previousFileURL = directory.appendingPathComponent("Enigma.previous.log")
    self.writesFile = writesFile
    self.maximumFileSize = maximumFileSize
  }

  static func event(_ message: String) { shared.record(message) }
  static func event(_ message: String, error: Error) { shared.record(message, error: error) }

  func record(_ message: String, error: Error) {
    let error = error as NSError
    record("\(message) (\(error.domain) \(error.code))")
  }

  func record(_ message: String, date: Date = .now) {
    logger.notice("\(message, privacy: .public)")
    guard writesFile else { return }
    let line = Data("\(date.formatted(.iso8601)) \(message)\n".utf8)
    queue.async { [self] in append(line) }
  }

  /// The log files that exist, oldest first, once every event so far is written.
  var files: [URL] {
    queue.sync {}
    return [previousFileURL, fileURL].filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  private func append(_ line: Data) {
    let manager = FileManager.default
    try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let size = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
    if size + line.count > maximumFileSize, size > 0 {
      try? manager.removeItem(at: previousFileURL)
      try? manager.moveItem(at: fileURL, to: previousFileURL)
    }
    guard let handle = try? FileHandle(forWritingTo: fileURL) else {
      try? line.write(to: fileURL)
      return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: line)
  }
}
