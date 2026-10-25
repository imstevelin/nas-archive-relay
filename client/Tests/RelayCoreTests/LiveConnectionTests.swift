import Foundation
import XCTest

@testable import RelayCore

final class LiveConnectionTests: XCTestCase {
  func testPinnedLiveConnection() async throws {
    guard let path = ProcessInfo.processInfo.environment["NAS_RELAY_CONNECTION"] else {
      throw XCTSkip(
        "Set NAS_RELAY_CONNECTION to a private connection JSON for opt-in live TLS verification")
    }
    let info = try ConnectionInfo.parse(String(contentsOfFile: path, encoding: .utf8))
    let api = RelayAPI(profile: ServerProfile(info), token: info.token)
    defer { api.close() }
    for endpoint in info.endpoints {
      let ping = try await api.get("v1/ping", endpoint: endpoint, as: Ping.self)
      XCTAssertEqual(ping.server_id, info.server_id)
    }
  }
}
