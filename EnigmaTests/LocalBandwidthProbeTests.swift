import Foundation
import XCTest
@testable import Enigma

final class LocalBandwidthProbeTests: XCTestCase {
  private let gib = LocalHardwareProfile.gib

  func testBestPassIsClampedIntoTheValidRange() {
    XCTAssertEqual(LocalBandwidthProbe.best(of: [100, 250, 240]), 250)
    XCTAssertEqual(LocalBandwidthProbe.best(of: [2_000]), 1_500)
    XCTAssertEqual(LocalBandwidthProbe.best(of: [10]), 50)
    XCTAssertNil(LocalBandwidthProbe.best(of: [.nan, -1, 0, .infinity]))
    XCTAssertNil(LocalBandwidthProbe.best(of: []))
  }

  func testNoMetalDeviceMeasuresNothing() {
    XCTAssertNil(LocalBandwidthProbe.measure(device: nil))
  }

  @MainActor
  func testBandwidthIsMeasuredOncePerFingerprintAndPowerMode() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = LockedBox(mac())
    let probe = LockedBox(0)
    let measure: @Sendable () -> Double? = { probe.update { $0 += 1 }; return 267 }
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil,
      detect: { _ in profile.value }, measureBandwidth: measure)
    await advisor.detectHardware()
    await advisor.detectHardware()
    XCTAssertEqual(probe.value, 1)
    XCTAssertEqual(advisor.hardware?.measuredBandwidth, 267)

    let restored = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil,
      detect: { _ in profile.value }, measureBandwidth: measure)
    await restored.detectHardware()
    XCTAssertEqual(probe.value, 1)
    XCTAssertEqual(restored.hardware?.measuredBandwidth, 267)

    profile.update { $0.lowPowerMode = true }
    await restored.detectHardware()
    XCTAssertEqual(probe.value, 2)
    await restored.detectHardware(remeasureBandwidth: true)
    XCTAssertEqual(probe.value, 3)
  }

  @MainActor
  func testFailedProbeLeavesBandwidthNil() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = LockedBox(0)
    let profile = mac()
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil,
      detect: { _ in profile }, measureBandwidth: { probe.update { $0 += 1 }; return nil })
    await advisor.detectHardware()
    XCTAssertNotNil(advisor.hardware)
    XCTAssertNil(advisor.hardware?.measuredBandwidth)
    XCTAssertFalse(advisor.isDetecting)
    // A failure is remembered for this session only: no retry until Check this Mac.
    await advisor.detectHardware()
    XCTAssertEqual(probe.value, 1)
    await advisor.detectHardware(remeasureBandwidth: true)
    XCTAssertEqual(probe.value, 2)
    XCTAssertFalse(advisor.isDetecting)
    let relaunched = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil,
      detect: { _ in profile }, measureBandwidth: { probe.update { $0 += 1 }; return nil })
    await relaunched.detectHardware()
    XCTAssertEqual(probe.value, 3, "A new launch tries again")
  }

  @MainActor
  func testAdvisorWithoutAProbeNeverMeasures() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = mac()
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in profile })
    await advisor.detectHardware()
    XCTAssertNotNil(advisor.hardware)
    XCTAssertNil(advisor.hardware?.measuredBandwidth)
  }

  func testFingerprintIgnoresMeasuredBandwidth() {
    var measured = mac()
    measured.measuredBandwidth = 267
    XCTAssertEqual(measured.fingerprint, mac().fingerprint)
  }

  func testHardwareReportsWithoutBandwidthStillDecode() throws {
    var profile = mac()
    profile.measuredBandwidth = 267
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    json.removeValue(forKey: "measuredBandwidth")
    let restored = try JSONDecoder().decode(LocalHardwareProfile.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(restored.measuredBandwidth)
    profile.measuredBandwidth = nil
    XCTAssertEqual(restored, profile)
  }

  /// Opt-in: TEST_RUNNER_ENIGMA_BANDWIDTH_PROBE=1 runs the real Metal copy test.
  func testMetalProbeOnThisMac() throws {
    guard ProcessInfo.processInfo.environment["ENIGMA_BANDWIDTH_PROBE"] == "1" else {
      throw XCTSkip("Set TEST_RUNNER_ENIGMA_BANDWIDTH_PROBE=1 to measure this Mac's memory bandwidth.")
    }
    let start = Date()
    let bandwidth = try XCTUnwrap(LocalBandwidthProbe.measure())
    let elapsed = Date().timeIntervalSince(start)
    print("Measured memory bandwidth: \(bandwidth) GB/s in \(elapsed) s")
    XCTAssertTrue(LocalBandwidthProbe.validRange.contains(bandwidth))
    XCTAssertLessThan(elapsed, 0.25)
  }

  private func mac() -> LocalHardwareProfile {
    LocalHardwareProfile(physicalMemory: 24 * gib, isAppleSilicon: true, hasMetal: true, hasUnifiedMemory: true,
      chip: "Fixture chip", device: "Fixture Mac", cpuCount: 12, performanceCPUCount: 8,
      availableDiskBytes: 200 * gib, metalRecommendedWorkingSet: 18 * gib, metalMaximumBufferLength: 8 * gib,
      lowPowerMode: false)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalBandwidthProbeTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value { lock.withLock { stored } }
  func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
