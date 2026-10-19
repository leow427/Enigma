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

/// The preview sheet is a separate window; give it the panel's existing capture exclusion.
struct ScreenConsentWindowPrivacy: NSViewRepresentable {
  func makeNSView(context: Context) -> PrivacyView { PrivacyView() }
  func updateNSView(_ view: PrivacyView, context: Context) {}

  final class PrivacyView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.sharingType = .none
    }
  }
}
