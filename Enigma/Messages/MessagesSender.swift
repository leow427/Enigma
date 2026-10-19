import Foundation

struct ProcessOutput: Sendable, Equatable {
  let status: Int32
  let output: String
  let error: String
}

/// Sends through Messages.app with AppleScript. The script is a constant read from standard
/// input; the target and text reach it only as `on run argv` arguments, so message content
/// can never change what the script does.
struct MessagesSender: Sendable {
  enum Target: Sendable, Equatable {
    /// An existing conversation, by `chat.guid`. Keeps its service (iMessage, SMS, or RCS).
    case chat(String)
    /// A handle with no conversation yet, sent over iMessage.
    case iMessage(String)
  }

  typealias Runner = @Sendable (_ executable: URL, _ arguments: [String], _ input: String) async throws -> ProcessOutput

  static let script = """
    on run argv
      if (count of argv) is not 3 then error "Enigma expected exactly three arguments." number 1
      set targetKind to item 1 of argv
      set targetValue to item 2 of argv
      set messageText to item 3 of argv
      tell application "Messages"
        if targetKind is "chat" then
          send messageText to chat id targetValue
        else if targetKind is "imessage" then
          send messageText to participant targetValue of (1st account whose service type = iMessage)
        else
          error "Unknown target kind." number 2
        end if
      end tell
      return "sent"
    end run
    """

  static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")

  var run: Runner = MessagesSender.runProcess

  /// `-` makes osascript read the script from standard input and ends option parsing, so
  /// arguments that begin with a dash are passed through unchanged.
  static func arguments(for target: Target, text: String) -> [String] {
    switch target {
    case .chat(let guid): ["-", "chat", guid, text]
    case .iMessage(let handle): ["-", "imessage", handle, text]
    }
  }

  func send(_ text: String, to target: Target) async throws {
    let result = try await run(Self.osascript, Self.arguments(for: target, text: text), Self.script)
    guard result.status == 0 else { throw Self.error(from: result.error) }
  }

  static func error(from output: String) -> MessagesError {
    let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
    // -1743: the user denied (or never answered) the Automation prompt for Messages.
    if detail.contains("-1743") || detail.localizedCaseInsensitiveContains("not authorized to send apple events") {
      return .automationDenied
    }
    if detail.contains("-1728") { return .chatNotFound }
    let message = detail.replacingOccurrences(of: #"^.*execution error: "#, with: "", options: .regularExpression)
    return .sendFailed(message.isEmpty ? "osascript failed without a message." : String(message.prefix(300)))
  }

  static let runProcess: Runner = { executable, arguments, input in
    let process = Process()
    let output = Pipe(), error = Pipe(), stdin = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = stdin
    process.standardOutput = output
    process.standardError = error
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { process in
          let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
          let err = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
          continuation.resume(returning: ProcessOutput(status: process.terminationStatus, output: out, error: err))
        }
        do {
          try process.run()
          // If osascript exits early, the write fails with EPIPE instead of signalling Enigma.
          _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
          try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
          try? stdin.fileHandleForWriting.close()
        } catch {
          process.terminationHandler = nil
          continuation.resume(throwing: MessagesError.sendFailed(error.localizedDescription))
        }
      }
    } onCancel: {
      if process.isRunning { process.terminate() }
    }
  }
}
