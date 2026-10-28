import Foundation

/// Native tool calling (F32): capable models get Enigma's tools on every turn and
/// decide themselves when to use them; other models keep today's chips and rules.
enum NativeTools {
  /// Off until F32 CP5. Flagged routes take today's path while false.
  static let isEnabled = false

  /// True when the route's model calls tools natively. Ignores `isEnabled`.
  static func isCapable(route: Route, localModel: LocalModel?) -> Bool {
    if route.mode == .local { return localModel?.catalogDescriptor?.supportsNativeTools ?? false }
    guard let provider = CloudProviderID(rawValue: route.providerID) else { return false }
    return CloudModelCapabilities.supportsNativeTools(provider: provider, modelID: route.modelID)
  }
}
