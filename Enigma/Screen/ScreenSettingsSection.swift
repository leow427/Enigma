import SwiftUI

/// Cloud screenshots in Settings: the upload setting and what it means.
struct ScreenSettingsSection: View {
  @ObservedObject var settings: ScreenSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaRow("Allow screenshots to be sent to cloud models", subtitle: "Off by default.",
                info: ScreenSettings.savedPermissionExplanation) {
        EnigmaSwitch("Allow screenshots to be sent to cloud models", isOn: $settings.allowCloudScreenshots)
      }
      EnigmaHairline()
      VStack(alignment: .leading, spacing: 6) {
        EnigmaNote(ScreenSettings.ocrExplanation)
        EnigmaNote(ScreenSettings.modelPickerNote)
      }
      .padding(.top, 10)
    }
  }
}
