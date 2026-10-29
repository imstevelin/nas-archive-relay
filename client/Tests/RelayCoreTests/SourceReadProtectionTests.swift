import Foundation
import XCTest

@testable import RelayCore

final class SourceReadProtectionTests: XCTestCase {
  func testProtectionTargetsOnlyLocalExternalVolumes() {
    XCTAssertTrue(SourceReadProtection.isExternalLocal(internalDisk: false, local: true))
    XCTAssertFalse(SourceReadProtection.isExternalLocal(internalDisk: true, local: true))
    XCTAssertFalse(SourceReadProtection.isExternalLocal(internalDisk: false, local: false))
    XCTAssertFalse(SourceReadProtection.isExternalLocal(internalDisk: nil, local: true))
  }
  func testAllFilesOnOneVolumeShareTheSameGate() {
    let registry = SourceReadRegistry()
    XCTAssertTrue(registry.gate(for: "volume-a") === registry.gate(for: "volume-a"))
    XCTAssertFalse(registry.gate(for: "volume-a") === registry.gate(for: "volume-b"))
  }
  func testConcurrentReadersShareOneRateBudget() async throws {
    let gate = SourceReadGate(bytesPerSecond: 24 * 1024 * 1024)
    let started = ProcessInfo.processInfo.systemUptime
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<2 {
        group.addTask { for _ in 0..<4 { try gate.pace(bytes: 1024 * 1024) } }
      }
      try await group.waitForAll()
    }
    XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.25)
  }
  func testQueuedPreparationCanCancelAndDoesNotLockAnotherVolume() async throws {
    let registry = SourceReadRegistry()
    let gate = registry.gate(for: "source")
    try gate.acquirePreparation { _ in }
    let events = AsyncStream<Bool>.makeStream()
    let queued = Task.detached {
      try gate.acquirePreparation { events.continuation.yield($0) }
      gate.releasePreparation()
    }
    var iterator = events.stream.makeAsyncIterator()
    let waiting = await iterator.next()
    XCTAssertEqual(waiting, true)
    let other = registry.gate(for: "other-source")
    try other.acquirePreparation { _ in }
    other.releasePreparation()
    queued.cancel()
    do {
      try await queued.value
      XCTFail("Cancelled preparation must leave the queue")
    } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    gate.releasePreparation()
    try gate.acquirePreparation { _ in }
    gate.releasePreparation()
    events.continuation.finish()
  }
  func testRateWaitCanBeCancelled() async throws {
    let gate = SourceReadGate(bytesPerSecond: 1)
    try gate.pace(bytes: 10)
    let waiting = Task.detached { try gate.pace(bytes: 1) }
    try await Task.sleep(for: .milliseconds(40))
    waiting.cancel()
    do {
      try await waiting.value
      XCTFail("Cancelled read must not wait for its full reservation")
    } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
  }
}
