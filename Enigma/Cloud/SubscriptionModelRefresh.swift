import Foundation

/// Runs work shortly after launch and then once a day while Enigma runs. The due time is
/// checked against the wall clock every `checkInterval`, so a run that fell due while the
/// Mac slept happens once soon after wake (the sleep's continuous clock ends then), never
/// as a burst of missed runs: the next one is due a full `interval` after a run finishes,
/// or `retryInterval` after one that failed (for example offline at login).
struct DailySchedule: Sendable {
  var initialDelay: TimeInterval = 2 * 60
  var interval: TimeInterval = 24 * 60 * 60
  var retryInterval: TimeInterval = 60 * 60
  var checkInterval: TimeInterval = 10 * 60
  var now: @Sendable () -> Date = { Date() }
  var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

  /// Runs until the task is cancelled (or `sleep` throws). `work` returns false when it
  /// failed and should be retried after `retryInterval`.
  func run(_ work: @Sendable () async -> Bool) async {
    var due = now().addingTimeInterval(initialDelay)
    while !Task.isCancelled {
      let remaining = due.timeIntervalSince(now())
      // A clock set back by more than a day would otherwise delay the next run.
      if remaining > interval { due = now().addingTimeInterval(interval); continue }
      if remaining > 0 {
        do { try await sleep(min(remaining, checkInterval)) } catch { return }
        continue
      }
      let succeeded = await work()
      due = now().addingTimeInterval(succeeded ? interval : retryInterval)
    }
  }
}

/// The daily upkeep of the subscription routes (ChatGPT via Codex, Claude via Claude Code),
/// for the ones that are set up. Metadata only: `account/read`, `model/list` and
/// `claude auth status`, never a model turn, and never Enigma's Keychain items. A route
/// whose CLI isn't found runs nothing, and Codex isn't started unless a local sign says the
/// person may use ChatGPT. Failures are silent and keep the cached lists.
struct SubscriptionModelRefresh: Sendable {
  var codexIsInstalled: @Sendable () -> Bool
  /// A cheap local check (no process) that ChatGPT may be in use, before Codex is started.
  var mayUseChatGPT: @Sendable () async -> Bool
  /// Whether Codex is signed in with ChatGPT, the sign that the person uses the route.
  var codexIsSignedIn: @Sendable () async -> Bool
  /// Runs Codex runtime maintenance; true when it installed a new Codex.
  var maintainCodex: @Sendable (_ usesChatGPT: Bool) async -> Bool
  /// Lets running Codex app servers switch to a newly installed Codex once idle.
  var restartCodexWhenIdle: @Sendable () async -> Void
  /// Whether Codex requests now reach the Codex the lookup finds. False while a process
  /// from an older binary must stay because a reply is streaming.
  var codexIsCurrent: @Sendable () async -> Bool
  var claudeCodeIsInstalled: @Sendable () -> Bool
  /// A cheap local check that Claude Code may be in use, before its CLI is run.
  var mayUseClaudeCode: @Sendable () async -> Bool
  /// Force-refreshes one route's model list, keeping the cached list on failure. False
  /// when it failed and is worth retrying soon.
  var refreshModels: @Sendable (CloudProviderID) async -> Bool

  /// False when a refresh failed, so the schedule retries sooner.
  func run() async -> Bool {
    var succeeded = true
    if codexIsInstalled(), await mayUseChatGPT() {
      let usesChatGPT = await codexIsSignedIn()
      // Maintenance first, so the list comes from the newer Codex when one was installed.
      if await maintainCodex(usesChatGPT) { await restartCodexWhenIdle() }
      if usesChatGPT {
        // An old process would list (and cache for a day) the old binary's models; retry
        // in an hour instead, once the reply has finished and the new Codex runs.
        if !(await codexIsCurrent()) { succeeded = false }
        else if !(await refreshModels(.chatGPT)) { succeeded = false }
      }
    }
    // The catalog checks Claude Code's sign-in before listing its models.
    if claudeCodeIsInstalled(), await mayUseClaudeCode(), !(await refreshModels(.claudeCode)) { succeeded = false }
    return succeeded
  }

  @MainActor
  static func live(settings: CloudSettingsModel = .shared) -> SubscriptionModelRefresh {
    SubscriptionModelRefresh(
      codexIsInstalled: { CodexRuntimeConfiguration.executableURL() != nil },
      mayUseChatGPT: { await settings.mayUseChatGPT() },
      codexIsSignedIn: { (try? await CodexSubscriptionClient.live.account()) != nil },
      maintainCodex: { usesChatGPT in
        await CodexRuntime.maintainDaily(usesChatGPT: usesChatGPT,
                                         systemExecutable: CodexRuntime.systemExecutable()).installed
      },
      restartCodexWhenIdle: {
        await CodexAppServer.shared.restartWhenIdle()
        await CodexAppServer.fileMode.restartWhenIdle()
      },
      // The list is read through the shared server; File Mode lists models on its own.
      codexIsCurrent: { await CodexAppServer.shared.usesCurrentExecutable() },
      claudeCodeIsInstalled: { ClaudeCodeSubscriptionClient.live.isInstalled },
      mayUseClaudeCode: { await settings.mayUseClaudeCode() },
      refreshModels: { provider in await settings.refreshModelsQuietly(for: provider) }
    )
  }
}
