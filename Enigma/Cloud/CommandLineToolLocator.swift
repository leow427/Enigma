import Foundation

/// Finds a command-line tool such as `codex` or `claude`. An app opened from
/// Finder gets a minimal `PATH`, so besides each tool's usual folders this also
/// checks the folders Node version managers, npm and Bun install into, the
/// login shell's answer, a file the person chose, and finally `PATH`.
struct CommandLineToolSearch: Sendable {
  let name: String
  /// Full paths checked first and never listed in "looked in", such as a
  /// developer override or Enigma's own runtime.
  var preferred: [String] = []
  /// The tool's usual install folders, in order.
  var usualFolders: [String]
  var home: String
  var environment: [String: String]
  /// What `$SHELL -ilc 'command -v name'` found, if it has been asked.
  var loginShellPath: String?
  /// A file the person chose, as a last resort.
  var chosenPath: String?

  /// Version-manager folders; each manager's newest Node version comes first.
  var managerFolders: [String] {
    var folders = Self.versionFolders(in: "\(home)/.nvm/versions/node").map { "\($0)/bin" }
    folders.append("\(home)/.volta/bin")
    for root in ["\(home)/.local/share/fnm/node-versions", "\(home)/Library/Application Support/fnm/node-versions"] {
      folders += Self.versionFolders(in: root).map { "\($0)/installation/bin" }
    }
    folders += ["\(home)/.asdf/shims", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
    return folders
  }

  var candidates: [String] {
    preferred
      + (usualFolders + managerFolders).map { "\($0)/\(name)" }
      + [loginShellPath, chosenPath].compactMap { $0 }
      + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
  }

  /// The first candidate that is an absolute path to an executable file, as
  /// found rather than symlink-resolved, so its own folder can go on `PATH`.
  func executableURL() -> URL? {
    candidates.first(where: Self.isExecutableFile).map { URL(fileURLWithPath: $0) }
  }

  /// Where the search looked, readable: folders rather than every Node version.
  var lookedIn: String {
    let folders = usualFolders + [
      "\(home)/.nvm/versions/node/*/bin", "\(home)/.volta/bin", "\(home)/.local/share/fnm",
      "\(home)/Library/Application Support/fnm", "\(home)/.asdf/shims", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
    ]
    var seen = Set<String>()
    let listed = folders.map(abbreviate).filter { seen.insert($0).inserted }
    return listed.joined(separator: ", ") + " and PATH"
  }

  func abbreviate(_ path: String) -> String {
    guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }

  static func isExecutableFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
  }

  /// A fixed `PATH` with the tool's own folder (and any `extra` folders) first,
  /// so a Node-based install finds the `node` installed beside it.
  static func path(for executable: URL, extra: [String] = []) -> String {
    let fixed = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    var seen = Set<String>()
    return ([executable.deletingLastPathComponent().path] + extra + fixed)
      .filter { seen.insert($0).inserted }
      .joined(separator: ":")
  }

  private static func versionFolders(in root: String) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
    return names.filter { !$0.hasPrefix(".") }
      .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
      .map { "\(root)/\($0)" }
  }
}

/// Asks the user's shell once per tool where it is (`$SHELL -ilc 'command -v tool'`),
/// off the main actor and with a short timeout. Interactive so zsh reads `~/.zshrc`,
/// where nvm, fnm, asdf and Bun usually add themselves. The synchronous lookups read
/// the cached answer, so they never wait for a shell.
final class LoginShellToolLookup: @unchecked Sendable {
  /// What the shell printed when it exited on its own, or nil when it failed to
  /// start, timed out or crashed.
  typealias Runner = @Sendable (_ shell: URL, _ arguments: [String], _ timeout: Duration) async -> String?

  /// Does nothing in a test host, so tests never run the developer's real shell.
  static let shared = LoginShellToolLookup(isEnabled: !TestHost.isActive)

  private let shell: URL
  private let timeout: Duration
  private let runner: Runner
  private let isEnabled: Bool
  private let lock = NSLock()
  private var answers: [String: String?] = [:]
  private var lookups: [String: (id: UUID, task: Task<String??, Never>)] = [:]

  init(shell: String? = ProcessInfo.processInfo.environment["SHELL"], timeout: Duration = .seconds(5),
       isEnabled: Bool = true, runner: @escaping Runner = LoginShellToolLookup.run) {
    let candidate = shell.flatMap { CommandLineToolSearch.isExecutableFile($0) ? $0 : nil } ?? "/bin/zsh"
    self.shell = URL(fileURLWithPath: candidate)
    self.timeout = timeout
    self.isEnabled = isEnabled
    self.runner = runner
  }

  /// The cached answer, or nil when there is none yet or the shell found nothing.
  func cachedPath(for tool: String) -> String? {
    lock.withLock { answers[tool] ?? nil }
  }

  /// Forgets a cached "not found", so an explicit check asks the shell again,
  /// for example after the person installed the tool. A found path is kept.
  func forgetNotFound(_ tool: String) {
    lock.withLock {
      if case .some(.none) = answers[tool] { answers[tool] = nil }
    }
  }

  /// Asks the shell unless it already answered. Only a definite answer is cached,
  /// including "not found"; a timeout or failure is asked again next time.
  @discardableResult
  func resolve(_ tool: String) async -> String? {
    guard isEnabled, tool.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil else { return nil }
    let (id, task): (UUID?, Task<String??, Never>) = lock.withLock {
      if let answer = answers[tool] { return (nil, Task { .some(answer) }) }
      if let running = lookups[tool] { return (running.id, running.task) }
      let running = Task.detached { [shell, timeout, runner] () -> String?? in
        guard let output = await runner(shell, ["-ilc", "command -v \(tool)"], timeout) else { return .none }
        return .some(Self.parse(output, tool: tool))
      }
      let id = UUID()
      lookups[tool] = (id, running)
      return (id, running)
    }
    let answer = await task.value
    lock.withLock {
      if let answer { answers.updateValue(answer, forKey: tool) }
      // A late waiter must not drop a newer lookup's entry.
      if let id, lookups[tool]?.id == id { lookups[tool] = nil }
    }
    return answer ?? nil
  }

  /// Accepts only an absolute path to an executable file named `tool`; a
  /// profile may print greetings, other paths or an alias definition too.
  static func parse(_ output: String?, tool: String) -> String? {
    guard let output else { return nil }
    return output.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .last { $0.hasPrefix("/") && URL(fileURLWithPath: $0).lastPathComponent == tool
        && CommandLineToolSearch.isExecutableFile($0) }
  }

  static let run: Runner = { shell, arguments, timeout in
    let output = FileManager.default.temporaryDirectory.appending(path: "enigma-shell-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: output.path, contents: nil),
          let file = try? FileHandle(forWritingTo: output) else { return nil }
    defer { try? file.close(); try? FileManager.default.removeItem(at: output) }
    let process = Process()
    process.executableURL = shell
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = file
    process.standardError = FileHandle.nullDevice
    let finished: Bool = await withCheckedContinuation { continuation in
      let once = ResumeOnce(continuation)
      process.terminationHandler = { _ in once.resume(true) }
      do { try process.run() } catch { once.resume(false); return }
      Task {
        try? await Task.sleep(for: timeout)
        // An interactive shell ignores SIGTERM. `Process` makes the shell a process
        // group leader, so this also ends anything its profile started.
        if process.isRunning {
          let pid = process.processIdentifier
          if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
        }
        once.resume(false)
      }
    }
    // `command -v` exits 1 when the tool isn't found (127 in fish): a definite answer too.
    guard finished, process.terminationReason == .exit,
          [0, 1, 127].contains(process.terminationStatus) else { return nil }
    return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
  }
}

/// Whether this process hosts XCTest, which must never run the developer's
/// shell or download anything.
enum TestHost {
  static let isActive = NSClassFromString("XCTestCase") != nil
}

private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Bool, Never>?

  init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

  func resume(_ value: Bool) {
    let pending: CheckedContinuation<Bool, Never>? = lock.withLock {
      defer { continuation = nil }
      return continuation
    }
    pending?.resume(returning: value)
  }
}
