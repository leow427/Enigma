import AppKit
import SwiftUI

// The subscription connections, shared by setup and Settings.

/// ChatGPT through the Codex sign-in on this Mac.
struct ChatGPTConnectionControls: View {
  @ObservedObject var settings: CloudSettingsModel

  static func status(isConnected: Bool, isSigningIn: Bool) -> (EnigmaStatusLine.Status, String) {
    if isConnected { return (.on, "connected") }
    if isSigningIn { return (.busy, "signing in") }
    return (.off, "not connected")
  }

  var body: some View {
    let status = Self.status(isConnected: settings.chatGPTAccount != nil, isSigningIn: settings.isSigningIn)
    VStack(alignment: .leading, spacing: 0) {
      EnigmaRow("ChatGPT", subtitle: "Through your ChatGPT plan, using Codex") {
        HStack(spacing: 12) {
          EnigmaStatusLine(status.0, status.1)
          action
        }
      }
      EnigmaConnectionDetails {
        if let account = settings.chatGPTAccount {
          EnigmaConnectionNote(account.email ?? "Signed in with ChatGPT")
        } else if settings.isSigningIn {
          EnigmaConnectionNote("Finish signing in in your browser…")
        }
        EnigmaConnectionNote("Uses your ChatGPT plan's Codex allowance, not API billing. Plan limits and model availability apply. This is a Codex-powered chat, not the ChatGPT website.")
        if !settings.isCodexAvailable {
          EnigmaConnectionNote("The Codex CLI is required on this Mac. Install or update it, then check again.")
        }
        EnigmaConnectionNote("Codex securely stores your sign-in on this Mac.")
        HStack(spacing: 2) {
          Button(settings.isCheckingChatGPT ? "Checking…" : "Check sign-in status") {
            Task { await settings.checkChatGPTSignIn() }
          }
          .enigmaButtonStyle(.text)
          .disabled(settings.isSigningIn || settings.isCheckingChatGPT)
          if !settings.isCodexAvailable {
            Link("Codex installation instructions", destination: URL(string: "https://learn.chatgpt.com/docs/cli")!)
              .enigmaButtonStyle(.text)
          }
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
          SignInCheckResult(check, product: "Codex",
                            signInHint: "Choose Sign in to connect your ChatGPT plan.")
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
        .accessibilityLabel("Cancel ChatGPT sign-in")
    } else {
      Button("Sign in") {
        settings.signInWithChatGPT { url in
          await MainActor.run { NSWorkspace.shared.open(url) }
        }
      }
      .enigmaButtonStyle(.secondary)
      .disabled(!settings.isCodexAvailable || settings.isCheckingChatGPT)
      .accessibilityLabel("Sign in with ChatGPT")
    }
  }
}

/// Claude through the Claude Code sign-in on this Mac, which Claude Code owns.
struct ClaudeCodeConnectionControls: View {
  @ObservedObject var settings: CloudSettingsModel

  static func status(isConnected: Bool, isSelected: Bool, isWaiting: Bool) -> (EnigmaStatusLine.Status, String) {
    if isConnected { return (.on, isSelected ? "connected · selected for cloud" : "connected") }
    if isWaiting { return (.busy, "signing in") }
    return (.off, "not connected")
  }

  var body: some View {
    let isSelected = settings.preferredProvider == .claudeCode
    let status = Self.status(isConnected: settings.claudeCodeAccount != nil, isSelected: isSelected,
                             isWaiting: settings.isWaitingForClaudeCodeSignIn)
    VStack(alignment: .leading, spacing: 0) {
      EnigmaRow("Claude", subtitle: "Through your Claude plan, using Claude Code") {
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
        } else if settings.isWaitingForClaudeCodeSignIn {
          EnigmaConnectionNote("Finish signing in from Terminal and your browser…")
        }
        EnigmaConnectionNote("Uses your Claude Pro or Max plan through Claude Code, not API billing. Plan usage limits apply. Responses are text-only: Claude Code tools, MCP servers, hooks, plugins, and CLAUDE.md files are turned off, and sessions are not saved.")
        if !settings.isClaudeCodeAvailable {
          EnigmaConnectionNote("Claude Code is required on this Mac. Install it, then check again.")
        }
        EnigmaConnectionNote("Enigma shares the Claude Code sign-in on this Mac. To disconnect, choose another provider, or run claude auth logout in Terminal to sign out everywhere.")
        HStack(spacing: 2) {
          Button(settings.isCheckingClaudeCode ? "Checking…" : "Check sign-in status") {
            Task { await settings.checkClaudeCodeSignIn() }
          }
          .enigmaButtonStyle(.text)
          .disabled(settings.isWaitingForClaudeCodeSignIn || settings.isCheckingClaudeCode)
          if !settings.isClaudeCodeAvailable {
            Link("Claude Code installation instructions", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
              .enigmaButtonStyle(.text)
          }
        }
        .padding(.leading, -8)
        if let check = settings.claudeCodeCheck {
          SignInCheckResult(check, product: "Claude Code",
                            signInHint: "Choose Sign in to connect your Claude plan.")
        } else if let error = settings.claudeCodeError {
          EnigmaStatusLine(.problem, error)
        }
      }
    }
    .task { await settings.refreshClaudeCodeAccount() }
    .onChange(of: settings.claudeCodeCheck) { _, check in
      if let check { SignInCheckResult.announce(check, product: "Claude Code") }
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
        .accessibilityLabel("Cancel Claude Code sign-in")
    } else {
      Button("Sign in") {
        settings.signInToClaudeCode { NSWorkspace.shared.open($0) }
      }
      .enigmaButtonStyle(.secondary)
      .disabled(!settings.isClaudeCodeAvailable || settings.isCheckingClaudeCode)
      .accessibilityLabel("Sign in to Claude Code")
    }
  }
}

/// What "Check sign-in status" found, with the next step.
struct SignInCheckResult: View {
  let check: CloudSettingsModel.SignInCheck
  let product: String
  let signInHint: String

  init(_ check: CloudSettingsModel.SignInCheck, product: String, signInHint: String) {
    self.check = check
    self.product = product
    self.signInHint = signInHint
  }

  static func message(_ check: CloudSettingsModel.SignInCheck, product: String) -> (EnigmaStatusLine.Status, String) {
    switch check {
    case .signedIn(let who): (.on, who.map { "Signed in as \($0)" } ?? "Signed in")
    case .notSignedIn: (.off, "Not signed in")
    case .notInstalled: (.problem, "\(product) not found on this Mac")
    case .failed(let message): (.problem, message)
    }
  }

  static func announce(_ check: CloudSettingsModel.SignInCheck, product: String) {
    AccessibilityNotification.Announcement(message(check, product: product).1).post()
  }

  var body: some View {
    let line = Self.message(check, product: product)
    VStack(alignment: .leading, spacing: 4) {
      EnigmaStatusLine(line.0, line.1)
      switch check {
      case .signedIn, .notInstalled: EmptyView()
      case .notSignedIn: EnigmaConnectionNote(signInHint)
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
