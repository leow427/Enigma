import SwiftUI

/// Shared by the full chat and compact selection composers; no hidden search state.
struct WebSearchStatusView: View {
  @ObservedObject var settings: WebSearchSettings
  let isExplicit: Bool
  var compact = false
  var openSettings: () -> Void

  var body: some View {
    if isExplicit || settings.canSearchAutomatically {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          if isExplicit {
            Label("Web Search · This message", systemImage: "globe")
              .help("Delete /search from the draft to cancel explicit search for this message.")
          }
          if settings.canSearchAutomatically {
            Text("Auto search · On")
            Button("Off") { settings.automaticallySearch = false }
              .buttonStyle(.plain)
              .foregroundStyle(NatureGlass.accent)
              .accessibilityLabel("Turn off automatic web search")
              .help("Turn off automatic search for later messages. This preference is saved; /search still works.")
          }
          if !settings.hasAPIKey {
            Button("Add Brave key…", action: openSettings).buttonStyle(.borderless)
          }
        }
        if !compact {
          Text("Search sends queries to Brave, including relevant attached context.")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .help("Search uses Brave, including in Local mode. Only your question or /search can authorize retrieval; attached context may refine the query.")
    }
  }
}

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
      Text("With a saved Brave key, questions about news, recent events and changing facts can search without /search. This also applies in Local mode and sends your current question to Brave. Turn this off to use search only when explicitly enabled.")
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
      Text("Type /search to search for this message only, even for timeless questions. Delete it before sending to cancel explicit search. Later messages follow the automatic-search setting; when active, both composers show Auto search · On with Off. Search sends queries to Brave, including in Local mode. Relevant attached context may refine a query only after your question authorizes search; your selected model writes the answer.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Link("Brave Search API dashboard", destination: URL(string: "https://api-dashboard.search.brave.com/")!)
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
  }
}
