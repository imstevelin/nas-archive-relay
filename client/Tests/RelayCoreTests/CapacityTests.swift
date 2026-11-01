import Foundation
import XCTest

@testable import RelayCore

final class CapacityTests: XCTestCase {
  func testServerCapacityAndLegacyCompatibility() throws {
    let base: [String: Any] = [
      "server_id": "relay", "name": "Relay", "version": "0.4.0",
      "role": "admin", "client_id": "client", "default_target": "", "default_folder": "",
      "endpoints": [], "free_bytes": 1000, "reserve_bytes": 100, "chunk_size": 8,
    ]
    let legacy = try JSONDecoder().decode(
      ServerInfo.self, from: JSONSerialization.data(withJSONObject: base))
    XCTAssertNil(
      legacy.available_upload_bytes, "Do not mislabel physical free space as admission capacity")
    var modern = base
    modern["total_bytes"] = 2000
    modern["reserved_upload_bytes"] = 300
    modern["available_upload_bytes"] = 600
    modern["cleanup_pending_jobs"] = 1
    modern["cleanup_pending_bytes"] = 200
    let info = try JSONDecoder().decode(
      ServerInfo.self, from: JSONSerialization.data(withJSONObject: modern))
    XCTAssertEqual(info.available_upload_bytes, 600)
    XCTAssertEqual(info.reserved_upload_bytes, 300)
    XCTAssertEqual(info.cleanup_pending_bytes, 200)
  }
}
