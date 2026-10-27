import Foundation
import SwiftUI

/// One version's release notes, from `docs/release-notes/<version>.md`.
struct ReleaseNote: Equatable, Identifiable {
  let version: String
  let markdown: String

  var id: String { version }

  /// The notes bundled with the app, in its `release-notes` folder.
  static var bundledDirectory: URL? { Bundle.main.url(forResource: "release-notes", withExtension: nil) }

  /// Every `X.Y.Z.md` in `directory`, in no set order; other files, like a
  /// draft, are left out. A missing or unreadable folder or file gives fewer
  /// notes, never an error.
  static func load(from directory: URL?) -> [ReleaseNote] {
    guard let directory,
          let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return files.filter { $0.pathExtension == "md" }.compactMap { file in
      let version = file.deletingPathExtension().lastPathComponent
      guard version.wholeMatch(of: /\d+\.\d+\.\d+/) != nil,
            let markdown = try? String(contentsOf: file, encoding: .utf8) else { return nil }
      return ReleaseNote(version: version, markdown: markdown)
    }
  }

  /// Compares `X.Y.Z` versions, and build numbers, field by field.
  static func isNewer(_ version: String, than other: String) -> Bool {
    version.compare(other, options: .numeric) == .orderedDescending
  }
}

/// After Enigma launches on a newer build than last time, a What's new?
/// button offers the release notes of every version since the last one seen.
/// Opening them retires the button for good; until then it stays, and the
/// next update adds its notes. A fresh install has nothing to show. An
/// existing user from before this feature, who has no saved build, is known
/// by a finished welcome setup and sees the running version's notes.
@MainActor
final class WhatsNew: ObservableObject {
  /// Inert in the test host, which shares the installed app's defaults.
  static let shared = TestHost.isActive ? WhatsNew(version: "", build: "", notes: [], defaults: nil) : WhatsNew()
  static let lastSeenBuildKey = "whatsNew.lastSeenBuild.v1"
  static let lastSeenVersionKey = "whatsNew.lastSeenVersion.v1"

  /// The running version, like `0.12.0`.
  let version: String
  /// What the sheet shows, newest first. It stays after the button goes.
  let notes: [ReleaseNote]
  @Published private(set) var showsButton: Bool

  private let build: String
  /// Nil remembers nothing.
  private let defaults: UserDefaults?

  convenience init() {
    let info = Bundle.main.infoDictionary ?? [:]
    self.init(version: info["CFBundleShortVersionString"] as? String ?? "",
              build: info["CFBundleVersion"] as? String ?? "",
              notes: ReleaseNote.load(from: ReleaseNote.bundledDirectory))
  }

  /// `notes` are every bundled note; only those since the last version seen
  /// are kept.
  init(version: String, build: String, notes: [ReleaseNote], defaults: UserDefaults? = .standard) {
    self.version = version
    self.build = build
    self.defaults = defaults
    let lastBuild = defaults?.string(forKey: Self.lastSeenBuildKey)
    let isNewBuild = lastBuild.map { ReleaseNote.isNewer(build, than: $0) } ?? true
    let isExistingUser = lastBuild != nil || defaults?.bool(forKey: WelcomeSetup.completedKey) == true
    // Without a saved version, only the running version's notes are known to be new.
    let lastVersion = lastBuild == nil ? nil : defaults?.string(forKey: Self.lastSeenVersionKey)
    self.notes = isExistingUser && isNewBuild ? notes.filter { note in
      !ReleaseNote.isNewer(note.version, than: version)
        && (lastVersion.map { ReleaseNote.isNewer(note.version, than: $0) } ?? (note.version == version))
    }.sorted { ReleaseNote.isNewer($0.version, than: $1.version) } : []
    showsButton = !self.notes.isEmpty
    if !showsButton {
      // A fresh install, or an update with nothing to read, is already seen.
      if isNewBuild { remember(build: build, version: version) }
    } else if lastBuild == nil, let newest = self.notes.first {
      // Keep the place from before these notes, so an unopened button carries
      // them into the next update. Build 0 is older than every real build.
      let before = notes.map(\.version).filter { ReleaseNote.isNewer(newest.version, than: $0) }
        .max { ReleaseNote.isNewer($1, than: $0) }
      remember(build: "0", version: before ?? "0")
    }
  }

  /// The newest version with notes to show, normally the running one.
  var newestVersion: String { notes.first?.version ?? version }

  /// "What's new in Enigma 0.12.0", for VoiceOver.
  var accessibilityLabel: String { "What's new in Enigma \(newestVersion)" }

  /// The notes are opening: retire the button for this version.
  func open() {
    showsButton = false
    remember(build: build, version: version)
  }

  private func remember(build: String, version: String) {
    defaults?.set(build, forKey: Self.lastSeenBuildKey)
    defaults?.set(version, forKey: Self.lastSeenVersionKey)
  }
}

/// The release notes since the last version seen, newest first.
struct WhatsNewView: View {
  /// The newest version shown.
  let version: String
  let notes: [ReleaseNote]
  @Environment(\.dismiss) private var dismiss
  @Environment(\.enigmaPalette) private var palette

  static let size = CGSize(width: 560, height: 560)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("What's new")
        .font(EnigmaTypography.ui(20, weight: .semibold))
        .tracking(-0.3)
        .foregroundStyle(palette.textPrimary.color)
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 28)
        .padding(.top, 24)
      Text(notes.count > 1 ? "Everything added since you last read these notes." : "Added in Enigma \(version).")
        .font(EnigmaTypography.ui(13))
        .foregroundStyle(palette.textSecondary.color)
        .padding(.horizontal, 28)
        .padding(.top, 4)
        .padding(.bottom, 12)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
            if index > 0 { EnigmaHairline() }
            ChatMarkdownView(content: note.markdown)
              .enigmaTestMarker("Release notes \(note.version)")
          }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
      }
      .scrollBounceBehavior(.basedOnSize)
      EnigmaHairline()
      HStack {
        Spacer()
        Button { dismiss() } label: {
          HStack(spacing: 10) {
            Text("Done")
            EnigmaKeycap("↵")
          }
        }
        .enigmaButtonStyle(.primary)
        .keyboardShortcut(.defaultAction)
        .enigmaTestMarker("Done")
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 14)
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .background(palette.background.color)
    .tint(palette.accent.color)
    .onExitCommand { dismiss() }
  }
}
