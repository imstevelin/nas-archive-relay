import Foundation
import XCTest
@testable import RelayCore

final class SourceFaultTests: XCTestCase {
  func testReadFaultRequiresManualRetryAndRecordsAttemptedOffset() {
    let url = URL(fileURLWithPath: "/Volumes/A/file.mov")
    for error in [NSError(domain: NSPOSIXErrorDomain, code: 5),
                  NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)] {
      let fault = SourceAccess.failure(error, url: url, offset: 9380560896)
      XCTAssertTrue(fault.sourceIO)
      XCTAssertFalse(fault.retryable)
      XCTAssertTrue(fault.message.contains("9380560896 bytes"))
    }
    XCTAssertFalse(RelayFailure("network", status: 503, retryable: true).sourceIO)
    XCTAssertFalse(SourceAccess.failure(NSError(domain: NSPOSIXErrorDomain, code: 13), url: url).sourceIO)
    XCTAssertFalse(SourceAccess.failure(NSError(domain: NSPOSIXErrorDomain, code: 2), url: url).sourceIO)
  }
  func testFaultSelectsOnlyUnfinishedSourceJobsOnSameVolume() throws {
    func job(_ id: String, _ path: String, _ volume: String? = nil) -> LocalTask {
      var t = LocalTask(id: id, name: id, source: path, bookmark: nil,
                        serverID: "s", targetID: "t", folder: "")
      t.sourceVolumeID = volume
      return t
    }
    let failed = job("f", "/Volumes/Drive/one", "uuid")
    var other = job("o", "/Volumes/Renamed/two", "uuid")
    other.uploaded = 86083912672
    XCTAssertTrue(SourceFaultPolicy.shouldSuspend(other, after: failed))
    XCTAssertTrue(SourceFaultPolicy.shouldSuspend(job("old", "/Volumes/Drive/old"), after: failed))
    XCTAssertFalse(SourceFaultPolicy.shouldSuspend(job("x", "/Volumes/Drive2/x"), after: failed))
    XCTAssertFalse(SourceFaultPolicy.shouldSuspend(job("x", "/Volumes/Drive/x", "different"), after: failed))
    other.accepted = true
    XCTAssertFalse(SourceFaultPolicy.shouldSuspend(other, after: failed))
    other.accepted = false
    other.state = "paused"
    XCTAssertFalse(SourceFaultPolicy.shouldSuspend(other, after: failed))
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(failed)) as! [String: Any]
    object.removeValue(forKey: "sourceVolumeID")
    let old = try JSONDecoder().decode(LocalTask.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(old.sourceVolumeID)
  }
}
