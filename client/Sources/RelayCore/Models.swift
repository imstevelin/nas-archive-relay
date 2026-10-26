import CryptoKit
import Foundation
import Security

public struct ConnectionInfo: Codable, Sendable {
  public var schema: Int
  public var server_id: String
  public var name: String
  public var endpoints: [String]
  public var fingerprint: String
  public var certificate: String
  public var token: String
  public var client_id: String
  public var role: String

  public static func parse(_ text: String) throws -> ConnectionInfo {
    var data: Data?
    if let line = text.components(separatedBy: .whitespacesAndNewlines).first(where: {
      $0.hasPrefix("nasrelay://connect?")
    }),
      let parts = URLComponents(string: line),
      let encoded = parts.queryItems?.first(where: { $0.name == "data" })?.value
    {
      var value = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
        of: "_", with: "/")
      value += String(repeating: "=", count: (4 - value.count % 4) % 4)
      data = Data(base64Encoded: value)
    } else {
      data = text.data(using: .utf8)
    }
    guard let data, data.count < 131072 else { throw RelayFailure("連線資訊格式不正確") }
    let value = try JSONDecoder().decode(ConnectionInfo.self, from: data)
    try value.validate()
    return value
  }
  public func validate() throws {
    let id: (String) -> Bool = {
      $0.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
    }
    guard schema == 1, id(server_id), id(client_id), !name.isEmpty,
      ["admin", "client"].contains(role),
      token.count >= 32, token.count <= 128, !token.contains(where: { $0.isWhitespace }),
      let der = Data(base64Encoded: certificate), der.count < 65536,
      SecCertificateCreateWithData(nil, der as CFData) != nil,
      Self.sha(der) == fingerprint.lowercased(), !endpoints.isEmpty, endpoints.count <= 16
    else {
      throw RelayFailure("連線資訊或憑證指紋不符")
    }
    for endpoint in endpoints {
      guard let u = URLComponents(string: endpoint), u.scheme == "https", let host = u.host,
        !host.isEmpty,
        u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
        u.path.isEmpty || u.path == "/"
      else { throw RelayFailure("中繼位址必須是 HTTPS 根位址") }
    }
  }
  public static func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct ServerProfile: Codable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var endpoints: [String]
  public var fingerprint: String
  public var certificate: String
  public var clientID: String
  public var role: String
  public var preferredTarget: String?
  public var preferredFolder: String?
  public init(_ info: ConnectionInfo) {
    id = info.server_id
    name = info.name
    endpoints = info.endpoints
    fingerprint = info.fingerprint
    certificate = info.certificate
    clientID = info.client_id
    role = info.role
  }
  public func edited(name: String, addresses: String) throws -> ServerProfile {
    let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty, label.count <= 160 else { throw RelayFailure("請輸入伺服器顯示名稱") }
    let port = endpoints.first.flatMap { URL(string: $0)?.port } ?? 8743
    let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
    let values = addresses.components(separatedBy: separators).filter { !$0.isEmpty }
    var normalized: [String] = []
    for value in values {
      let explicitScheme = value.contains("://")
      guard var u = URLComponents(string: explicitScheme ? value : "https://" + value),
        u.scheme == "https", let host = u.host, !host.isEmpty,
        u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
        u.path.isEmpty || u.path == "/", u.port == nil || (1...65535).contains(u.port!)
      else { throw RelayFailure("請輸入 IP 或 HTTPS 根位址，例如 https://192.168.1.20:8743") }
      if !explicitScheme && u.port == nil { u.port = port }
      u.path = ""
      guard let endpoint = u.url?.absoluteString else { throw RelayFailure("伺服器位址不正確") }
      if !normalized.contains(endpoint) { normalized.append(endpoint) }
    }
    guard !normalized.isEmpty, normalized.count <= 16 else {
      throw RelayFailure("請提供 1 至 16 個連線位址，每行一個")
    }
    var result = self
    result.name = label
    result.endpoints = normalized
    return result
  }
  public var credentialKey: String { id + "." + clientID }
}

public struct Target: Codable, Identifiable, Sendable {
  public var id = ""
  public var name = ""
  public var `protocol` = "nfs"
  public var host = ""
  public var share = ""
  public var export = "/"
  public var nfs_version = "4.2"
  public var username: String? = nil
  public var domain: String? = nil
  public var default_folder = ""
  public var has_credentials = false
  public var enabled = true
  public init() {}
}
public struct TargetInput: Encodable, Sendable {
  public let id, name, `protocol`, host, share, export, nfs_version: String
  public let username, domain, default_folder: String
  public let has_credentials, enabled: Bool
  public let password: String?
  public init(target: Target, password: String?) {
    id = target.id
    name = target.name
    `protocol` = target.protocol
    host = target.host
    share = target.share
    export = target.export
    nfs_version = target.nfs_version
    username = target.username ?? ""
    domain = target.domain ?? ""
    default_folder = target.default_folder
    has_credentials = target.has_credentials
    enabled = target.enabled
    self.password = password
  }
}
public struct ServerInfo: Decodable, Sendable {
  public let server_id, name, version, role, client_id, default_target, default_folder: String
  public let endpoints: [String]
  public let free_bytes, reserve_bytes, chunk_size: Int64
}
public struct Ping: Decodable, Sendable {
  public let server_id, name, version, client_id, role: String
}
public struct ServerJob: Codable, Identifiable, Sendable {
  public let id, owner, name, target_id, folder, manifest_sha256, stage, action: String
  public let accepted: Bool
  public let bytes, bytes_done, bytes_total, created, updated: Int64
  public let speed_bps: Double
  public let eta_seconds: Double?
  public let error: String?
  public let resume_stage: String?
  public let retry_at: Int64?
  public let archive_name: String?
  public let relay_clean: Bool?
  public let nas_clean: Bool?
  public let cleanup_error: String?
}
public struct ManifestEntry: Codable, Sendable {
  public var path, type: String
  public var size: Int64
  public var sha256: String
  public var mtime: Int64
  public var metadata: [String: String]?
  public init(
    path: String, type: String, size: Int64 = 0, sha256: String = "", mtime: Int64 = 0,
    metadata: [String: String]? = nil
  ) {
    self.path = path
    self.type = type
    self.size = size
    self.sha256 = sha256
    self.mtime = mtime
    self.metadata = metadata
  }
}
public struct PreflightReply: Decodable, Sendable { public let exists: Bool }
public struct Manifest: Codable, Sendable {
  public var id, name, target_id, folder: String
  public var entries: [ManifestEntry]
  public var collision_policy: String?
  public init(id: String, name: String, targetID: String, folder: String, entries: [ManifestEntry])
  {
    self.id = id
    self.name = name
    target_id = targetID
    self.folder = folder
    self.entries = entries
  }
  public var bytes: Int64 { entries.reduce(0) { $0 + ($1.type == "file" ? $1.size : 0) } }
}
public struct UploadStatus: Decodable, Sendable {
  public struct Offset: Decodable, Sendable {
    public let index: Int
    public let offset, size: Int64
  }
  public let files: [Offset]
  public let job: ServerJob
}
public struct OffsetReply: Decodable, Sendable { public let offset: Int64 }
public struct OKReply: Decodable, Sendable { public let ok: Bool }
public struct TargetTest: Decodable, Sendable {
  public let ok: Bool
  public let free_bytes: Int64
  public let latency_ms: Double
  public let `protocol`: String
}
public struct ClientIdentity: Decodable, Identifiable, Sendable {
  public let id, name, role: String
  public let revoked: Bool
  public let created: Int64
}
public struct Invitation: Decodable, Sendable {
  public let connection: ConnectionInfo
  public let uri: String
}

public struct LocalTask: Codable, Identifiable, Sendable {
  public var id, name, source: String
  public var bookmark: Data?
  public var serverID, targetID, folder: String
  public var state = "queued"
  public var bytes: Int64 = 0
  public var uploaded: Int64 = 0
  public var preparationDone: Int64 = 0
  public var speed: Double = 0
  public var eta: Double?
  public var message: String?
  public var pendingAction: String?
  public var duplicateChoice: String?
  public var accepted = false
  public var remote: ServerJob?
  public var created = Date().timeIntervalSince1970
  public init(
    id: String, name: String, source: String, bookmark: Data?, serverID: String, targetID: String,
    folder: String
  ) {
    self.id = id
    self.name = name
    self.source = source
    self.bookmark = bookmark
    self.serverID = serverID
    self.targetID = targetID
    self.folder = folder
  }
  public var uploadFraction: Double {
    if accepted { return 1 }
    guard bytes > 0 else { return 0 }
    return min(1, max(0, Double(uploaded) / Double(bytes)))
  }
  public var finished: Bool {
    if let remote, ["completed", "cancelled"].contains(remote.stage) {
      return remote.relay_clean != false && remote.nas_clean != false
    }
    return state == "cancelled" && remote == nil
  }
}
public struct RelayFailure: Error, LocalizedError, Sendable {
  public let message: String
  public let status: Int
  public init(_ message: String, status: Int = 0) {
    self.message = message
    self.status = status
  }
  public var errorDescription: String? { message }
}

public struct TransferMeter: Sendable {
  private var samples: [(Double, Int64)]
  public init(time: Double, bytes: Int64) { samples = [(time, bytes)] }
  public mutating func sample(time: Double, bytes: Int64, total: Int64) -> (
    speed: Double, eta: Double?
  ) {
    if let last = samples.last, time <= last.0 || bytes < last.1 { return (0, nil) }
    samples.append((time, bytes))
    while samples.count > 2 && time - samples[1].0 > 10 { samples.removeFirst() }
    guard let first = samples.first, time - first.0 > 0 else { return (0, nil) }
    let speed = Double(bytes - first.1) / (time - first.0)
    return (speed, speed > 0 && total > bytes ? Double(total - bytes) / speed : nil)
  }
}
public enum Routing {
  public static func nearest(_ measurements: [String: Double], manual: String? = nil) -> String? {
    if let manual { return measurements[manual] != nil ? manual : nil }
    return measurements.filter { $0.value.isFinite && $0.value >= 0 }.min { a, b in
      a.value == b.value ? a.key < b.key : a.value < b.value
    }?.key
  }
  public static func safeFolder(_ value: String) -> Bool {
    if value.isEmpty { return true }
    return !value.hasPrefix("/") && !value.contains("\\") && !value.contains("\0")
      && !value.contains("\n") && !value.contains("\r")
      && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.lowercased().hasPrefix(".nas-relay")
          && $0.lowercased() != ".relay-partial"
      }
  }
}
