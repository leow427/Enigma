import SwiftUI

// Screen cards: the attached screenshot over the composer, the upload consent
// sheet, and the uploads-off and error cards. They carry hosted-test markers.

/// A screenshot waiting to be sent: a preview, what it captured, and Retake
/// and Remove.
struct ScreenAttachmentCard: View {
  @Environment(\.screenControlMarker) private var controlMarker
  @Environment(\.enigmaPalette) private var palette
  let attachment: ScreenAttachment
  let isBusy: Bool
  let remove: () -> Void
  let retake: () -> Void

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    HStack(spacing: 10) {
      Image(nsImage: attachment.originalImage)
        .resizable().scaledToFit().frame(width: 76, height: 52)
        .background(palette.background.color, in: shape)
        .clipShape(shape)
        .enigmaEdge(shape)
        .accessibilityLabel("Captured \(attachment.source.captureScope)")
      VStack(alignment: .leading, spacing: 3) {
        Text(attachment.source.label)
          .font(EnigmaTypography.ui(12.5, weight: .medium))
          .foregroundStyle(palette.textPrimary.color)
        Text("Attached · \(attachment.status.rawValue)")
          .font(EnigmaTypography.mono(11))
          .foregroundStyle(palette.textSecondary.color)
      }
      Spacer(minLength: 0)
      Button("Retake", action: retake)
        .enigmaButtonStyle(.secondary)
        .disabled(isBusy)
        .accessibilityLabel("Retake screenshot")
        .background { controlMarker?("Retake") }
      Button("Remove", action: remove)
        .enigmaButtonStyle(.secondary)
        .disabled(isBusy)
        .accessibilityLabel("Remove screenshot")
        .background { controlMarker?("Remove") }
    }
    .enigmaCard(padding: 10)
  }
}

/// The question before a screenshot is first uploaded, as in
/// `ScreenUploadConsentView`: the real image, where it goes, and what the
/// answer saves. Allow & Send is the one `accent` button; Escape keeps the
/// screenshot local. The sheet's window is kept out of screen captures.
struct ScreenUploadConsentView: View {
  @Environment(\.screenControlMarker) private var controlMarker
  @Environment(\.enigmaPalette) private var palette
  let consent: ScreenUploadConsent
  let allow: () -> Void
  let decline: () -> Void

  static let width: CGFloat = 500

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    VStack(alignment: .leading, spacing: 14) {
      Text(consent.title)
        .font(EnigmaTypography.ui(16, weight: .semibold))
        .tracking(-0.2)
        .foregroundStyle(palette.textPrimary.color)
        .accessibilityAddTraits(.isHeader)
      Image(nsImage: consent.attachment.originalImage)
        .resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 160)
        .background(palette.surface.color, in: shape)
        .enigmaEdge(shape)
        .accessibilityLabel("Preview of \(consent.attachment.source.captureScope)")
      Text(consent.explanation)
        .font(EnigmaTypography.ui(13))
        .foregroundStyle(palette.textPrimary.color)
      Text(ScreenSettings.savedPermissionExplanation)
        .font(EnigmaTypography.ui(13))
        .foregroundStyle(palette.textPrimary.color)
      Text(ScreenSettings.ocrExplanation)
        .font(EnigmaTypography.ui(12))
        .foregroundStyle(palette.textSecondary.color)
      HStack {
        Button("Keep Screenshots Local", action: decline)
          .enigmaButtonStyle(.secondary)
          .keyboardShortcut(.cancelAction)
          .background { controlMarker?("Keep Screenshots Local") }
        Spacer()
        Button("Allow & Send", action: allow)
          .enigmaButtonStyle(.primary)
          .keyboardShortcut(.defaultAction)
          .background { controlMarker?("Allow & Send") }
      }
      .padding(.top, 4)
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(24)
    .frame(width: Self.width)
    .background(palette.background.color)
    .tint(palette.accent.color)
    .background(ScreenConsentWindowPrivacy())
  }
}

/// Screenshot uploads are off for the attached capture's cloud route.
struct ScreenUploadsOffCard: View {
  let review: () -> Void
  let openSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      EnigmaCardTitle("Screenshot uploads are off", systemImage: "hand.raised")
      EnigmaNote("Cloud image analysis needs your approval. Text can still be read locally.")
      HStack(spacing: 8) {
        Button("Review screenshot permission…", action: review)
          .enigmaButtonStyle(.compactPrimary)
          .enigmaTestMarker("Review screenshot permission…")
        Button("Open Screen Settings", action: openSettings)
          .enigmaButtonStyle(.secondary)
          .enigmaTestMarker("Open Screen Settings")
      }
      .padding(.top, 2)
    }
    .enigmaCard()
  }
}

/// A capture that failed, with the way into Screen Recording settings when
/// that's the cause.
struct ScreenErrorCard: View {
  let error: String
  let needsScreenRecordingSettings: Bool
  let openSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      EnigmaStatusLine(.problem, error)
      if needsScreenRecordingSettings {
        Button("Open Screen Recording Settings…", action: openSettings)
          .enigmaButtonStyle(.compactPrimary)
          .enigmaTestMarker("Open Screen Recording Settings…")
      }
    }
    .enigmaCard(padding: 12)
  }
}
