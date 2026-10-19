import AppKit
import Darwin

/// At launch, offers to move a translocated or misplaced Enigma into Applications and
/// reopen it there, so Sparkle can update it. The decision and wording live in
/// `InstallLocation`; the file work in `ApplicationMover`.
@MainActor enum MoveToApplicationsPrompt {
  /// Returns true when Enigma is relaunching and launch should stop.
  static func runIfNeeded() -> Bool {
    let bundleURL = Bundle.main.bundleURL
    let translocation = translocationStatus(of: bundleURL)
    let defaults = UserDefaults.standard
    #if DEBUG
    let isDebugBuild = true
    #else
    let isDebugBuild = false
    #endif
    let context = InstallLocationContext(
      bundleURL: bundleURL,
      isTranslocated: translocation.isTranslocated,
      originalURL: translocation.original,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      systemApplicationsIsWritable: FileManager.default.isWritableFile(
        atPath: InstallLocation.systemApplicationsFolder.path),
      dontAskAgain: defaults.bool(forKey: InstallLocation.dontAskAgainKey),
      isDebugBuild: isDebugBuild
    )

    let decision = InstallLocation.decide(context)
    let offerText: InstallLocationAlertText
    switch decision {
    case .stay:
      return false
    case .reopenInPlace:
      offerText = .reopenOffer
    case .move(_, let inHomeFolder):
      offerText = .moveOffer(inHomeFolder: inHomeFolder)
    }

    // Enigma is an accessory app, so bring it forward before showing a modal alert.
    NSApp.activate()
    let offer = makeAlert(offerText, style: .informational)
    offer.showsSuppressionButton = true
    offer.suppressionButton?.title = "Don't ask again"
    let response = offer.runModal()
    // Honour the checkbox whichever button was chosen.
    if offer.suppressionButton?.state == .on {
      defaults.set(true, forKey: InstallLocation.dontAskAgainKey)
    }
    guard response == .alertFirstButtonReturn else { return false }

    let mover = ApplicationMover()
    let relaunchTarget: URL
    var originalToDiscard: (original: URL?, destination: URL)?
    do {
      switch decision {
      case .stay:
        return false
      case .reopenInPlace(let original):
        try mover.removeQuarantine(from: original)
        relaunchTarget = original
      case .move(let destination, _):
        var replacingExisting = false
        if mover.itemExists(at: destination) {
          guard confirmReplacing(at: destination, mover: mover) else { return false }
          replacingExisting = true
        }
        try mover.install(from: bundleURL, to: destination, replacingExisting: replacingExisting)
        originalToDiscard = (translocation.isTranslocated ? translocation.original : bundleURL, destination)
        relaunchTarget = destination
      }
    } catch {
      NSLog("Unable to move Enigma into Applications: %@", String(describing: error))
      showFailure(reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
      return false
    }

    // Trash the download only once the relaunch helper is running, so a failed
    // relaunch never leaves Enigma running from a bundle in the Trash.
    guard startRelaunchHelper(for: relaunchTarget) else { return false }
    if let originalToDiscard {
      mover.discardOriginal(originalToDiscard.original, destination: originalToDiscard.destination)
    }
    NSApp.terminate(nil)
    return true
  }

  private static var runningVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

  private static func confirmReplacing(at destination: URL, mover: ApplicationMover) -> Bool {
    let existing = mover.existingVersion(at: destination)
    let age = InstallLocation.age(ofExisting: existing, comparedTo: runningVersion)
    let text = InstallLocationAlertText.replace(
      existingVersion: existing, runningVersion: runningVersion, age: age)
    return makeAlert(text, style: age == .newer ? .warning : .informational).runModal()
      == .alertFirstButtonReturn
  }

  private static func showFailure(reason: String) {
    makeAlert(.failure(reason: reason), style: .warning).runModal()
  }

  private static func makeAlert(_ text: InstallLocationAlertText, style: NSAlert.Style) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = text.title
    alert.informativeText = text.message
    alert.addButton(withTitle: text.confirmButton)
    if !text.cancelButton.isEmpty {
      alert.addButton(withTitle: text.cancelButton).keyEquivalent = "\u{1b}"
    }
    return alert
  }

  // MARK: Relaunch

  /// Starts a helper that opens `app` once this process has exited, so the two copies
  /// never hold the global shortcuts at once. Returns false if the helper could not start.
  private static func startRelaunchHelper(for app: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
      "sh",
      "\(getpid())",
      app.path,
    ]
    do {
      try process.run()
    } catch {
      NSLog("Unable to start the Enigma relaunch helper: %@", String(describing: error))
      showFailure(reason: error.localizedDescription)
      return false
    }
    return true
  }

  // MARK: Translocation

  private typealias IsTranslocatedURL = @convention(c) (
    CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?
  ) -> UInt8
  private typealias CreateOriginalPathForURL = @convention(c) (
    CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
  ) -> Unmanaged<CFURL>?

  /// Asks Security.framework (SPI, as Sparkle and LetsMove do) whether `url` is an App
  /// Translocation copy and where the original is. Falls back to the path when the SPI
  /// is unavailable, with the original unknown.
  private static func translocationStatus(of url: URL) -> (isTranslocated: Bool, original: URL?) {
    let fallback = (isTranslocated: url.pathComponents.contains("AppTranslocation"), original: URL?.none)
    guard
      let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
      let isTranslocatedSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
      let createOriginalSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
    else { return fallback }
    let isTranslocatedURL = unsafeBitCast(isTranslocatedSymbol, to: IsTranslocatedURL.self)
    let createOriginalPath = unsafeBitCast(createOriginalSymbol, to: CreateOriginalPathForURL.self)

    var isTranslocated = false
    var error: Unmanaged<CFError>?
    let succeeded = isTranslocatedURL(url as CFURL, &isTranslocated, &error) != 0
    error?.release()
    guard succeeded else { return fallback }
    guard isTranslocated else { return (false, nil) }

    var originalError: Unmanaged<CFError>?
    let original = createOriginalPath(url as CFURL, &originalError)?.takeRetainedValue()
    originalError?.release()
    return (true, original.map { $0 as URL })
  }
}
