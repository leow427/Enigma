import Foundation

/// An update Sparkle has found, as the menu bar offers it.
struct PendingUpdate: Equatable {
  enum Stage: Equatable { case readyToInstall, available }

  /// The display version, e.g. "0.10.1".
  let version: String
  let stage: Stage

  var menuTitle: String {
    switch stage {
    case .readyToInstall: "Restart to Update to \(version)"
    case .available: "Update to \(version) Available…"
    }
  }
}

/// What `AppUpdater` drives. Only `SparkleUpdaterBackend` talks to Sparkle; tests use a fake.
@MainActor protocol AppUpdaterBackend: AnyObject {
  var automaticallyChecksForUpdates: Bool { get set }
  var automaticallyDownloadsUpdates: Bool { get set }
  var lastUpdateCheckDate: Date? { get }
  func start(reportingTo updater: AppUpdater)
  func checkForUpdates()
}

/// The update state the menu bar and Settings read and drive. It holds no Sparkle types.
@MainActor final class AppUpdater: ObservableObject {
  /// The app's updater. Sparkle starts only when the app calls `start()` after launch.
  static let shared = AppUpdater(backend: SparkleUpdaterBackend())

  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var pendingUpdate: PendingUpdate?
  @Published private(set) var lastUpdateCheckDate: Date?

  private let backend: any AppUpdaterBackend
  private var hasStarted = false
  private var installPendingUpdate: (@MainActor () -> Void)?

  init(backend: any AppUpdaterBackend) {
    self.backend = backend
  }

  var automaticallyChecksForUpdates: Bool {
    get { backend.automaticallyChecksForUpdates }
    set {
      objectWillChange.send()
      backend.automaticallyChecksForUpdates = newValue
    }
  }

  var automaticallyDownloadsUpdates: Bool {
    get { backend.automaticallyDownloadsUpdates }
    set {
      objectWillChange.send()
      backend.automaticallyDownloadsUpdates = newValue
    }
  }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    backend.start(reportingTo: self)
    lastUpdateCheckDate = backend.lastUpdateCheckDate
  }

  func checkForUpdates() {
    backend.checkForUpdates()
  }

  /// Installs a downloaded update now (once), or hands an available one back to Sparkle.
  func performPendingUpdate() {
    switch pendingUpdate?.stage {
    case .readyToInstall:
      let install = installPendingUpdate
      installPendingUpdate = nil
      pendingUpdate = nil
      install?()
    case .available:
      backend.checkForUpdates()
    case nil:
      break
    }
  }

  // MARK: Called by the backend

  func backendCanCheckChanged(_ canCheck: Bool) {
    canCheckForUpdates = canCheck
  }

  func backendUpdateReady(version: String, install: @escaping @MainActor () -> Void) {
    installPendingUpdate = install
    pendingUpdate = PendingUpdate(version: version, stage: .readyToInstall)
  }

  func backendUpdateAvailable(version: String) {
    // A downloaded update waiting to install is the stronger offer; keep it.
    guard pendingUpdate?.stage != .readyToInstall else { return }
    pendingUpdate = PendingUpdate(version: version, stage: .available)
  }

  /// Sparkle's update session ended: an available update goes, a downloaded one stays until it installs.
  func backendSessionEnded() {
    if pendingUpdate?.stage == .available {
      pendingUpdate = nil
    }
  }

  /// Sparkle changed a setting itself, e.g. from its update alert's checkbox; redraw what reads it.
  func backendSettingsChanged() {
    objectWillChange.send()
  }

  func backendCheckFinished() {
    lastUpdateCheckDate = backend.lastUpdateCheckDate
  }

  // MARK: Text

  static func versionText(info: [String: Any]) -> String {
    guard let short = info["CFBundleShortVersionString"] as? String,
          let build = info["CFBundleVersion"] as? String else { return "Unknown version" }
    return "\(short) (\(build))"
  }

  static func lastCheckedText(_ date: Date?, now: Date, locale: Locale) -> String {
    guard let date else { return "Not checked yet" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.locale = locale
    return "Last checked " + formatter.localizedString(for: date, relativeTo: now)
  }
}
