import Foundation
import XCTest
@testable import Enigma

/// Finding Codex and Claude Code, and installing Enigma's pinned Codex, with
/// temporary folders, an injected home and environment, and fixture archives.
final class CloudToolInstallTests: XCTestCase {
  // MARK: Lookup

  func testCodexLookupOrderPrefersOverrideThenPinnedRuntimeAndDropsAppBundles() {
    let home = "/Users/someone"
    let runtime = URL(fileURLWithPath: "/tmp/runtime-root")
    let search = CodexRuntimeConfiguration.search(
      environment: ["AI_SPOTLIGHT_CODEX_PATH": "/override/codex", "PATH": "/path-one:/path-two"],
      home: home, runtimeDirectory: runtime, loginShellPath: "/shell/codex")
    let candidates = search.candidates
    XCTAssertEqual(Array(candidates.prefix(5)), [
      "/override/codex", "/tmp/runtime-root/codex-\(CodexRuntime.version)/bin/codex",
      "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
    ])
    XCTAssertEqual(Array(candidates.suffix(3)), ["/shell/codex", "/path-one/codex", "/path-two/codex"])
    for folder in ["\(home)/.volta/bin", "\(home)/.asdf/shims", "\(home)/.npm-global/bin", "\(home)/.bun/bin"] {
      XCTAssertTrue(candidates.contains("\(folder)/codex"), folder)
    }
    XCTAssertFalse(candidates.contains { $0.contains(".app/") }, "ChatGPT.app and Codex.app are no longer candidates")
  }

  func testClaudeLookupOrderPutsChosenFileBeforePATH() {
    let home = "/Users/someone"
    let candidates = ClaudeCodeRuntime.search(
      environment: ["AI_SPOTLIGHT_CLAUDE_PATH": "/override/claude", "PATH": "/path-one"],
      home: home, loginShellPath: "/shell/claude", chosenPath: "/chosen/claude").candidates
    XCTAssertEqual(Array(candidates.prefix(5)), [
      "/override/claude", "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
      "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
    ])
    XCTAssertEqual(Array(candidates.suffix(3)), ["/shell/claude", "/chosen/claude", "/path-one/claude"])
  }

  func testSearchFindsTheFirstExecutableInEveryKindOfFolder() throws {
    let root = try temporaryDirectory()
    let home = root.appending(path: "home").path
    func search(environment: [String: String] = [:], shell: String? = nil, chosen: String? = nil) -> CommandLineToolSearch {
      CommandLineToolSearch(name: "tool", preferred: [root.appending(path: "runtime/bin/tool").path],
                            usualFolders: [root.appending(path: "system").path], home: home,
                            environment: environment, loginShellPath: shell, chosenPath: chosen)
    }
    XCTAssertNil(search().executableURL())

    let onPath = try executable(at: root.appending(path: "on-path/tool"))
    XCTAssertEqual(search(environment: ["PATH": onPath.deletingLastPathComponent().path]).executableURL(), onPath)
    let chosen = try executable(at: root.appending(path: "chosen/tool"))
    XCTAssertEqual(search(environment: ["PATH": onPath.deletingLastPathComponent().path],
                          chosen: chosen.path).executableURL(), chosen)
    let shell = try executable(at: root.appending(path: "shell/tool"))
    XCTAssertEqual(search(shell: shell.path, chosen: chosen.path).executableURL(), shell)

    // A chosen path only counts while it is still an executable file.
    let notExecutable = root.appending(path: "plain/tool")
    try FileManager.default.createDirectory(at: notExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("text".utf8).write(to: notExecutable)
    XCTAssertNil(search(chosen: notExecutable.path).executableURL())
    XCTAssertNil(search(chosen: root.path).executableURL(), "A folder is not a tool")
    XCTAssertNil(search(chosen: "relative/tool").executableURL())

    let bun = try executable(at: URL(fileURLWithPath: home).appending(path: ".bun/bin/tool"))
    XCTAssertEqual(search(shell: shell.path).executableURL(), bun)
    let volta = try executable(at: URL(fileURLWithPath: home).appending(path: ".volta/bin/tool"))
    XCTAssertEqual(search().executableURL(), volta)
    let system = try executable(at: root.appending(path: "system/tool"))
    XCTAssertEqual(search().executableURL(), system)
    let runtime = try executable(at: root.appending(path: "runtime/bin/tool"))
    XCTAssertEqual(search().executableURL(), runtime)
  }

  func testVersionManagerFoldersListNewestNodeFirst() throws {
    let root = try temporaryDirectory()
    let home = root.path
    for version in ["v9.0.0", "v20.11.1", "v18.2.0"] {
      try FileManager.default.createDirectory(at: root.appending(path: ".nvm/versions/node/\(version)/bin"),
                                              withIntermediateDirectories: true)
    }
    for version in ["v22.1.0", "v22.10.0"] {
      try FileManager.default.createDirectory(at: root.appending(path: ".local/share/fnm/node-versions/\(version)"),
                                              withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(
      at: root.appending(path: "Library/Application Support/fnm/node-versions/v21.0.0"), withIntermediateDirectories: true)
    let folders = CommandLineToolSearch(name: "claude", usualFolders: [], home: home, environment: [:]).managerFolders
    XCTAssertEqual(folders, [
      "\(home)/.nvm/versions/node/v20.11.1/bin", "\(home)/.nvm/versions/node/v18.2.0/bin",
      "\(home)/.nvm/versions/node/v9.0.0/bin", "\(home)/.volta/bin",
      "\(home)/.local/share/fnm/node-versions/v22.10.0/installation/bin",
      "\(home)/.local/share/fnm/node-versions/v22.1.0/installation/bin",
      "\(home)/Library/Application Support/fnm/node-versions/v21.0.0/installation/bin",
      "\(home)/.asdf/shims", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
    ])
    let claude = try executable(at: root.appending(path: ".nvm/versions/node/v20.11.1/bin/claude"))
    _ = try executable(at: root.appending(path: ".nvm/versions/node/v9.0.0/bin/claude"))
    XCTAssertEqual(CommandLineToolSearch(name: "claude", usualFolders: [], home: home, environment: [:]).executableURL(), claude)
  }

  @MainActor
  func testNotFoundSaysWhereEnigmaLookedWithHomeAbbreviated() {
    let home = "/Users/someone"
    let lookedIn = ClaudeCodeRuntime.search(environment: [:], home: home, loginShellPath: nil, chosenPath: nil).lookedIn
    XCTAssertTrue(lookedIn.hasPrefix("~/.local/bin, ~/.claude/local, /opt/homebrew/bin, /usr/local/bin, "), lookedIn)
    XCTAssertTrue(lookedIn.contains("~/.nvm/versions/node/*/bin"))
    XCTAssertTrue(lookedIn.contains("~/.volta/bin"))
    XCTAssertTrue(lookedIn.contains("~/.bun/bin"))
    XCTAssertTrue(lookedIn.hasSuffix(" and PATH"))
    XCTAssertFalse(lookedIn.contains(home))
    let message = SignInCheckResult.message(.notInstalled, product: "Claude Code", lookedIn: lookedIn)
    XCTAssertEqual(message.0, .problem)
    XCTAssertEqual(message.1, "Claude Code not found on this Mac (looked in \(lookedIn))")
    XCTAssertEqual(SignInCheckResult.message(.notInstalled, product: "Codex").1, "Codex not found on this Mac")
    let download = SignInCheckResult.message(.notSignedInNeedsCodexDownload, product: "Codex")
    XCTAssertEqual(download.0, .off)
    XCTAssertEqual(download.1, "Not signed in · Sign in downloads Codex from OpenAI (\(CodexRuntime.downloadSize))")

    let codex = CodexRuntimeConfiguration.search(environment: [:], home: home,
                                                 runtimeDirectory: URL(fileURLWithPath: "/runtime"), loginShellPath: nil)
    XCTAssertFalse(codex.lookedIn.contains("/runtime"), "Enigma's own runtime is not a place people install to")
    XCTAssertTrue(codex.lookedIn.hasPrefix("/opt/homebrew/bin, /usr/local/bin, ~/.local/bin"))
  }

  // MARK: Login shell

  func testLoginShellAnswerIsParsedAndCachedForTheSession() async throws {
    let root = try temporaryDirectory()
    let claude = try executable(at: root.appending(path: "bin/claude"))
    let calls = CallCounter()
    let lookup = LoginShellToolLookup(shell: "/bin/sh", timeout: .seconds(3)) { shell, arguments, timeout in
      calls.record("\(shell.path) \(arguments.joined(separator: " ")) \(timeout)")
      return "Welcome back!\n\(claude.path)\n"
    }
    XCTAssertNil(lookup.cachedPath(for: "claude"))
    let found = await lookup.resolve("claude")
    let again = await lookup.resolve("claude")
    XCTAssertEqual(found, claude.path)
    XCTAssertEqual(again, claude.path)
    XCTAssertEqual(lookup.cachedPath(for: "claude"), claude.path)
    XCTAssertEqual(calls.values, ["/bin/sh -ilc command -v claude 3.0 seconds"],
                   "Interactive, so zsh reads ~/.zshrc where version managers add themselves")

    let rejected = await lookup.resolve("claude; rm -rf ~")
    XCTAssertNil(rejected)
    XCTAssertEqual(calls.values.count, 1, "Only a plain tool name reaches the shell")
  }

  func testLoginShellAnswerMustBeAnAbsoluteExecutable() throws {
    let root = try temporaryDirectory()
    let plain = root.appending(path: "plain")
    try Data("x".utf8).write(to: plain)
    XCTAssertNil(LoginShellToolLookup.parse(nil, tool: "claude"))
    XCTAssertNil(LoginShellToolLookup.parse("", tool: "claude"))
    XCTAssertNil(LoginShellToolLookup.parse("alias claude='~/.claude/local/claude'", tool: "claude"))
    XCTAssertNil(LoginShellToolLookup.parse("claude", tool: "claude"))
    XCTAssertNil(LoginShellToolLookup.parse(plain.path, tool: "plain"))
    XCTAssertNil(LoginShellToolLookup.parse(root.path, tool: root.lastPathComponent))
    XCTAssertEqual(LoginShellToolLookup.parse("/bin/sh\n", tool: "sh"), "/bin/sh")

    // A profile that prints another program's path must not pass for the tool.
    XCTAssertNil(LoginShellToolLookup.parse("/bin/sh\n", tool: "claude"))
    let claude = try executable(at: root.appending(path: "bin/claude"))
    XCTAssertEqual(LoginShellToolLookup.parse("/bin/sh\n\(claude.path)\n/bin/ls\n", tool: "claude"), claude.path)
  }

  func testLoginShellTimeoutIsRetriedButADefiniteNotFoundIsCached() async throws {
    let root = try temporaryDirectory()
    let slowShell = try executable(at: root.appending(path: "slow-shell"), script: "#!/bin/sh\nexec sleep 30\n")
    let started = ContinuousClock.now
    let output = await LoginShellToolLookup.run(slowShell, ["-ilc", "command -v codex"], .milliseconds(200))
    XCTAssertNil(output, "A timeout is not an answer")
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))

    let answeringShell = try executable(at: root.appending(path: "shell"), script: "#!/bin/sh\necho \"$2\"\necho /bin/sh\n")
    let answer = await LoginShellToolLookup.run(answeringShell, ["-ilc", "command -v codex"], .seconds(5))
    XCTAssertEqual(answer, "command -v codex\n/bin/sh\n")
    let notFoundShell = try executable(at: root.appending(path: "not-found"), script: "#!/bin/sh\nexit 1\n")
    let notFound = await LoginShellToolLookup.run(notFoundShell, ["-ilc", "command -v codex"], .seconds(5))
    XCTAssertEqual(notFound, "", "command -v exits 1 when nothing is found: a definite answer")
    let fishShell = try executable(at: root.appending(path: "fish"), script: "#!/bin/sh\nexit 127\n")
    let fish = await LoginShellToolLookup.run(fishShell, ["-ilc", "command -v codex"], .seconds(5))
    XCTAssertEqual(fish, "", "fish exits 127 when command -v finds nothing")
    let brokenShell = try executable(at: root.appending(path: "broken"), script: "#!/bin/sh\nexit 2\n")
    let broken = await LoginShellToolLookup.run(brokenShell, ["-ilc", "command -v codex"], .seconds(5))
    XCTAssertNil(broken)

    // A timeout ends what the profile started too, not just the shell.
    let pidFile = root.appending(path: "child-pid")
    let spawningShell = try executable(at: root.appending(path: "spawning"),
                                       script: "#!/bin/sh\nsleep 30 &\necho $! > '\(pidFile.path)'\nwait\n")
    let spawned = await LoginShellToolLookup.run(spawningShell, ["-ilc", "command -v codex"], .milliseconds(300))
    XCTAssertNil(spawned)
    let child = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while kill(child, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertNotEqual(kill(child, 0), 0, "The profile's child process outlived the timeout")

    let found = try executable(at: root.appending(path: "bin/codex"))
    let replies = CallCounter()
    let lookup = LoginShellToolLookup(shell: "/bin/sh") { _, _, timeout in
      replies.record("asked")
      XCTAssertEqual(timeout, .seconds(5))
      return replies.values.count == 1 ? nil : found.path
    }
    let first = await lookup.resolve("codex")
    XCTAssertNil(first)
    XCTAssertNil(lookup.cachedPath(for: "codex"))
    let second = await lookup.resolve("codex")
    XCTAssertEqual(second, found.path, "A failed or timed-out lookup is asked again")
    _ = await lookup.resolve("codex")
    XCTAssertEqual(replies.values.count, 2)

    let empty = CallCounter()
    let nothing = LoginShellToolLookup(shell: "/bin/sh") { _, _, _ in empty.record("asked"); return "" }
    let none = await nothing.resolve("claude")
    let again = await nothing.resolve("claude")
    XCTAssertNil(none)
    XCTAssertNil(again)
    XCTAssertEqual(empty.values.count, 1, "A clean \"not found\" is cached for the session")
  }

  func testForgettingNotFoundAsksAgainButKeepsAFoundPath() async throws {
    let root = try temporaryDirectory()
    let codex = try executable(at: root.appending(path: "bin/codex"))
    let calls = CallCounter()
    let lookup = LoginShellToolLookup(shell: "/bin/sh") { _, _, _ in
      calls.record("asked")
      return calls.values.count == 1 ? "" : codex.path
    }
    let first = await lookup.resolve("codex")
    XCTAssertNil(first)
    _ = await lookup.resolve("codex")
    XCTAssertEqual(calls.values.count, 1, "Background refreshes use the cached answer")
    lookup.forgetNotFound("codex")
    let found = await lookup.resolve("codex")
    XCTAssertEqual(found, codex.path)
    lookup.forgetNotFound("codex")
    _ = await lookup.resolve("codex")
    XCTAssertEqual(calls.values.count, 2, "A found path is kept")
  }

  func testTestHostsNeverAskTheRealShell() async {
    let found = await LoginShellToolLookup.shared.resolve("sh")
    XCTAssertNil(found)
    let disabled = CallCounter()
    let lookup = LoginShellToolLookup(isEnabled: false) { _, _, _ in disabled.record("asked"); return "/bin/sh" }
    let answer = await lookup.resolve("sh")
    XCTAssertNil(answer)
    XCTAssertTrue(disabled.values.isEmpty)
  }

  // MARK: Running with the tool's own folder on PATH

  func testToolsRunWithTheirOwnFolderFirstOnPATH() throws {
    let root = try temporaryDirectory()
    let tool = URL(fileURLWithPath: root.path + "/link-folder/codex")
    let path = CommandLineToolSearch.path(for: tool, extra: ["/extra"])
    XCTAssertEqual(path.split(separator: ":").prefix(3).map(String.init), [root.path + "/link-folder", "/extra", "/opt/homebrew/bin"])
    XCTAssertTrue(path.hasSuffix("/usr/bin:/bin:/usr/sbin:/sbin"))

    let configuration = CodexRuntimeConfiguration(directory: root.appending(path: "home"))
    let package = root.appending(path: "codex-\(CodexRuntime.version)")
    try FileManager.default.createDirectory(at: package.appending(path: "codex-path"), withIntermediateDirectories: true)
    let pinned = try executable(at: package.appending(path: "bin/codex"))
    let environment = configuration.environment(for: pinned)
    XCTAssertEqual(environment["PATH"]?.split(separator: ":").prefix(2).map(String.init),
                   [package.appending(path: "bin").path, package.appending(path: "codex-path").path])
    XCTAssertEqual(environment["CODEX_HOME"], root.appending(path: "home").path)
    let system = configuration.environment(for: URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
    XCTAssertEqual(system["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL"] { XCTAssertNil(environment[key], key) }
  }

  func testClaudeCodeRunsWithItsOwnFolderOnPATH() async throws {
    let root = try temporaryDirectory()
    let claude = try executable(at: root.appending(path: "node-bin/claude"), script: "#!/bin/sh\necho \"$PATH\"\n")
    let runtime = ClaudeCodeRuntime(directory: root.appending(path: "runtime"), executable: { claude })
    let process = try runtime.launch(arguments: [], input: nil)
    var output = Data()
    for await chunk in process.output { output.append(chunk) }
    let path = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(path.split(separator: ":").first.map(String.init), root.appending(path: "node-bin").path)
  }

  // MARK: Codex runtime install

  @MainActor
  func testConnectionStatusesFollowTheFlowInOrder() {
    XCTAssertEqual(ChatGPTConnectionControls.status(isConnected: true, isSigningIn: true, isDownloading: true,
                                                    isInstalling: true).1, "connected")
    // Like Claude's row, ChatGPT's says when it's the provider Cloud uses.
    XCTAssertEqual(ChatGPTConnectionControls.status(isConnected: true, isSelected: true, isSigningIn: false).1,
                   "connected · selected for cloud")
    XCTAssertEqual(ChatGPTConnectionControls.status(isConnected: false, isSelected: true, isSigningIn: false).1,
                   "not connected", "Selected but signed out isn't in use")
    XCTAssertEqual(ChatGPTConnectionControls.status(isConnected: false, isSigningIn: true, isDownloading: true,
                                                    isInstalling: true).1, "installing Codex")
    XCTAssertEqual(ChatGPTConnectionControls.status(isConnected: false, isSigningIn: true, isDownloading: true).1,
                   "downloading Codex")
    XCTAssertEqual(ChatGPTConnectionControls.status(isConnected: false, isSigningIn: true).1, "signing in")
    XCTAssertEqual(ChatGPTConnectionControls.status(isConnected: false, isSigningIn: false).0, .off)
    for busy in [ChatGPTConnectionControls.status(isConnected: false, isSigningIn: true, isDownloading: true),
                 ChatGPTConnectionControls.status(isConnected: false, isSigningIn: true)] {
      XCTAssertEqual(busy.0, .busy)
    }
    let installing = ClaudeCodeConnectionControls.status(isConnected: false, isSelected: false, isWaiting: true,
                                                         isInstalling: true)
    XCTAssertEqual(installing.0, .busy)
    XCTAssertEqual(installing.1, "installing")
    XCTAssertEqual(ClaudeCodeConnectionControls.status(isConnected: false, isSelected: false, isWaiting: true).1,
                   "signing in")
    XCTAssertEqual(ClaudeCodeConnectionControls.status(isConnected: false, isSelected: false, isWaiting: true,
                                                       isInstalling: true, isFound: true).1,
                   "signing in", "Once the installed Claude Code is found, the wait is for sign-in")
    XCTAssertEqual(ClaudeCodeConnectionControls.status(isConnected: true, isSelected: true, isWaiting: true,
                                                       isInstalling: true).1, "connected · selected for cloud")
  }

  @MainActor
  func testPinnedCodexMatchesTheOfficialReleaseForThisMac() throws {
    let archive = CodexRuntime.pinned.archive
    try archive.validate()
    XCTAssertEqual(archive.url.host, "github.com")
    XCTAssertTrue(archive.url.path.hasPrefix("/openai/codex/releases/download/rust-v\(CodexRuntime.version)/"))
    XCTAssertTrue(archive.url.lastPathComponent.hasSuffix("\(CodexRuntime.target).tar.gz"))
    XCTAssertEqual(CodexRuntime.downloadSize,
                   ByteCountFormatter.string(fromByteCount: archive.expectedByteCount, countStyle: .file))
    XCTAssertTrue(ChatGPTConnectionControls.downloadNote.hasSuffix(CodexRuntime.downloadSize))
  }

  func testInstallExtractsCheckedPackageAndRemovesOlderVersions() async throws {
    let root = try temporaryDirectory()
    let installs = root.appending(path: "Codex Runtime")
    let old = installs.appending(path: "codex-0.100.0/bin")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let unrelated = installs.appending(path: "notes")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    let archive = try makePackage(in: root)
    let staging = try stagingDirectory(in: installs)
    XCTAssertNil(CodexRuntime.installedExecutable(in: installs))
    let codex = try await CodexRuntime.install(archive: archive, staging: staging, into: installs)
    XCTAssertEqual(codex.path, installs.appending(path: "codex-\(CodexRuntime.version)/bin/codex").path)
    XCTAssertEqual(CodexRuntime.installedExecutable(in: installs)?.path, codex.path)
    XCTAssertTrue(FileManager.default.isExecutableFile(
      atPath: installs.appending(path: "codex-\(CodexRuntime.version)/bin/codex-code-mode-host").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: installs.appending(path: "codex-\(CodexRuntime.version)/codex-path/rg").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path),
                  "A running app server may still use an older folder, so install leaves it")
    XCTAssertEqual(CodexRuntimeConfiguration.executableURL(environment: [:], home: root.path, runtimeDirectory: installs,
                                                           loginShellPath: nil), codex)

    // An installed runtime is used without downloading again.
    let reused = try await CodexRuntime.install(into: installs, session: noNetworkSession(),
                                                activity: DownloadActivity { _ in {} }, progress: { _ in })
    XCTAssertEqual(reused, codex)

    // The next launch, with the pinned version installed, removes older ones.
    let stale = try stagingDirectory(in: installs, age: .day)
    let fresh = try stagingDirectory(in: installs)
    let newer = try executable(at: installs.appending(path: "codex-9.0.0/bin/codex"))
    let unparseable = try executable(at: installs.appending(path: "codex-foo/bin/codex"))
    let defaults = try temporaryDefaults()
    let step = await CodexRuntime.maintainAtLaunch(in: installs, defaults: defaults,
                                                   upgrade: { _ in XCTFail("Already up to date") })
    XCTAssertEqual(step, .cleanUp(["codex-0.100.0"]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path))
    XCTAssertTrue(CommandLineToolSearch.isExecutableFile(newer.path), "Another build's newer pin stays")
    XCTAssertTrue(CommandLineToolSearch.isExecutableFile(unparseable.path), "Names that aren't versions stay")
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "Day-old interrupted installs are removed")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "Another instance may be installing now")
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "Only codex-* folders are removed")
    XCTAssertEqual(CodexRuntime.installedExecutable(in: installs), codex)
  }

  func testOlderBuiltInCodexKeepsWorkingUntilThePinnedOneIsInstalled() throws {
    let root = try temporaryDirectory()
    let installs = root.appending(path: "Codex Runtime")
    let older = try executable(at: installs.appending(path: "codex-0.9.0/bin/codex"))
    let newer = try executable(at: installs.appending(path: "codex-0.100.0/bin/codex"))
    _ = try executable(at: installs.appending(path: "codex-foo/bin/codex"))
    _ = try executable(at: installs.appending(path: "codex-1.2.x/bin/codex"))
    try FileManager.default.createDirectory(at: installs.appending(path: "codex-0.200.0/bin"), withIntermediateDirectories: true)
    XCTAssertEqual(CodexRuntime.otherVersionFolders(in: installs), ["codex-0.200.0", "codex-0.100.0", "codex-0.9.0"],
                   "Numeric order; names that aren't versions are ignored")
    XCTAssertEqual(CodexRuntime.olderVersionFolders(in: installs), ["codex-0.100.0", "codex-0.9.0"])
    XCTAssertEqual(CodexRuntime.fallbackExecutables(in: installs), [newer, older], "Folders without codex are skipped")
    let search = CodexRuntimeConfiguration.search(environment: [:], home: root.path, runtimeDirectory: installs, loginShellPath: nil)
    XCTAssertEqual(Array(search.candidates.prefix(3)), [
      installs.appending(path: "codex-\(CodexRuntime.version)/bin/codex").path, newer.path, older.path,
    ])
    XCTAssertEqual(search.executableURL(), newer)
    let pinned = try executable(at: installs.appending(path: "codex-\(CodexRuntime.version)/bin/codex"))
    XCTAssertEqual(CodexRuntimeConfiguration.executableURL(environment: [:], home: root.path, runtimeDirectory: installs,
                                                           loginShellPath: nil), pinned)
    XCTAssertEqual(CodexRuntime.versionNumbers(ofFolder: "codex-0.163.0"), [0, 163, 0])
    XCTAssertNil(CodexRuntime.versionNumbers(ofFolder: "codex-"))
    XCTAssertNil(CodexRuntime.versionNumbers(ofFolder: "codex-1..2"))
    XCTAssertNil(CodexRuntime.versionNumbers(ofFolder: "notes"))
  }

  func testLaunchStepCleansUpOnlyOnceThePinnedVersionIsInstalled() {
    XCTAssertEqual(CodexRuntime.launchStep(pinnedInstalled: false, olderFolders: [], hasUsableOther: false), .nothing)
    XCTAssertEqual(CodexRuntime.launchStep(pinnedInstalled: true, olderFolders: [], hasUsableOther: true), .nothing)
    XCTAssertEqual(CodexRuntime.launchStep(pinnedInstalled: true, olderFolders: ["codex-0.1.0"], hasUsableOther: true),
                   .cleanUp(["codex-0.1.0"]))
    XCTAssertEqual(CodexRuntime.launchStep(pinnedInstalled: false, olderFolders: ["codex-0.1.0"], hasUsableOther: true),
                   .upgrade)
    XCTAssertEqual(CodexRuntime.launchStep(pinnedInstalled: false, olderFolders: ["codex-0.1.0"], hasUsableOther: false),
                   .nothing, "A broken leftover alone is not worth a background download")
    XCTAssertEqual(CodexRuntime.launchStep(pinnedInstalled: false, olderFolders: ["codex-0.1.0"], hasUsableOther: true,
                                           hasUsableNewer: true),
                   .nothing, "Another build's newer copy is used instead of re-downloading this pin")
    XCTAssertEqual(CodexRuntime.launchStep(pinnedInstalled: true, olderFolders: ["codex-0.1.0"], hasUsableOther: true,
                                           hasUsableNewer: true), .cleanUp(["codex-0.1.0"]))
  }

  func testFailedQuietUpgradeOfTheSameVersionWaitsADay() {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let version = CodexRuntime.version
    XCTAssertTrue(CodexRuntime.shouldRetryUpgrade(lastFailedVersion: nil, lastFailedAt: nil, now: now))
    XCTAssertFalse(CodexRuntime.shouldRetryUpgrade(lastFailedVersion: version, lastFailedAt: now.addingTimeInterval(-3600), now: now))
    XCTAssertTrue(CodexRuntime.shouldRetryUpgrade(lastFailedVersion: version, lastFailedAt: now.addingTimeInterval(-25 * 3600), now: now))
    XCTAssertTrue(CodexRuntime.shouldRetryUpgrade(lastFailedVersion: "0.1.0", lastFailedAt: now, now: now),
                  "A newer pin is tried at once")
    XCTAssertTrue(CodexRuntime.shouldRetryUpgrade(lastFailedVersion: version, lastFailedAt: now.addingTimeInterval(3600), now: now),
                  "A failure time in the future, after a clock change, doesn't block retries")
  }

  func testLaunchUpgradesQuietlyBacksOffAfterAFailureAndKeepsTheOlderCopy() async throws {
    let root = try temporaryDirectory()
    let installs = root.appending(path: "Codex Runtime")
    let older = try executable(at: installs.appending(path: "codex-0.100.0/bin/codex"))
    let stale = try stagingDirectory(in: installs, age: .day)
    let defaults = try temporaryDefaults()
    let upgrades = CallCounter()
    let now = Date()
    let failed = await CodexRuntime.maintainAtLaunch(in: installs, defaults: defaults, now: now) { directory in
      upgrades.record(directory.path)
      throw URLError(.notConnectedToInternet)
    }
    XCTAssertEqual(failed, .upgrade)
    XCTAssertEqual(upgrades.values, [installs.path], "The upgrade installs into the folder being maintained")
    XCTAssertTrue(CommandLineToolSearch.isExecutableFile(older.path), "The older copy keeps working")
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))

    _ = await CodexRuntime.maintainAtLaunch(in: installs, defaults: defaults, now: now.addingTimeInterval(3600)) { _ in
      upgrades.record("too soon")
    }
    XCTAssertEqual(upgrades.values.count, 1, "The same version isn't downloaded again within a day")

    let upgraded = await CodexRuntime.maintainAtLaunch(in: installs, defaults: defaults,
                                                       now: now.addingTimeInterval(25 * 3600)) { directory in
      upgrades.record("upgrade")
      let pinned = directory.appending(path: "codex-\(CodexRuntime.version)/bin/codex")
      try FileManager.default.createDirectory(at: pinned.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("#!/bin/sh\n".utf8).write(to: pinned)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pinned.path)
    }
    XCTAssertEqual(upgraded, .upgrade)
    XCTAssertEqual(upgrades.values.count, 2)
    XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("aiSpotlight.codexRuntime") },
                   "Success clears the failure record")
    XCTAssertTrue(CommandLineToolSearch.isExecutableFile(older.path), "Removed at the next launch, not now")
    let next = await CodexRuntime.maintainAtLaunch(in: installs, defaults: defaults) { _ in XCTFail("Already up to date") }
    XCTAssertEqual(next, .cleanUp(["codex-0.100.0"]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: older.path))
  }

  func testANewerBuiltInCodexFromAnotherBuildPreventsAQuietUpgrade() async throws {
    let root = try temporaryDirectory()
    let installs = root.appending(path: "Codex Runtime")
    _ = try executable(at: installs.appending(path: "codex-0.100.0/bin/codex"))
    let newer = try executable(at: installs.appending(path: "codex-9.0.0/bin/codex"))
    XCTAssertTrue(CodexRuntime.hasUsableNewerVersion(in: installs))
    let step = await CodexRuntime.maintainAtLaunch(in: installs, defaults: try temporaryDefaults()) { _ in
      XCTFail("Another build's newer copy is already in use")
    }
    XCTAssertEqual(step, .nothing)
    XCTAssertEqual(CodexRuntimeConfiguration.executableURL(environment: [:], home: root.path, runtimeDirectory: installs,
                                                           loginShellPath: nil), newer)
  }

  func testInstallRemovesOnlyStaleStagingBeforeDownloading() async throws {
    let root = try temporaryDirectory()
    let installs = root.appending(path: "Codex Runtime")
    let stale = try stagingDirectory(in: installs, age: .day)
    try Data(count: 1024).write(to: stale.appending(path: "codex.tar.gz"))
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 86_400)], ofItemAtPath: stale.path)
    let fresh = try stagingDirectory(in: installs)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OfflineProtocol.self]
    do {
      _ = try await CodexRuntime.install(into: installs, session: URLSession(configuration: configuration),
                                         activity: DownloadActivity { _ in {} }, progress: { _ in })
      XCTFail("The fixture session is offline")
    } catch {
      XCTAssertNil(error as? CodexRuntimeError, "A failed download is a download error, not an install error")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: installs.path).filter { $0.hasPrefix(".staging-") }
    XCTAssertEqual(leftovers, [fresh.lastPathComponent], "A failed install cleans up after itself; others' stay")
  }

  func testInstallKeepsACopyAnotherInstanceAlreadyMovedIntoPlace() async throws {
    let root = try temporaryDirectory()
    let installs = root.appending(path: "Codex Runtime")
    let existing = try executable(at: installs.appending(path: "codex-\(CodexRuntime.version)/bin/codex"),
                                  script: "#!/bin/sh\necho first\n")
    let archive = try makePackage(in: root.appending(path: "second"))
    let installed = try await CodexRuntime.install(archive: archive, staging: try stagingDirectory(in: installs), into: installs)
    XCTAssertEqual(installed.path, existing.path)
    XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "#!/bin/sh\necho first\n",
                   "The copy that is already in place, and maybe in use, is kept")
  }

  func testInstallRejectsUnsafeOrWrongPackages() async throws {
    let root = try temporaryDirectory()
    func attempt(_ name: String, _ expected: CodexRuntimeError, file: StaticString = #filePath, line: UInt = #line,
                 _ customize: (URL) throws -> Void) async throws {
      let folder = root.appending(path: name)
      let archive = try makePackage(in: folder, customize: customize)
      let installs = folder.appending(path: "installs")
      do {
        _ = try await CodexRuntime.install(archive: archive, staging: try stagingDirectory(in: installs), into: installs)
        XCTFail("Expected \(expected)", file: file, line: line)
      } catch {
        XCTAssertEqual(error as? CodexRuntimeError, expected, file: file, line: line)
      }
      XCTAssertNil(CodexRuntime.installedExecutable(in: installs), file: file, line: line)
    }
    try await attempt("extra", .invalidArchive) { package in
      try Data("x".utf8).write(to: package.appending(path: "README"))
    }
    try await attempt("link", .invalidArchive) { package in
      try FileManager.default.createSymbolicLink(atPath: package.appending(path: "codex-path/escape").path,
                                                 withDestinationPath: "/usr/bin")
    }
    try await attempt("dangling-link", .invalidArchive) { package in
      try FileManager.default.createSymbolicLink(atPath: package.appending(path: "codex-resources/escape").path,
                                                 withDestinationPath: "../../../outside-\(UUID().uuidString)")
    }
    try await attempt("version", .wrongPackage) { package in
      try self.writeManifest(in: package, version: "0.1.0", target: CodexRuntime.target)
    }
    try await attempt("target", .wrongPackage) { package in
      try self.writeManifest(in: package, version: CodexRuntime.version, target: "riscv-unknown")
    }
    try await attempt("manifest", .incomplete) { package in
      try FileManager.default.removeItem(at: package.appending(path: "codex-package.json"))
    }
    try await attempt("host", .incomplete) { package in
      try FileManager.default.removeItem(at: package.appending(path: "bin/codex-code-mode-host"))
    }
    try await attempt("smoke", .cannotStart) { package in
      _ = try self.executable(at: package.appending(path: "bin/codex"), script: "#!/bin/sh\necho 'codex-cli 0.1.0'\n")
    }
    try await attempt("crash", .cannotStart) { package in
      _ = try self.executable(at: package.appending(path: "bin/codex"), script: "#!/bin/sh\nexit 3\n")
    }
  }

  func testAbsoluteLinksAreRejectedEvenWhenTheyPointInsideTheStagedFolder() async throws {
    let root = try temporaryDirectory()
    let installs = root.appending(path: "installs")
    let staging = try stagingDirectory(in: installs)
    let inside = staging.appending(path: "unpacked/bin/codex").path
    let archive = try makePackage(in: root.appending(path: "absolute")) { package in
      try FileManager.default.createSymbolicLink(atPath: package.appending(path: "codex-path/abs").path,
                                                 withDestinationPath: inside)
    }
    do {
      _ = try await CodexRuntime.install(archive: archive, staging: staging, into: installs)
      XCTFail("An absolute link would dangle once the folder moves")
    } catch {
      XCTAssertEqual(error as? CodexRuntimeError, .invalidArchive)
    }
  }

  func testArchiveEntriesMustStayInsideTheKnownTopLevelFolders() {
    for allowed in ["bin/", "bin/codex", "codex-package.json", "codex-path/rg", "codex-resources/voice/manifest.json"] {
      XCTAssertTrue(CodexRuntime.isAllowedEntry(allowed), allowed)
    }
    for rejected in ["/bin/codex", "bin/../../evil", "../evil", "codex-resources/../../x", "README", "Codex.app/x", ""] {
      XCTAssertFalse(CodexRuntime.isAllowedEntry(rejected), rejected)
    }
  }

  // MARK: Helpers

  /// A package laid out like OpenAI's, with shell scripts for the binaries.
  private func makePackage(in folder: URL, customize: (URL) throws -> Void = { _ in }) throws -> URL {
    let package = folder.appending(path: "package")
    _ = try executable(at: package.appending(path: "bin/codex"),
                       script: "#!/bin/sh\n[ \"$1\" = --version ] && echo 'codex-cli \(CodexRuntime.version)'\n")
    _ = try executable(at: package.appending(path: "bin/codex-code-mode-host"))
    _ = try executable(at: package.appending(path: "codex-path/rg"))
    try FileManager.default.createDirectory(at: package.appending(path: "codex-resources/voice"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: package.appending(path: "codex-resources/voice/manifest.json"))
    try writeManifest(in: package, version: CodexRuntime.version, target: CodexRuntime.target)
    try customize(package)
    let archive = folder.appending(path: "codex.tar.gz")
    let entries = try FileManager.default.contentsOfDirectory(atPath: package.path).sorted()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-czf", archive.path, "-C", package.path] + entries
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return archive
  }

  private func writeManifest(in package: URL, version: String, target: String) throws {
    let json = #"{"layoutVersion":1,"version":"\#(version)","target":"\#(target)","variant":"codex","entrypoint":"bin/codex","resourcesDir":"codex-resources","pathDir":"codex-path"}"#
    try Data(json.utf8).write(to: package.appending(path: "codex-package.json"))
  }

  private enum StagingAge { case fresh, day }

  private func stagingDirectory(in installs: URL, age: StagingAge = .fresh) throws -> URL {
    let staging = installs.appending(path: ".staging-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    if age == .day {
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 86_400)],
                                            ofItemAtPath: staging.path)
    }
    return staging
  }

  private func temporaryDefaults() throws -> UserDefaults {
    let suite = "CloudToolInstallTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    return defaults
  }

  @discardableResult
  private func executable(at url: URL, script: String = "#!/bin/sh\nexit 0\n") throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private func noNetworkSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NoNetworkProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "CloudToolInstallTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory.resolvingSymlinksInPath()
  }
}

private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  var values: [String] { lock.withLock { recorded } }
  func record(_ value: String) { lock.withLock { recorded.append(value) } }
}

private final class OfflineProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  // Not a transient error, so the transfer fails at once instead of retrying.
  override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)) }
  override func stopLoading() {}
}

private final class NoNetworkProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    XCTFail("An installed runtime must not be downloaded again")
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }
  override func stopLoading() {}
}
