import AppKit
import SwiftUI

// The subscription connections, shared by setup and Settings.

/// ChatGPT through the Codex sign-in on this Mac. When no Codex is found, Sign in
/// first downloads Enigma's pinned copy from OpenAI.
struct ChatGPTConnectionControls: View {
  @ObservedObject var settings: CloudSettingsModel

  static let downloadNote = "Signing in the first time downloads Codex from OpenAI · \(CodexRuntime.downloadSize)"
  /// The longer explanation, behind the row's ⓘ.
  static let info = "Uses your ChatGPT plan's Codex allowance, not API billing. Plan limits and model availability apply. This is a Codex-powered chat, not the ChatGPT website. Codex securely stores your sign-in on this Mac."
  static let downloadCheckText = "Not signed in · Sign in downloads Codex from OpenAI (\(CodexRuntime.downloadSize))"

  static func status(isConnected: Bool, isSelected: Bool = false, isSigningIn: Bool, isDownloading: Bool = false,
                     isInstalling: Bool = false) -> (EnigmaStatusLine.Status, String) {
    if isConnected { return (.on, isSelected ? "connected · selected for cloud" : "connected") }
    if isInstalling { return (.busy, "installing Codex") }
    if isDownloading { return (.busy, "downloading Codex") }
    if isSigningIn { return (.busy, "signing in") }
    return (.off, "not connected")
  }

  var body: some View {
    // The download reports 100% before the package is checked and installed.
    let isInstalling = settings.isDownloadingCodex && settings.codexDownloadProgress >= 1
    let status = Self.status(isConnected: settings.chatGPTAccount != nil,
                             isSelected: settings.preferredProvider == .chatGPT, isSigningIn: settings.isSigningIn,
                             isDownloading: settings.isDownloadingCodex, isInstalling: isInstalling)
    VStack(alignment: .leading, spacing: 0) {
      EnigmaRow("ChatGPT", subtitle: "Through your ChatGPT plan, using Codex", info: Self.info) {
        HStack(spacing: 12) {
          EnigmaStatusLine(status.0, status.1)
          action
        }
      }
      EnigmaConnectionDetails {
        if let account = settings.chatGPTAccount {
          EnigmaConnectionNote(account.email ?? "Signed in with ChatGPT")
        } else if isInstalling {
          EnigmaConnectionNote("Installing Codex… Sign-in continues in your browser when it finishes.")
        } else if settings.isDownloadingCodex {
          EnigmaProgressBar(fraction: settings.codexDownloadProgress, width: nil, label: "Codex download progress")
          EnigmaConnectionNote("Downloading Codex from OpenAI. Sign-in continues in your browser when it finishes.")
        } else if settings.isSigningIn {
          EnigmaConnectionNote("Finish signing in in your browser…")
        } else if !settings.isCodexAvailable {
          EnigmaConnectionNote(Self.downloadNote)
        }
        HStack(spacing: 2) {
          Button(settings.isCheckingChatGPT ? "Checking…" : "Check sign-in status") {
            Task { await settings.checkChatGPTSignIn() }
          }
          .enigmaButtonStyle(.text)
          .disabled(settings.isSigningIn || settings.isCheckingChatGPT)
          if settings.chatGPTAccount != nil {
            Button("Sign out") {
              Task { await settings.signOutOfChatGPT() }
            }
            .enigmaButtonStyle(.text)
            .accessibilityLabel("Sign out of ChatGPT")
          }
        }
        .padding(.leading, -8)
        if let check = settings.chatGPTCheck {
          SignInCheckResult(check, product: "Codex", signInHint: "Choose Sign in to connect your ChatGPT plan.")
        } else if let accountError = settings.accountError {
          EnigmaStatusLine(.problem, accountError)
        }
      }
    }
    .task { await settings.refreshChatGPTAccount() }
    .onChange(of: settings.chatGPTCheck) { _, check in
      if let check { SignInCheckResult.announce(check, product: "Codex") }
    }
  }

  @ViewBuilder private var action: some View {
    if settings.chatGPTAccount != nil {
      Button("Use ChatGPT") {
        settings.preferredProvider = .chatGPT
        Task { await settings.discoverModels() }
      }
      .enigmaButtonStyle(.secondary)
    } else if settings.isSigningIn {
      Button("Cancel") { settings.cancelSignIn() }
        .enigmaButtonStyle(.secondary)
        .accessibilityLabel(settings.isDownloadingCodex ? "Cancel Codex download and sign-in" : "Cancel ChatGPT sign-in")
    } else {
      Button("Sign in") {
        settings.signInWithChatGPT { url in
          await MainActor.run { NSWorkspace.shared.open(url) }
        }
      }
      .enigmaButtonStyle(.secondary)
      .disabled(settings.isCheckingChatGPT)
      .accessibilityLabel(settings.isCodexAvailable ? "Sign in with ChatGPT"
        : "Sign in with ChatGPT, downloading Codex from OpenAI first (\(CodexRuntime.downloadSize))")
    }
  }
}

/// Claude through the Claude Code sign-in on this Mac, which Claude Code owns.
/// Claude Code is never bundled: when it is missing, Install runs Anthropic's
/// official installer in Terminal.
struct ClaudeCodeConnectionControls: View {
  @ObservedObject var settings: CloudSettingsModel
  /// Settings shows the API-key note; welcome setup, short on room, leaves it out.
  var showsAPIKeyNote = true

  static let installSteps = [
    "1. Open Terminal (Applications → Utilities → Terminal).",
    "2. Paste the command below and press Return.",
    "3. Come back and choose Check again, then Sign in.",
  ]
  /// The longer explanation, behind the row's ⓘ.
  static let info = "Uses your Claude Pro or Max plan through Claude Code, not API billing. Plan usage limits apply. Claude Code tools, MCP servers, hooks, plugins, and CLAUDE.md files are turned off, and sessions are not saved. Enigma shares the Claude Code sign-in on this Mac. To disconnect, choose another provider, or run claude auth logout in Terminal to sign out everywhere."
  static let apiKeyNote = "Anthropic's supported way to use Claude in other apps is an Anthropic API key: add one under API keys below."

  /// Once the installed Claude Code is found, the wait is for sign-in.
  static func status(isConnected: Bool, isSelected: Bool, isWaiting: Bool, isInstalling: Bool = false,
                     isFound: Bool = false) -> (EnigmaStatusLine.Status, String) {
    if isConnected { return (.on, isSelected ? "connected · selected for cloud" : "connected") }
    if isWaiting { return (.busy, isInstalling && !isFound ? "installing" : "signing in") }
    return (.off, "not connected")
  }

  var body: some View {
    let isSelected = settings.preferredProvider == .claudeCode
    let status = Self.status(isConnected: settings.claudeCodeAccount != nil, isSelected: isSelected,
                             isWaiting: settings.isWaitingForClaudeCodeSignIn,
                             isInstalling: settings.isInstallingClaudeCode, isFound: settings.isClaudeCodeAvailable)
    let isMissing = !settings.isClaudeCodeAvailable && settings.claudeCodeAccount == nil
    VStack(alignment: .leading, spacing: 0) {
      EnigmaRow("Claude", subtitle: "Through your Claude plan, using Claude Code", info: Self.info) {
        HStack(spacing: 12) {
          EnigmaStatusLine(status.0, status.1)
          action(isSelected: isSelected)
        }
      }
      EnigmaConnectionDetails {
        if let account = settings.claudeCodeAccount {
          EnigmaConnectionNote(account.email ?? "Signed in to Claude Code")
          if let plan = account.plan, !plan.isEmpty {
            EnigmaConnectionNote("Claude \(plan.capitalized) plan")
          }
        } else if settings.isInstallingClaudeCode && !settings.isClaudeCodeAvailable {
          EnigmaConnectionNote("Finish installing in Terminal, then sign in from your browser…")
        } else if settings.isWaitingForClaudeCodeSignIn {
          EnigmaConnectionNote("Finish signing in from Terminal and your browser…")
        }
        if isMissing && !settings.isWaitingForClaudeCodeSignIn {
          EnigmaConnectionNote("Install Claude Code runs Anthropic's installer in Terminal, then signs in.")
          if showsAPIKeyNote { EnigmaConnectionNote(Self.apiKeyNote).enigmaTestMarker("Anthropic API key note") }
          EnigmaDisclosure("Terminal steps") {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(Self.installSteps, id: \.self) { EnigmaConnectionNote($0) }
              InstallCommandLine(command: ClaudeCodeRuntime.installCommand)
            }
          }
        }
        HStack(spacing: 2) {
          Button(settings.isCheckingClaudeCode ? "Checking…" : isMissing ? "Check again" : "Check sign-in status") {
            Task { await settings.checkClaudeCodeSignIn() }
          }
          .enigmaButtonStyle(.text)
          .disabled(settings.isWaitingForClaudeCodeSignIn || settings.isCheckingClaudeCode)
          .accessibilityLabel(isMissing ? "Check again for Claude Code" : "Check sign-in status")
          if isMissing {
            Button("Choose Claude Code…", action: chooseClaudeCode)
              .enigmaButtonStyle(.text)
              .disabled(settings.isWaitingForClaudeCodeSignIn || settings.isCheckingClaudeCode)
              .accessibilityLabel("Choose the Claude Code program")
          }
        }
        .padding(.leading, -8)
        if let check = settings.claudeCodeCheck {
          SignInCheckResult(check, product: "Claude Code",
                            signInHint: "Choose Sign in to connect your Claude plan.",
                            lookedIn: settings.claudeCodeLookedIn,
                            installHint: "Choose Install Claude Code, or Choose Claude Code… if it is installed somewhere else.")
        } else if let error = settings.claudeCodeError {
          EnigmaStatusLine(.problem, error)
        }
      }
    }
    .task { await settings.refreshClaudeCodeAccount() }
    .onChange(of: settings.claudeCodeCheck) { _, check in
      if let check {
        SignInCheckResult.announce(check, product: "Claude Code", lookedIn: settings.claudeCodeLookedIn)
      }
    }
  }

  @ViewBuilder private func action(isSelected: Bool) -> some View {
    if settings.claudeCodeAccount != nil {
      Button("Use Claude") {
        settings.preferredProvider = .claudeCode
        Task { await settings.discoverModels() }
      }
      .enigmaButtonStyle(.secondary)
      .disabled(isSelected)
    } else if settings.isWaitingForClaudeCodeSignIn {
      Button("Cancel") { settings.cancelClaudeCodeSignIn() }
        .enigmaButtonStyle(.secondary)
        .accessibilityLabel(settings.isInstallingClaudeCode ? "Cancel Claude Code install" : "Cancel Claude Code sign-in")
    } else if !settings.isClaudeCodeAvailable {
      Button("Install Claude Code") {
        settings.installClaudeCode { NSWorkspace.shared.open($0) }
      }
      .enigmaButtonStyle(.secondary)
      .disabled(settings.isCheckingClaudeCode)
      .accessibilityLabel("Install Claude Code in Terminal, then sign in")
    } else {
      Button("Sign in") {
        settings.signInToClaudeCode { NSWorkspace.shared.open($0) }
      }
      .enigmaButtonStyle(.secondary)
      .disabled(settings.isCheckingClaudeCode)
      .accessibilityLabel("Sign in to Claude Code")
    }
  }

  private func chooseClaudeCode() {
    let panel = NSOpenPanel()
    panel.title = "Choose Claude Code"
    panel.message = "Choose the claude program from your Claude Code install."
    panel.prompt = "Choose"
    // Keep the path as picked: an npm `bin/claude` link must not become its `cli.js`.
    panel.resolvesAliases = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.treatsFilePackagesAsDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await settings.chooseClaudeCode(at: url) }
  }
}

/// A command to paste into Terminal, with Copy.
struct InstallCommandLine: View {
  let command: String
  @State private var didCopy = false
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    HStack(spacing: 8) {
      Text(command)
        .font(EnigmaTypography.mono(12))
        .foregroundStyle(palette.accentText.color)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Install command: \(command)")
      Button(didCopy ? "Copied" : "Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        didCopy = true
        AccessibilityNotification.Announcement("Install command copied").post()
        Task {
          try? await Task.sleep(for: .seconds(2))
          didCopy = false
        }
      }
      .enigmaButtonStyle(.text)
      .accessibilityLabel(didCopy ? "Install command copied" : "Copy the install command")
    }
  }
}

/// What "Check sign-in status" found, with the next step.
struct SignInCheckResult: View {
  let check: CloudSettingsModel.SignInCheck
  let product: String
  let signInHint: String
  let lookedIn: String
  let installHint: String

  init(_ check: CloudSettingsModel.SignInCheck, product: String, signInHint: String,
       lookedIn: String = "", installHint: String = "") {
    self.check = check
    self.product = product
    self.signInHint = signInHint
    self.lookedIn = lookedIn
    self.installHint = installHint
  }

  static func message(_ check: CloudSettingsModel.SignInCheck, product: String,
                      lookedIn: String = "") -> (EnigmaStatusLine.Status, String) {
    switch check {
    case .signedIn(let who): (.on, who.map { "Signed in as \($0)" } ?? "Signed in")
    case .notSignedIn: (.off, "Not signed in")
    case .notSignedInNeedsCodexDownload: (.off, ChatGPTConnectionControls.downloadCheckText)
    case .notInstalled:
      (.problem, "\(product) not found on this Mac" + (lookedIn.isEmpty ? "" : " (looked in \(lookedIn))"))
    case .failed(let message): (.problem, message)
    }
  }

  static func announce(_ check: CloudSettingsModel.SignInCheck, product: String, lookedIn: String = "") {
    AccessibilityNotification.Announcement(message(check, product: product, lookedIn: lookedIn).1).post()
  }

  var body: some View {
    let line = Self.message(check, product: product, lookedIn: lookedIn)
    VStack(alignment: .leading, spacing: 4) {
      EnigmaStatusLine(line.0, line.1)
      switch check {
      case .signedIn: EmptyView()
      case .notInstalled: if !installHint.isEmpty { EnigmaConnectionNote(installHint) }
      case .notSignedIn: EnigmaConnectionNote(signInHint)
      case .notSignedInNeedsCodexDownload: EmptyView()
      case .failed: EnigmaConnectionNote("Try again in a moment. If it keeps failing, update \(product) and restart Enigma.")
      }
    }
  }
}

/// The notes and actions under a connection's row.
struct EnigmaConnectionDetails<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) { content() }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.bottom, 12)
  }
}

/// Supporting text under a connection, in `textSecondary` because people read it.
struct EnigmaConnectionNote: View {
  let text: String
  @Environment(\.enigmaPalette) private var palette

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(EnigmaTypography.ui(12))
      .foregroundStyle(palette.textSecondary.color)
      .fixedSize(horizontal: false, vertical: true)
  }
}
