import SwiftUI

// Messages cards: the send approval and the problem card.

/// Shows exactly who will receive what, and sends only on an explicit choice.
/// Send is the one `accent` button and has no keyboard shortcut; Escape is
/// Don't Send.
struct MessagesSendApprovalCard: View {
  let approval: MessagesSendApproval
  let answer: (Bool) -> Void
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    VStack(alignment: .leading, spacing: 10) {
      EnigmaCardTitle("Send this message?", assetImage: "MessagesTool")
      VStack(alignment: .leading, spacing: 3) {
        if let name = approval.conversationName {
          Text("Group: \(name)")
            .font(EnigmaTypography.ui(12.5, weight: .semibold))
            .foregroundStyle(palette.textPrimary.color)
        }
        ForEach(Array(approval.recipients.enumerated()), id: \.offset) { _, recipient in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(recipient.name ?? recipient.handle)
              .font(EnigmaTypography.ui(12.5, weight: .semibold))
              .foregroundStyle(palette.textPrimary.color)
            if recipient.name != nil {
              Text(recipient.handle)
                .font(EnigmaTypography.mono(11))
                .foregroundStyle(palette.textSecondary.color)
            }
          }
        }
        Text("Via \(approval.service)")
          .font(EnigmaTypography.mono(11))
          .foregroundStyle(palette.textSecondary.color)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("To " + approval.recipients.map { [$0.name, $0.handle].compactMap { $0 }.joined(separator: ", ") }
        .joined(separator: "; "))
      ScrollView {
        Text(approval.text)
          .font(EnigmaTypography.ui(13.5))
          .foregroundStyle(palette.textPrimary.color)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .frame(maxHeight: 160)
      .fixedSize(horizontal: false, vertical: true)
      .background(palette.background.color, in: shape)
      .enigmaEdge(shape)
      .accessibilityLabel("Message text")
      .accessibilityValue(approval.text)
      HStack(spacing: 8) {
        Text("Enigma sends only if you choose Send.")
          .font(EnigmaTypography.ui(12))
          .foregroundStyle(palette.textSecondary.color)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button("Don't Send", role: .cancel) { answer(false) }
          .enigmaButtonStyle(.secondary)
          .keyboardShortcut(.cancelAction)
          .enigmaTestMarker("Don't Send")
        Button("Send") { answer(true) }
          .enigmaButtonStyle(.compactPrimary)
          .enigmaTestMarker("Send")
      }
    }
    .enigmaCard()
  }
}

/// Why /messages couldn't run, with the settings pane that fixes it.
struct MessagesIssueCard: View {
  let issue: MessagesIssue
  let openSettings: (MessagesPrivacyPane) -> Void
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      EnigmaStatusLine(.problem, issue.message)
      HStack(spacing: 8) {
        if let pane = issue.pane {
          Button(pane.settingsButtonTitle) { openSettings(pane) }
            .enigmaButtonStyle(.compactPrimary)
            .enigmaTestMarker(pane.settingsButtonTitle)
        }
        Button("Dismiss", action: dismiss)
          .enigmaButtonStyle(.secondary)
          .enigmaTestMarker("Dismiss")
      }
    }
    .enigmaCard(padding: 12)
  }
}
