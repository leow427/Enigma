import Foundation
import Security

enum CodexRuntimeError: LocalizedError, Equatable {
  case invalidArchive
  case incomplete
  case wrongPackage
  case cannotStart
  case timedOut
  /// Anything else that failed after the download, such as a full disk.
  case installFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidArchive: "The Codex download contains unexpected files."
    case .incomplete: "The Codex download is incomplete."
    case .wrongPackage: "The Codex download is not the expected version for this Mac."
    case .cannotStart: "The downloaded Codex could not start on this Mac."
    case .timedOut: "Installing Codex took too long."
    case .installFailed(let message): message
    }
  }
}

/// Enigma's own copy of OpenAI's signed Codex package, downloaded on first
/// ChatGPT sign-in into Application Support, separate from the Codex home that
/// holds Enigma's Codex settings. The package is used as published: OpenAI's
/// signature must stay intact, so nothing in it is re-signed or modified.
struct CodexRuntime: Sendable {
  // To update, bump the version and take each size and digest from
  // `gh release view rust-v<version> --repo openai/codex --json assets`, then
  // check that the archive layout and `codex-package.json` still match `install`.
  // docs/ChatGPT-Setup.md also names the version, folder and sizes; update it too.
  static let version = "0.164.0"
  static let topLevelEntries: Set<String> = ["bin", "codex-package.json", "codex-path", "codex-resources"]

  let archive: VerifiedModelArtifact

  static var target: String {
    #if arch(arm64)
    "aarch64-apple-darwin"
    #else
    "x86_64-apple-darwin"
    #endif
  }

  static var pinned: CodexRuntime {
    #if arch(arm64)
    let size: Int64 = 136007998
    let checksum = "dd99e9092270691a67bdde7be04ac283dea9da8e86cbde356c2cc851a79205fa"
    #else
    let size: Int64 = 147158682
    let checksum = "cfb2a9988d7ea448511166a35789af07a0065d1117db54350b17d46cf03d0294"
    #endif
    return CodexRuntime(archive: VerifiedModelArtifact(
      url: URL(string: "https://github.com/openai/codex/releases/download/rust-v\(version)/codex-package-\(target).tar.gz")!,
      expectedByteCount: size, checksumSHA256: checksum))
  }

  static var downloadSize: String {
    ByteCountFormatter.string(fromByteCount: pinned.archive.expectedByteCount, countStyle: .file)
  }

  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AI Spotlight/Codex Runtime", directoryHint: .isDirectory)
  }

  static let folderName = "codex-\(version)"

  /// The pinned `codex` when it is installed in `directory`.
  static func installedExecutable(in directory: URL = directory) -> URL? {
    let executable = directory.appending(path: folderName + "/bin/codex")
    return CommandLineToolSearch.isExecutableFile(executable.path) ? executable : nil
  }

  /// The version in a `codex-<version>` folder name, or nil for any other name.
  static func versionNumbers(ofFolder name: String) -> [Int]? {
    guard name.hasPrefix("codex-") else { return nil }
    let parts = name.dropFirst("codex-".count).split(separator: ".", omittingEmptySubsequences: false)
    let numbers = parts.compactMap { Int($0) }
    return !parts.isEmpty && numbers.count == parts.count ? numbers : nil
  }

  static func isOlder(_ lhs: [Int], than rhs: [Int]) -> Bool {
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[index] : 0, right = index < rhs.count ? rhs[index] : 0
      if left != right { return left < right }
    }
    return false
  }

  /// Other versions' folders with a parseable version, newest first. Every Enigma
  /// build shares this directory, so another build's pin may be here too.
  static func otherVersionFolders(in directory: URL = directory) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0 != folderName && versionNumbers(ofFolder: $0) != nil }
      .sorted { isOlder(versionNumbers(ofFolder: $1)!, than: versionNumbers(ofFolder: $0)!) }
  }

  /// Versions older than the pin, newest first: the only ones cleanup removes.
  static func olderVersionFolders(in directory: URL = directory) -> [String] {
    let pinnedNumbers = versionNumbers(ofFolder: folderName) ?? []
    return otherVersionFolders(in: directory).filter { isOlder(versionNumbers(ofFolder: $0)!, than: pinnedNumbers) }
  }

  /// Other versions' executables, newest first, for when the pinned one is missing.
  static func fallbackExecutables(in directory: URL = directory) -> [URL] {
    otherVersionFolders(in: directory).map { directory.appending(path: $0 + "/bin/codex") }
      .filter { CommandLineToolSearch.isExecutableFile($0.path) }
  }

  enum LaunchStep: Equatable {
    case nothing
    /// The pinned version is installed, so older versions can go.
    case cleanUp([String])
    /// Only another built-in Codex is installed: download the pinned one quietly.
    case upgrade
  }

  /// What launch maintenance does. Old versions are removed only at launch, not
  /// right after an install, because a running app server or its code-mode host
  /// may still use its folder; new processes always use the pinned folder.
  /// A usable built-in Codex newer than the pin (another build's) means no
  /// upgrade: fallback already uses it, and that build's cleanup would remove
  /// this pin again, so the two would keep re-downloading each other's copy.
  static func launchStep(pinnedInstalled: Bool, olderFolders: [String], hasUsableOther: Bool,
                         hasUsableNewer: Bool = false) -> LaunchStep {
    if pinnedInstalled { return olderFolders.isEmpty ? .nothing : .cleanUp(olderFolders) }
    return hasUsableOther && !hasUsableNewer ? .upgrade : .nothing
  }

  /// Whether a usable built-in Codex newer than the pin is installed.
  static func hasUsableNewerVersion(in directory: URL = directory) -> Bool {
    let pinnedNumbers = versionNumbers(ofFolder: folderName) ?? []
    return otherVersionFolders(in: directory).contains { folder in
      isOlder(pinnedNumbers, than: versionNumbers(ofFolder: folder)!)
        && CommandLineToolSearch.isExecutableFile(directory.appending(path: folder + "/bin/codex").path)
    }
  }

  private enum FailureKey {
    static let version = "aiSpotlight.codexRuntime.lastFailedUpgradeVersion"
    static let date = "aiSpotlight.codexRuntime.lastFailedUpgradeDate"
  }

  static let upgradeRetryInterval: TimeInterval = 24 * 60 * 60

  /// One quiet install at a time in this process: the launch upgrade may still be
  /// downloading when the first daily check runs, and that check then skips.
  static let quietInstall = QuietInstallFlag()

  /// A quiet upgrade of the same version that failed less than a day ago waits,
  /// so a persistent failure doesn't download the package (about 136 MB) every time.
  static func shouldRetryUpgrade(lastFailedVersion: String?, lastFailedAt: Date?, now: Date) -> Bool {
    guard lastFailedVersion == version, let lastFailedAt else { return true }
    // A failure "in the future" means the clock moved; don't let it block retries.
    guard lastFailedAt <= now else { return true }
    return now.timeIntervalSince(lastFailedAt) >= upgradeRetryInterval
  }

  /// Runs once at launch, in the background: removes stale interrupted installs,
  /// then cleans up or quietly upgrades. The upgrade has no UI and never signs
  /// anyone in; the other copy keeps working meanwhile.
  @discardableResult
  static func maintainAtLaunch(
    in directory: URL = directory, defaults: UserDefaults = .standard, now: Date = Date(),
    upgrade: @Sendable (URL) async throws -> Void = {
      _ = try await install(into: $0, activity: .background, progress: { _ in })
    }
  ) async -> LaunchStep {
    removeStaleStaging(in: directory, now: now)
    let step = launchStep(pinnedInstalled: installedExecutable(in: directory) != nil,
                          olderFolders: olderVersionFolders(in: directory),
                          hasUsableOther: !fallbackExecutables(in: directory).isEmpty,
                          hasUsableNewer: hasUsableNewerVersion(in: directory))
    switch step {
    case .nothing: break
    case .cleanUp(let folders):
      for folder in folders { FileManager.default.removeItemIfPresent(at: directory.appending(path: folder)) }
    case .upgrade:
      guard shouldRetryUpgrade(lastFailedVersion: defaults.string(forKey: FailureKey.version),
                               lastFailedAt: defaults.object(forKey: FailureKey.date) as? Date, now: now),
            quietInstall.begin() else { break }
      defer { quietInstall.end() }
      do {
        try await upgrade(directory)
        defaults.removeObject(forKey: FailureKey.version)
        defaults.removeObject(forKey: FailureKey.date)
      } catch {
        defaults.set(version, forKey: FailureKey.version)
        defaults.set(now, forKey: FailureKey.date)
      }
    }
    return step
  }

  enum DailyStep: Equatable {
    case nothing
    /// Only another built-in Codex is installed: the launch upgrade, retried daily.
    case upgrade
    /// The Codex in use is an older system install (such as Homebrew's) and the person
    /// uses the ChatGPT route: install the pinned one, which is then preferred.
    case replaceOlderSystemCodex
  }

  /// What the daily check does. It never cleans up: a running app server may still use
  /// an older folder, so cleanup stays at launch. A system Codex is replaced only for
  /// people who use the ChatGPT route, so nobody else gets the download; only when it
  /// reports a version older than the pin, since OpenAI serves Codex's model list per
  /// client version, so an old Codex shows old models; and only when it is signed with
  /// OpenAI's Developer ID like the pinned package. Codex keeps the sign-in in the Keychain,
  /// where access follows the code identity of the binary that created the item, so only
  /// a switch between OpenAI-signed binaries stays silent.
  static func dailyStep(pinnedInstalled: Bool, hasUsableOther: Bool, hasUsableNewer: Bool,
                        usesChatGPT: Bool, systemVersion: [Int]?, systemSignedByOpenAI: Bool) -> DailyStep {
    if pinnedInstalled { return .nothing }
    if hasUsableOther { return hasUsableNewer ? .nothing : .upgrade }
    guard usesChatGPT, systemSignedByOpenAI, let systemVersion, let pinnedNumbers = versionNumbers(ofFolder: folderName),
          isOlder(systemVersion, than: pinnedNumbers) else { return .nothing }
    return .replaceOlderSystemCodex
  }

  /// OpenAI's Apple Developer team, which signs the Codex packages and npm binaries.
  static let openAITeamIdentifier = "2DC432GLL2"

  /// The Codex Enigma would run when it is a system install: not the developer override
  /// and not one of Enigma's built-in copies.
  static func systemExecutable(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runtimeDirectory: URL = directory,
    resolved: URL? = CodexRuntimeConfiguration.executableURL()
  ) -> URL? {
    guard let resolved else { return nil }
    if let override = environment["AI_SPOTLIGHT_CODEX_PATH"], resolved.path == override { return nil }
    let builtIn = runtimeDirectory.standardizedFileURL.path + "/"
    return resolved.standardizedFileURL.path.hasPrefix(builtIn) ? nil : resolved
  }

  /// The native binary behind a system `codex`. npm (and Homebrew's npm-based install)
  /// links `codex` to a Node script that runs the binary from the platform package; that
  /// binary is what creates the Keychain sign-in. Anything else is used as found.
  static func nativeExecutable(for executable: URL) -> URL {
    let resolved = executable.resolvingSymlinksInPath()
    guard resolved.pathExtension == "js", resolved.deletingLastPathComponent().lastPathComponent == "bin" else {
      return resolved
    }
    let package = resolved.deletingLastPathComponent().deletingLastPathComponent()
    #if arch(arm64)
    let platformPackage = "codex-darwin-arm64"
    #else
    let platformPackage = "codex-darwin-x64"
    #endif
    let binary = "vendor/\(target)/bin/codex"
    let candidates = [
      package.appending(path: "node_modules/@openai/\(platformPackage)/\(binary)"),
      package.deletingLastPathComponent().appending(path: "\(platformPackage)/\(binary)"),
      package.appending(path: binary),
    ]
    return candidates.first { CommandLineToolSearch.isExecutableFile($0.path) } ?? resolved
  }

  /// What another Codex must satisfy to read the Keychain sign-in silently: the `codex`
  /// identifier signed by OpenAI's Developer ID, as in the package's designated requirement.
  static let keychainRequirement =
    "identifier \"codex\" and anchor apple generic and certificate leaf[subject.OU] = \"\(openAITeamIdentifier)\""

  /// Whether `executable` has a valid code signature matching `keychainRequirement`.
  static func isSignedByOpenAI(_ executable: URL) -> Bool {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    let text = keychainRequirement
    guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
      return false
    }
    return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
  }

  /// The version in `codex --version` output: the token after `codex-cli` on the first
  /// line that has one, such as `codex-cli 0.153.4`. Other output (warnings on standard
  /// error) is ignored. A pre-release suffix (`0.164.0-alpha.1`) is dropped, so it counts
  /// as that release.
  static func versionNumbers(fromVersionOutput output: String) -> [Int]? {
    for line in output.split(whereSeparator: \.isNewline) {
      let tokens = line.split(whereSeparator: \.isWhitespace)
      guard let index = tokens.firstIndex(of: "codex-cli"), tokens.indices.contains(index + 1) else { continue }
      let release = tokens[index + 1].split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
      let parts = release.split(separator: ".", omittingEmptySubsequences: false)
      let numbers = parts.compactMap { Int($0) }
      return parts.count >= 2 && numbers.count == parts.count ? numbers : nil
    }
    return nil
  }

  /// Asks a Codex for its version (`codex --version`) in the same isolated environment
  /// the app server uses. Nil when it fails to run or prints something unexpected.
  static func reportedVersion(of executable: URL) async -> [Int]? {
    let directory = FileManager.default.temporaryDirectory
    let environment = CodexRuntimeConfiguration.live.environment(for: executable)
    guard let result = try? await run(executable, ["--version"], in: directory, environment: environment),
          result.status == 0 else { return nil }
    return versionNumbers(fromVersionOutput: result.output)
  }

  /// Runs daily in the background, the first time shortly after launch: installs the
  /// pinned Codex quietly when `dailyStep` says so, with the launch upgrade's retry rule
  /// (a failed install of this version waits a day). Never signs anyone in or out. Returns
  /// the step taken, and whether the install succeeded, so running app servers can switch.
  @discardableResult
  static func maintainDaily(
    in directory: URL = directory, defaults: UserDefaults = .standard, now: Date = Date(),
    usesChatGPT: Bool, systemExecutable: URL?,
    systemVersion: @Sendable (URL) async -> [Int]? = { await reportedVersion(of: nativeExecutable(for: $0)) },
    systemSignedByOpenAI: @Sendable (URL) -> Bool = { isSignedByOpenAI(nativeExecutable(for: $0)) },
    upgrade: @Sendable (URL) async throws -> Void = {
      _ = try await install(into: $0, activity: .background, progress: { _ in })
    }
  ) async -> (step: DailyStep, installed: Bool) {
    let pinnedInstalled = installedExecutable(in: directory) != nil
    let hasUsableOther = !fallbackExecutables(in: directory).isEmpty
    // Only ask the system Codex when the answer matters; the signature only when it is older.
    var systemNumbers: [Int]?
    var signed = false
    if !pinnedInstalled, !hasUsableOther, usesChatGPT, let systemExecutable {
      systemNumbers = await systemVersion(systemExecutable)
      if let systemNumbers, let pinnedNumbers = versionNumbers(ofFolder: folderName),
         isOlder(systemNumbers, than: pinnedNumbers) {
        signed = systemSignedByOpenAI(systemExecutable)
      }
    }
    let step = dailyStep(pinnedInstalled: pinnedInstalled, hasUsableOther: hasUsableOther,
                         hasUsableNewer: hasUsableNewerVersion(in: directory),
                         usesChatGPT: usesChatGPT, systemVersion: systemNumbers, systemSignedByOpenAI: signed)
    guard step != .nothing,
          shouldRetryUpgrade(lastFailedVersion: defaults.string(forKey: FailureKey.version),
                             lastFailedAt: defaults.object(forKey: FailureKey.date) as? Date, now: now),
          quietInstall.begin() else {
      return (step, false)
    }
    defer { quietInstall.end() }
    do {
      try await upgrade(directory)
      defaults.removeObject(forKey: FailureKey.version)
      defaults.removeObject(forKey: FailureKey.date)
      return (step, true)
    } catch {
      defaults.set(version, forKey: FailureKey.version)
      defaults.set(now, forKey: FailureKey.date)
      return (step, false)
    }
  }

  static let stagingMaximumAge: TimeInterval = 24 * 60 * 60

  /// Removes what an interrupted install left behind (an archive and an unpacked
  /// copy). Another Enigma instance may be installing right now, so only folders
  /// untouched for a day are removed.
  static func removeStaleStaging(in directory: URL, now: Date = Date()) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix(".staging-") {
      let url = directory.appending(path: name)
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      guard let modified, now.timeIntervalSince(modified) >= stagingMaximumAge else { continue }
      FileManager.default.removeItemIfPresent(at: url)
    }
  }

  /// Downloads, verifies and installs the pinned package unless it is already installed.
  @discardableResult
  static func install(into directory: URL = directory, session: URLSession = .shared,
                      activity: DownloadActivity = .system,
                      progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> URL {
    if let installed = installedExecutable(in: directory) { return installed }
    let runtime = pinned
    try runtime.archive.validate()
    let endActivity = activity.begin("Downloading Codex")
    defer { endActivity() }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    removeStaleStaging(in: directory)
    let staging = directory.appending(path: ".staging-" + UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { FileManager.default.removeItemIfPresent(at: staging) }
    let archive = staging.appending(path: "codex.tar.gz")
    try await runtime.archive.download(to: archive, session: session, progress: progress)
    // App setup with a pinned, checksum-verified archive; never an agent command.
    do {
      return try await install(archive: archive, staging: staging, into: directory)
    } catch let error as CodexRuntimeError {
      throw error
    } catch {
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      throw CodexRuntimeError.installFailed(error.localizedDescription)
    }
  }

  /// Extracts a verified archive into `staging`, checks it, then moves it into
  /// `directory` as this version's folder. Older versions stay until next launch.
  static func install(archive: URL, staging: URL, into directory: URL) async throws -> URL {
    let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
    let tar = URL(fileURLWithPath: "/usr/bin/tar")
    let listing = try await run(tar, ["-tzf", archive.path], in: staging)
    let paths = listing.output.split(whereSeparator: \.isNewline).map(String.init)
    guard listing.status == 0, !paths.isEmpty, paths.allSatisfy(isAllowedEntry) else {
      throw CodexRuntimeError.invalidArchive
    }
    guard try await run(tar, ["-xzf", archive.path, "--no-same-owner", "-C", unpacked.path], in: staging).status == 0 else {
      throw CodexRuntimeError.invalidArchive
    }
    let root = unpacked.resolvingSymlinksInPath().path + "/"
    let entries = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)
    while let url = entries?.nextObject() as? URL {
      guard url.resolvingSymlinksInPath().path.hasPrefix(root) else { throw CodexRuntimeError.invalidArchive }
      // A link to a missing file is not resolved above, so check its target too.
      // An absolute target would dangle once the folder moves into place.
      if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
        guard !target.hasPrefix("/") else { throw CodexRuntimeError.invalidArchive }
        let resolved = url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: target)
        guard resolved.standardizedFileURL.path.hasPrefix(root) else { throw CodexRuntimeError.invalidArchive }
      }
    }
    try validatePackage(at: unpacked)
    let codex = unpacked.appending(path: "bin/codex")
    let home = staging.appending(path: "home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let check = try await run(codex, ["--version"], in: staging, environment: [
      "PATH": "/usr/bin:/bin", "HOME": home.path, "CODEX_HOME": home.path, "LANG": "en_US.UTF-8",
    ])
    guard check.status == 0, check.output.contains(version) else { throw CodexRuntimeError.cannotStart }
    try Task.checkCancellation()
    let destination = directory.appending(path: folderName, directoryHint: .isDirectory)
    let installed = destination.appending(path: "bin/codex")
    // Another Enigma instance may have finished first; its copy may be in use.
    if CommandLineToolSearch.isExecutableFile(installed.path) { return installed }
    FileManager.default.removeItemIfPresent(at: destination)
    do {
      try FileManager.default.moveItem(at: unpacked, to: destination)
    } catch {
      if CommandLineToolSearch.isExecutableFile(installed.path) { return installed }
      throw error
    }
    return installed
  }

  static func isAllowedEntry(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard !path.hasPrefix("/"), let first = components.first else { return false }
    return topLevelEntries.contains(String(first)) && !components.contains("..")
  }

  private static func validatePackage(at root: URL) throws {
    guard let data = try? Data(contentsOf: root.appending(path: "codex-package.json")) else {
      throw CodexRuntimeError.incomplete
    }
    guard let package = try? JSONDecoder().decode(CodexValue.self, from: data),
          package["version"].string == version, package["target"].string == target,
          package["entrypoint"].string == "bin/codex" else { throw CodexRuntimeError.wrongPackage }
    for binary in ["bin/codex", "bin/codex-code-mode-host"] {
      guard CommandLineToolSearch.isExecutableFile(root.appending(path: binary).path) else {
        throw CodexRuntimeError.incomplete
      }
    }
  }

  private static func run(_ executable: URL, _ arguments: [String], in directory: URL,
                          environment: [String: String] = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"])
    async throws -> (status: Int32, output: String) {
    let output = directory.appending(path: "runtime-output-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let file = try FileHandle(forWritingTo: output)
    defer { try? file.close(); try? FileManager.default.removeItem(at: output) }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = directory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = file
    process.standardError = file
    let timedOut = TimeoutFlag()
    let timeout = Task {
      try await Task.sleep(for: .seconds(60))
      if process.isRunning { timedOut.set(); process.terminate() }
    }
    defer { timeout.cancel() }
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do {
          try process.run()
          if Task.isCancelled && process.isRunning { process.terminate() }
        } catch { continuation.resume(throwing: error) }
      }
      try Task.checkCancellation()
    } onCancel: { if process.isRunning { process.terminate() } }
    if timedOut.isSet { throw CodexRuntimeError.timedOut }
    return (process.terminationStatus, String(decoding: try Data(contentsOf: output), as: UTF8.self))
  }
}

final class QuietInstallFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var running = false

  /// False when an install is already running.
  func begin() -> Bool {
    lock.withLock {
      guard !running else { return false }
      running = true
      return true
    }
  }

  func end() { lock.withLock { running = false } }
}

private final class TimeoutFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool { lock.withLock { value } }
  func set() { lock.withLock { value = true } }
}

extension DownloadActivity {
  /// For work the person didn't start, such as a quiet upgrade: it lets the Mac sleep.
  static let background = DownloadActivity { reason in
    let token = BackgroundActivityToken(ProcessInfo.processInfo.beginActivity(options: .background, reason: reason))
    return { token.end() }
  }
}

private final class BackgroundActivityToken: @unchecked Sendable {
  private let lock = NSLock()
  private var token: (any NSObjectProtocol)?
  init(_ token: any NSObjectProtocol) { self.token = token }
  deinit { end() }
  func end() {
    let active: (any NSObjectProtocol)? = lock.withLock {
      defer { token = nil }
      return token
    }
    if let active { ProcessInfo.processInfo.endActivity(active) }
  }
}
