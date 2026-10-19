import Foundation
import Sparkle

/// The only place Enigma talks to Sparkle. It reports what Sparkle does to `AppUpdater`.
///
/// Creating it does nothing; the Sparkle controller is made on first use and started only by
/// `start(reportingTo:)`, which the app calls after launch and hosted tests never do.
@MainActor final class SparkleUpdaterBackend: NSObject, AppUpdaterBackend {
  private weak var updater: AppUpdater?
  private var canCheckObservation: NSKeyValueObservation?

  private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: false,
    updaterDelegate: self,
    userDriverDelegate: self
  )

  var automaticallyChecksForUpdates: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }

  var automaticallyDownloadsUpdates: Bool {
    get { controller.updater.automaticallyDownloadsUpdates }
    set { controller.updater.automaticallyDownloadsUpdates = newValue }
  }

  var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

  func start(reportingTo updater: AppUpdater) {
    self.updater = updater
    controller.startUpdater()
    canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
      [weak self] sparkleUpdater, _ in
      // Sparkle changes this property on the main thread.
      MainActor.assumeIsolated { self?.updater?.backendCanCheckChanged(sparkleUpdater.canCheckForUpdates) }
    }
  }

  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }

  /// A run from Xcode must never download an update and replace itself; a check the user starts is fine.
  nonisolated static func permitsCheck(isBackground: Bool, isDebugBuild: Bool) -> Bool {
    !(isBackground && isDebugBuild)
  }

  private static var isDebugBuild: Bool {
    #if DEBUG
    true
    #else
    false
    #endif
  }
}

extension SparkleUpdaterBackend: SPUUpdaterDelegate {
  func updater(
    _ updater: SPUUpdater,
    willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    // Sparkle calls this, and expects the block to run, on the main thread.
    nonisolated(unsafe) let install = immediateInstallHandler
    self.updater?.backendUpdateReady(version: item.displayVersionString) { install() }
    return true
  }

  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    guard Self.permitsCheck(isBackground: updateCheck == .updatesInBackground, isDebugBuild: Self.isDebugBuild) else {
      throw NSError(domain: "Enigma.Updates", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Debug builds do not check for updates in the background.",
      ])
    }
  }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
    self.updater?.backendCheckFinished()
  }
}

extension SparkleUpdaterBackend: @preconcurrency SPUStandardUserDriverDelegate {
  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    immediateFocus
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    // Sparkle left a scheduled update to us: offer it in the menu instead of an alert.
    guard !handleShowingUpdate, state.stage != .installing else { return }
    updater?.backendUpdateAvailable(version: update.displayVersionString)
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    updater?.backendSessionEnded()
  }

  func standardUserDriverWillFinishUpdateSession() {
    updater?.backendSessionEnded()
  }
}
