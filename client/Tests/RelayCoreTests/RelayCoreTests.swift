import Foundation
import XCTest

@testable import RelayCore

final class RelayCoreTests: XCTestCase {
  func testOrdinaryBookmarkFollowsMovedExternalStyleSource() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let old = base.appendingPathComponent("外接硬碟/素材")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let bookmark = try old.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    let moved = base.appendingPathComponent("外接硬碟/搬移後素材")
    try FileManager.default.moveItem(at: old, to: moved)
    let restored = SourceAccess.resolve(path: old.path, bookmark: bookmark)
    XCTAssertEqual(restored.resolvingSymlinksInPath().path, moved.resolvingSymlinksInPath().path)
    XCTAssertNoThrow(try SourceAccess.check(restored))
  }
  func testSourceErrorsDistinguishPermissionMissingAndIO() {
    let url = URL(fileURLWithPath: "/Volumes/Test Drive/素材.mov")
    let denied = NSError(
      domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 1)])
    XCTAssertTrue(SourceAccess.failure(denied, url: url).localizedDescription.contains("macOS 未允許"))
    XCTAssertTrue(
      SourceAccess.failure(NSError(domain: NSPOSIXErrorDomain, code: 2), url: url)
        .localizedDescription.contains("接回硬碟"))
    let io = SourceAccess.failure(NSError(domain: NSPOSIXErrorDomain, code: 5), url: url)
      .localizedDescription
    XCTAssertFalse(SourceAccess.failure(denied, url: url).retryable)
    XCTAssertTrue(
      SourceAccess.failure(NSError(domain: NSPOSIXErrorDomain, code: 2), url: url).retryable)
    XCTAssertTrue(
      SourceAccess.failure(NSError(domain: NSPOSIXErrorDomain, code: 5), url: url).retryable)
    XCTAssertTrue(io.contains(url.path))
    XCTAssertTrue(io.contains("NSPOSIXErrorDomain 5"))
    XCTAssertFalse(io.contains("找不到"))
  }
  func testShortReadsAccumulateAndEOFStillFails() throws {
    var parts = [Data([1]), Data([2, 3]), Data([4])]
    XCTAssertEqual(
      try SourceAccess.readExactly(count: 4) { _ in parts.removeFirst() }, Data([1, 2, 3, 4]))
    XCTAssertThrowsError(try SourceAccess.readExactly(count: 4) { _ in nil })
  }
  func testReadExternalStylePathWithSpacesAndApostrophe() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("Travel SSD's 2T/中文素材/相機.mov")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0, 1, 2, 3, 4]).write(to: source)
    XCTAssertEqual(try SourceAccess.readChunk(at: source, offset: 2, count: 3), Data([2, 3, 4]))
    XCTAssertThrowsError(try SourceAccess.readChunk(at: source, offset: 2, count: 4))
    let missing = base.appendingPathComponent("disconnected")
    XCTAssertThrowsError(try SourceAccess.check(missing))
  }
  func info() throws -> ConnectionInfo {
    let cert = try Data(
      contentsOf: XCTUnwrap(
        Bundle.module.url(forResource: "test-cert", withExtension: "der", subdirectory: "Fixtures"))
    )
    let object: [String: Any] = [
      "schema": 1, "server_id": String(repeating: "a", count: 32),
      "client_id": String(repeating: "b", count: 32), "name": "Test Relay",
      "endpoints": ["https://127.0.0.1:8743", "https://localhost:8743"],
      "fingerprint": ConnectionInfo.sha(cert), "certificate": cert.base64EncodedString(),
      "token": "test_only_connection_token_not_a_secret_0001", "role": "client",
    ]
    return try JSONDecoder().decode(
      ConnectionInfo.self, from: JSONSerialization.data(withJSONObject: object))
  }
  func testConnectionJSONAndURIImport() throws {
    let value = try info()
    let data = try JSONEncoder().encode(value)
    XCTAssertEqual(
      try ConnectionInfo.parse(String(decoding: data, as: UTF8.self)).server_id, value.server_id)
    let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    XCTAssertEqual(
      try ConnectionInfo.parse("Connection:\nnasrelay://connect?data=" + encoded + "\n").client_id,
      value.client_id)
  }
  func testWrongCertificateFingerprintRejected() throws {
    var value = try info()
    value.fingerprint = String(repeating: "0", count: 64)
    XCTAssertThrowsError(try value.validate())
  }
  func testInsecureAndCredentialURLsRejected() throws {
    for endpoint in [
      "http://localhost:8743", "https://user:password@localhost", "https://localhost/v1",
      "https://localhost?token=bad",
    ] {
      var value = try info()
      value.endpoints = [endpoint]
      XCTAssertThrowsError(try value.validate(), endpoint)
    }
  }
  func testPersistedProfileDoesNotContainToken() throws {
    let value = try info()
    let serialized = String(decoding: try JSONEncoder().encode(ServerProfile(value)), as: UTF8.self)
    XCTAssertFalse(serialized.contains(value.token))
    XCTAssertFalse(serialized.contains("\"token\""))
  }
  func testAutoAndManualRouting() {
    XCTAssertEqual(Routing.nearest(["remote": 90, "lan": 2]), "lan")
    XCTAssertEqual(Routing.nearest(["remote": 90, "lan": 2], manual: "remote"), "remote")
    XCTAssertNil(Routing.nearest(["lan": 2], manual: "offline"))
    XCTAssertEqual(Routing.nearest(["b": 2, "a": 2]), "a")
  }
  func testResumeMeterDoesNotCountAlreadyTransferredBytes() {
    var meter = TransferMeter(time: 10, bytes: 1000)
    let result = meter.sample(time: 12, bytes: 1200, total: 1400)
    XCTAssertEqual(result.speed, 100, accuracy: 0.001)
    XCTAssertEqual(result.eta ?? 0, 2, accuracy: 0.001)
  }
  func testMeterIgnoresCounterRegressionAndZeroRate() {
    var meter = TransferMeter(time: 10, bytes: 1000)
    XCTAssertEqual(meter.sample(time: 11, bytes: 900, total: 2000).speed, 0)
    let stopped = meter.sample(time: 12, bytes: 1000, total: 2000)
    XCTAssertEqual(stopped.speed, 0)
    XCTAssertNil(stopped.eta)
  }
  func testUnsafeArchiveFoldersRejected() {
    for p in ["/absolute", "../escape", "a/../b", "a//b", "a\\b", ".nas-relay-internal", "x\n"] {
      XCTAssertFalse(Routing.safeFolder(p), p)
    }
    XCTAssertTrue(Routing.safeFolder(""))
    XCTAssertTrue(Routing.safeFolder("3_專案存檔/Podcast"))
  }
  func testManifestKeepsOriginalAndEmptyDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("第 1 集")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
    let file = source.appendingPathComponent("camera.mov")
    let data = Data("unchanged media".utf8)
    try data.write(to: file)
    try Data("Finder view metadata".utf8).write(to: source.appendingPathComponent(".DS_Store"))
    let m = try ManifestBuilder.build(
      source: source, id: String(repeating: "c", count: 32),
      targetID: String(repeating: "d", count: 32), folder: "", progress: { _, _ in })
    XCTAssertEqual(m.bytes, Int64(data.count))
    XCTAssertEqual(m.entries.count, 3)
    try ManifestBuilder.verify(source: source, manifest: m, progress: { _, _ in })
    XCTAssertEqual(try Data(contentsOf: file), data)
    try Data("changed".utf8).write(to: file)
    XCTAssertThrowsError(
      try ManifestBuilder.verify(source: source, manifest: m, progress: { _, _ in }))
  }
  func testManifestRejectsSymbolicLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
    XCTAssertThrowsError(
      try ManifestBuilder.build(
        source: root, id: String(repeating: "c", count: 32),
        targetID: String(repeating: "d", count: 32), folder: "", progress: { _, _ in }))
  }
  func testReservedNamesAreCaseInsensitive() {
    XCTAssertFalse(Routing.safeFolder("Footage/.NAS-RELAY-INCOMPLETE.JSON"))
    XCTAssertFalse(Routing.safeFolder(".RELAY-PARTIAL"))
  }
  func testEditingConnectionKeepsIdentityAndStorageChoices() throws {
    var profile = ServerProfile(try info())
    profile.preferredTarget = "target"
    profile.preferredFolder = "Podcast"
    let updated = try profile.edited(
      name: "Office Relay", addresses: "192.168.1.20\nhttps://relay.local:9443\n192.168.1.20")
    XCTAssertEqual(updated.endpoints, ["https://192.168.1.20:8743", "https://relay.local:9443"])
    XCTAssertEqual(updated.id, profile.id)
    XCTAssertEqual(updated.clientID, profile.clientID)
    XCTAssertEqual(updated.fingerprint, profile.fingerprint)
    XCTAssertEqual(updated.certificate, profile.certificate)
    XCTAssertEqual(updated.preferredTarget, "target")
    XCTAssertEqual(updated.preferredFolder, "Podcast")
    for address in [
      "http://relay.local", "https://user:pass@relay.local", "https://relay.local/private",
      "https://relay.local?token=x",
    ] {
      XCTAssertThrowsError(try profile.edited(name: "Relay", addresses: address))
    }
  }
  func testResumePreparationKeepsConfirmedProgressAfterRestart() throws {
    var task = LocalTask(
      id: "job", name: "Footage", source: "/tmp/Footage", bookmark: nil, serverID: "relay",
      targetID: "nas", folder: "")
    task.bytes = 1000
    task.uploaded = 110
    task.state = "paused"
    let saved = try JSONEncoder().encode(task)
    var restored = try JSONDecoder().decode(LocalTask.self, from: saved)
    for state in ["resuming", "checking_resume", "preparing", "checking_source", "uploading"] {
      restored.state = state
      restored.preparationDone = 0
      XCTAssertEqual(restored.uploadFraction, 0.11, accuracy: 0.0001)
    }
    restored.accepted = true
    XCTAssertEqual(restored.uploadFraction, 1)
  }
}
