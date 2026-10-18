import SwiftUI

/// Cloud screenshots in the new Settings. Same setting and explanations as
/// `ScreenSettingsSection`.
struct EnigmaScreenSettingsSection: View {
  @ObservedObject var settings: ScreenSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Screen")
      EnigmaRow("Allow screenshots to be sent to cloud models",
                subtitle: "Off by default. " + ScreenSettings.savedPermissionExplanation) {
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
