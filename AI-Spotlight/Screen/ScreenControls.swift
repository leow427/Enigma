import SwiftUI

// Hosted tests can attach noninteractive native markers to locate real controls.
// Normal app views supply no marker; actions still go through the actual buttons.
private struct ScreenControlMarkerKey: EnvironmentKey {
  static let defaultValue: (@MainActor @Sendable (String) -> AnyView)? = nil
}

extension EnvironmentValues {
  var screenControlMarker: (@MainActor @Sendable (String) -> AnyView)? {
    get { self[ScreenControlMarkerKey.self] }
    set { self[ScreenControlMarkerKey.self] = newValue }
  }
}

struct ScreenAttachmentView: View {
  @Environment(\.screenControlMarker) private var controlMarker
  let attachment: ScreenAttachment
  let isBusy: Bool
  let remove: () -> Void
  let retake: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(nsImage: attachment.originalImage)
        .resizable().scaledToFit().frame(width: 76, height: 52)
        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Captured \(attachment.source.captureScope)")
      VStack(alignment: .leading, spacing: 3) {
        Text(attachment.source.label).font(.caption.weight(.medium))
        Text("Attached · \(attachment.status.rawValue)")
          .font(.caption2).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Button("Retake", action: retake).disabled(isBusy)
        .accessibilityLabel("Retake screenshot")
        .background { controlMarker?("Retake") }
      Button("Remove", action: remove).disabled(isBusy)
        .accessibilityLabel("Remove screenshot")
        .background { controlMarker?("Remove") }
    }
    .buttonStyle(.bordered).controlSize(.small)
    .padding(10)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
  }
}

struct ScreenUploadConsentView: View {
  @Environment(\.screenControlMarker) private var controlMarker
  let consent: ScreenUploadConsent
  let allow: () -> Void
  let decline: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(consent.title).font(.headline)
      Image(nsImage: consent.attachment.originalImage)
        .resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 160)
        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Preview of \(consent.attachment.source.captureScope)")
      Text(consent.explanation)
      Text(ScreenSettings.savedPermissionExplanation)
      Text(ScreenSettings.ocrExplanation).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Keep Screenshots Local", action: decline)
          .buttonStyle(.borderedProminent).tint(Color(white: 0.3))
          .keyboardShortcut(.cancelAction)
          .background { controlMarker?("Keep Screenshots Local") }
        Spacer()
        Button("Allow & Send", action: allow)
          .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          .background { controlMarker?("Allow & Send") }
      }
    }
    .font(.callout)
    .fixedSize(horizontal: false, vertical: true)
    .padding(24).frame(width: 500)
    .tint(NatureGlass.accent)
    .background(ScreenConsentWindowPrivacy())
  }
}

/// The preview sheet is a separate window; give it the panel's existing capture exclusion.
private struct ScreenConsentWindowPrivacy: NSViewRepresentable {
  func makeNSView(context: Context) -> PrivacyView { PrivacyView() }
  func updateNSView(_ view: PrivacyView, context: Context) {}

  final class PrivacyView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.sharingType = .none
    }
  }
}
