import SwiftUI

/// Asks before a model reads a chat, searches all chats, searches the web after reading messages, or
/// a provider's web search gets the approximate location.
/// The reply waits until a button is chosen. Escape is Don't allow; For this conversation is the
/// one `accent` button, so the lasting answer is never the easy one.
struct ToolPermissionCard: View {
  let request: ToolPermissionRequest
  let answer: (ToolPermissionAnswer) -> Void
  @Environment(\.enigmaPalette) private var palette

  /// The card's buttons, in order, with what each answers.
  static let buttons: [(title: String, answer: ToolPermissionAnswer)] = [
    ("Don't allow", .deny), ("For this conversation", .conversation), ("Always", .always),
  ]
  /// The one lasting answer of a card that offers no Always: for this chat.
  static let allowTitle = "Allow"

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      EnigmaCardTitle(request.title, systemImage: isMessages ? nil : "globe",
                      assetImage: isMessages ? "MessagesTool" : nil)
      Text(request.detail)
        .font(EnigmaTypography.ui(12))
        .foregroundStyle(palette.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Spacer(minLength: 8)
        Button(Self.buttons[0].title, role: .cancel) { answer(.deny) }
          .enigmaButtonStyle(.secondary)
          .keyboardShortcut(.cancelAction)
          .enigmaTestMarker(Self.buttons[0].title)
        if request.offersAlways {
          Button(Self.buttons[1].title) { answer(.conversation) }
            .enigmaButtonStyle(.compactPrimary)
            .enigmaTestMarker(Self.buttons[1].title)
          Button(Self.buttons[2].title) { answer(.always) }
            .enigmaButtonStyle(.secondary)
            .enigmaTestMarker(Self.buttons[2].title)
        } else {
          Button(Self.allowTitle) { answer(.conversation) }
            .enigmaButtonStyle(.compactPrimary)
            .enigmaTestMarker(Self.allowTitle)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(request.title + " " + request.detail)
    .enigmaCard()
  }

  private var isMessages: Bool {
    switch request.permission {
    case .searchAfterMessages, .shareLocation: return false
    default: return true
    }
  }
}
