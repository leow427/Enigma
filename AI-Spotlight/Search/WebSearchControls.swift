import SwiftUI

struct ToolMenuLabel: View {
  let title: String
  let imageName: String

  var body: some View {
    Label {
      Text(title)
    } icon: {
      Image(nsImage: Self.menuImage(named: imageName))
        .renderingMode(.template)
        .foregroundStyle(.primary)
    }
  }

  static func menuImage(named name: String) -> NSImage {
    // Native menus use the NSImage's intrinsic size, ignoring SwiftUI frames.
    // Copy the asset so resizing the menu icon cannot change the composer icon.
    let size = NSSize(width: 16, height: 16)
    let image = (NSImage(named: name)?.copy() as? NSImage) ?? NSImage(size: size)
    image.size = size
    image.isTemplate = true
    return image
  }
}

struct WebSearchSettingsSection: View {
  @ObservedObject var settings: WebSearchSettings
  @State private var apiKey = ""
  @State private var error: String?

  var body: some View {
    Section("Web Search · Brave") {
      Toggle("Search automatically when fresh information is needed", isOn: $settings.automaticallySearch)
      Text("On by default. With a saved Brave key, questions about news, recent events and changing facts can search automatically, including in Local mode. Without a key, automatic search stays inactive. Turn this setting off for manual-only search.")
        .font(.caption)
        .foregroundStyle(.secondary)
      SecureField(settings.hasAPIKey ? "Replace stored Brave API key" : "Brave Search API key", text: $apiKey)
        .textFieldStyle(.roundedBorder)
      HStack {
        Button("Save Key") {
          do {
            try settings.saveAPIKey(apiKey)
            apiKey = ""
            error = nil
          } catch { self.error = error.localizedDescription }
        }
        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Remove Key", role: .destructive) {
          do {
            try settings.removeAPIKey()
            apiKey = ""
            error = nil
          } catch { self.error = error.localizedDescription }
        }
        .disabled(!settings.hasAPIKey)
        if settings.hasAPIKey {
          Label("Key saved", systemImage: "checkmark.circle")
            .foregroundStyle(.green)
        }
      }
      Text("Use a Brave Search key with LLM Context access. Stored in macOS Keychain. Brave usage is billed separately.")
        .font(.caption)
        .foregroundStyle(.secondary)
      if settings.hasAPIKey {
        Text("Type /search to search for this message only, even for timeless questions. Delete it before sending to cancel explicit search. Later messages follow the automatic-search setting.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text("Search sends queries to Brave, including in Local mode. Relevant attached context may refine a query only after your question authorizes search; your selected model writes the answer.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Link("Brave Search API dashboard", destination: URL(string: "https://api-dashboard.search.brave.com/")!)
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
  }
}
