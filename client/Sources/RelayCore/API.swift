import CryptoKit
import Foundation
import Security

public enum CredentialVault {
  private static let service = "net.imstevelin.NASRelay.credentials"
  public static func set(_ value: String, key: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    let data = Data(value.utf8)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw RelayFailure("無法更新鑰匙圈（\(status)）") }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess else { throw RelayFailure("無法儲存鑰匙圈（\(added)）") }
  }
  public static func get(_ key: String) throws -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: key, kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else { throw RelayFailure("鑰匙圈中沒有此中繼的連線憑證（\(status)）") }
    return value
  }
  public static func remove(_ key: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

private final class PinDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
  let profile: ServerProfile
  init(_ profile: ServerProfile) { self.profile = profile }
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      profile.endpoints.contains(where: { URL(string: $0)?.host == challenge.protectionSpace.host }
      ),
      let trust = challenge.protectionSpace.serverTrust,
      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
      ConnectionInfo.sha(SecCertificateCopyData(leaf) as Data) == profile.fingerprint.lowercased(),
      let data = Data(base64Encoded: profile.certificate),
      let anchor = SecCertificateCreateWithData(nil, data as CFData)
    else {
      NSLog(
        "NAS Relay TLS identity mismatch, host %@, method %@", challenge.protectionSpace.host,
        challenge.protectionSpace.authenticationMethod)
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust, true)
    SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString))
    var trustError: CFError?
    guard SecTrustEvaluateWithError(trust, &trustError) else {
      NSLog("NAS Relay TLS validation failed: %@", String(describing: trustError))
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
private final class UploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let progress: @Sendable (Int64) -> Void
  init(_ progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64
  ) { progress(totalBytesSent) }
}
public final class RelayAPI: @unchecked Sendable {
  private let session: URLSession
  private let token: String
  public let profile: ServerProfile
  public init(profile: ServerProfile, token: String) {
    self.profile = profile
    self.token = token
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 900
    config.httpMaximumConnectionsPerHost = 4
    config.urlCache = nil
    config.tlsMinimumSupportedProtocolVersion = .TLSv13
    session = URLSession(configuration: config, delegate: PinDelegate(profile), delegateQueue: nil)
  }
  private func request(_ endpoint: String, _ path: String, method: String, body: Data? = nil) throws
    -> URLRequest
  {
    guard profile.endpoints.contains(endpoint), let base = URL(string: endpoint) else {
      throw RelayFailure("不允許的中繼位址")
    }
    var req = URLRequest(url: base.appendingPathComponent(path))
    req.httpMethod = method
    req.httpBody = body
    req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return req
  }
  private func checked<T: Decodable>(_ data: Data, _ response: URLResponse, as: T.Type) throws -> T
  {
    guard let response = response as? HTTPURLResponse else { throw RelayFailure("無效的伺服器回覆") }
    guard (200..<300).contains(response.statusCode) else {
      let message =
        (try? JSONDecoder().decode([String: String].self, from: data)["error"])
        ?? "HTTP \(response.statusCode)"
      throw RelayFailure(message, status: response.statusCode)
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
  public func get<T: Decodable & Sendable>(
    _ path: String, endpoint: String, as: T.Type, timeout: Double = 15
  ) async throws -> T {
    var req = try request(endpoint, path, method: "GET")
    req.timeoutInterval = timeout
    let (data, response) = try await session.data(for: req)
    return try checked(data, response, as: T.self)
  }
  public func send<T: Decodable & Sendable>(
    _ path: String, method: String = "POST", body: Data? = nil, endpoint: String, as: T.Type,
    timeout: Double = 30
  ) async throws -> T {
    var req = try request(endpoint, path, method: method, body: body)
    req.timeoutInterval = timeout
    let (data, response) = try await session.data(for: req)
    return try checked(data, response, as: T.self)
  }
  public func upload(
    jobID: String, index: Int, offset: Int64, data: Data, endpoint: String,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> Int64 {
    var req = try request(endpoint, "v1/jobs/\(jobID)/files/\(index)", method: "PUT")
    req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    req.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
    req.setValue(ConnectionInfo.sha(data), forHTTPHeaderField: "X-Chunk-SHA256")
    let (body, response) = try await session.upload(
      for: req, from: data, delegate: UploadDelegate(progress))
    return try checked(body, response, as: OffsetReply.self).offset
  }
  public func close() { session.invalidateAndCancel() }
}
