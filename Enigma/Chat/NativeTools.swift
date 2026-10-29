import Foundation
import OSLog

/// Native tool calling (F32): capable models get Enigma's tools on every turn and
/// decide themselves when to use them; other models keep today's chips and rules.
enum NativeTools {
  /// On since F32 CP5. Tests pass `nativeToolsEnabled: false` to `LocalChatViewModel` for today's path.
  static let isEnabled = true

  /// Routes, tool parts and tool names only: never message text, queries, arguments or results.
  static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.leow427.AISpotlight", category: "NativeTools")

  /// True when the route's model calls tools natively. Ignores `isEnabled`.
  static func isCapable(route: Route, localModel: LocalModel?) -> Bool {
    if route.mode == .local { return localModel?.catalogDescriptor?.supportsNativeTools ?? false }
    guard let provider = CloudProviderID(rawValue: route.providerID) else { return false }
    return CloudModelCapabilities.supportsNativeTools(provider: provider, modelID: route.modelID)
  }

  /// Whether the composer treats the selected mode as capable, for its chips: Local and Auto
  /// follow the local model (Auto starts local), Cloud the chosen cloud model. Ignores `isEnabled`.
  static func isCapable(mode: ChatMode, localModel: LocalModel?, cloudProvider: CloudProviderID, cloudModelID: String) -> Bool {
    switch mode {
    case .local, .auto:
      guard let localModel else { return false }
      return isCapable(route: Route(mode: .local, providerID: "local", modelID: localModel.id, usesNetwork: false),
                       localModel: localModel)
    case .cloud:
      return isCapable(route: Route(mode: .cloud, providerID: cloudProvider.rawValue, modelID: cloudModelID, usesNetwork: true),
                       localModel: localModel)
    }
  }
}
