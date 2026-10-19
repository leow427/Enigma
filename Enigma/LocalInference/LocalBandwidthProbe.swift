import Foundation
import Metal

/// Measures the memory bandwidth the GPU sees with a short blit copy, which is
/// what bounds local token generation. It makes no network requests and keeps
/// nothing but the resulting number.
enum LocalBandwidthProbe {
  static let validRange: ClosedRange<Double> = 50...1_500
  private static let bufferLength = 256 * 1_048_576
  private static let passes = 5

  /// Largest finite positive pass, clamped into validRange; nil when there is none.
  static func best(of passes: [Double]) -> Double? {
    guard let best = passes.filter({ $0.isFinite && $0 > 0 }).max() else { return nil }
    return min(validRange.upperBound, max(validRange.lowerBound, best))
  }

  /// Five blit passes on the GPU; nil without a device or on any command-buffer error.
  static func measure(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) -> Double? {
    guard let device, let queue = device.makeCommandQueue(),
          let first = device.makeBuffer(length: bufferLength, options: .storageModePrivate),
          let second = device.makeBuffer(length: bufferLength, options: .storageModePrivate) else {
      return nil
    }
    var readings: [Double] = []
    for pass in 0..<passes {
      // One pass copies A to B and back: 512 MiB read and 512 MiB written.
      guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return nil }
      blit.copy(from: first, sourceOffset: 0, to: second, destinationOffset: 0, size: bufferLength)
      blit.copy(from: second, sourceOffset: 0, to: first, destinationOffset: 0, size: bufferLength)
      blit.endEncoding()
      commands.commit()
      commands.waitUntilCompleted()
      guard commands.status == .completed else {
        NSLog("The memory bandwidth test failed: %@", String(describing: commands.error))
        return nil
      }
      // The first pass warms up the buffers and clocks.
      guard pass > 0 else { continue }
      let seconds = commands.gpuEndTime - commands.gpuStartTime
      readings.append(4 * Double(bufferLength) / seconds / 1e9)
    }
    return best(of: readings)
  }
}
