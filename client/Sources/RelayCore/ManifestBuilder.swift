import CryptoKit
import Darwin
import Foundation

public enum ManifestBuilder {
  private struct Signature: Equatable {
    let size: Int64
    let modified: Date
    let inode: UInt64
    let directory: Bool
  }
  private static func signature(_ url: URL) throws -> Signature {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let kind = attrs[.type] as? FileAttributeType
    guard kind == .typeDirectory || kind == .typeRegular else {
      throw RelayFailure("不支援符號連結或特殊檔案：\(url.lastPathComponent)")
    }
    return Signature(
      size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
      modified: attrs[.modificationDate] as? Date ?? .distantPast,
      inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
      directory: kind == .typeDirectory)
  }
  private static func listing(_ source: URL) throws -> [(String, URL, Signature)] {
    let selected = source.standardizedFileURL
    _ = try signature(selected)  // Reject a selected symlink, but allow symlinked parent folders.
    // URL's canonicalizer may keep /var while directory enumeration returns /private/var.
    guard let resolved = selected.path.withCString({ realpath($0, nil) }) else {
      throw RelayFailure("無法解析素材路徑")
    }
    let root = URL(fileURLWithPath: String(cString: resolved))
    free(resolved)
    let base = root.deletingLastPathComponent().path + "/"
    var values = [root]
    if try signature(root).directory {
      var failure: Error?
      guard
        let enumerator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: [], options: [],
          errorHandler: { _, err in
            failure = err
            return false
          })
      else { throw RelayFailure("無法讀取資料夾") }
      for case let url as URL in enumerator {
        try Task.checkCancellation()
        if url.lastPathComponent == ".DS_Store" { continue }
        values.append(url)
      }
      if let failure { throw failure }
    }
    var result: [(String, URL, Signature)] = []
    var names = Set<String>()
    for url in values.sorted(by: { $0.path < $1.path }) {
      guard url.path.hasPrefix(base) else { throw RelayFailure("素材路徑不正確") }
      let rel = String(url.path.dropFirst(base.count))
      guard Routing.safeFolder(rel) else { throw RelayFailure("素材使用了不支援的路徑：\(rel)") }
      let normalized = rel.precomposedStringWithCanonicalMapping.lowercased()
      guard names.insert(normalized).inserted else { throw RelayFailure("素材內有大小寫或 Unicode 重複名稱") }
      result.append((rel, url, try signature(url)))
    }
    return result
  }
  private static func digest(_ url: URL, progress: @Sendable (Int64) -> Void) throws -> String {
    let before = try signature(url)
    guard !before.directory else { throw RelayFailure("來源不是一般檔案") }
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    var hash = SHA256()
    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
      try Task.checkCancellation()
      hash.update(data: data)
      progress(Int64(data.count))
    }
    guard before == (try signature(url)) else {
      throw RelayFailure("素材在讀取期間變動：\(url.lastPathComponent)")
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private static func attributes(_ url: URL) throws -> [String: String]? {
    let size = url.path.withCString { listxattr($0, nil, 0, XATTR_NOFOLLOW) }
    guard size >= 0 else { throw RelayFailure("無法讀取素材擴充屬性") }
    if size == 0 { return nil }
    var names = [CChar](repeating: 0, count: size)
    let actual = url.path.withCString { path in
      names.withUnsafeMutableBufferPointer { listxattr(path, $0.baseAddress, size, XATTR_NOFOLLOW) }
    }
    guard actual >= 0 else { throw RelayFailure("素材擴充屬性已變動") }
    let keys = names.map { UInt8(bitPattern: $0) }.split(separator: 0).map {
      String(decoding: $0, as: UTF8.self)
    }
    var result: [String: String] = [:]
    for key in keys where key.hasPrefix("com.apple.") {
      let count = url.path.withCString { p in
        key.withCString { getxattr(p, $0, nil, 0, 0, XATTR_NOFOLLOW) }
      }
      guard count >= 0, count <= 16 * 1024 * 1024 else { throw RelayFailure("素材擴充屬性過大或無法讀取") }
      var bytes = [UInt8](repeating: 0, count: count)
      let read = url.path.withCString { p in
        key.withCString { k in
          bytes.withUnsafeMutableBytes { getxattr(p, k, $0.baseAddress, count, 0, XATTR_NOFOLLOW) }
        }
      }
      guard read == count else { throw RelayFailure("素材擴充屬性已變動") }
      result[key] = Data(bytes).base64EncodedString()
    }
    return result.isEmpty ? nil : result
  }
  public static func build(
    source: URL, id: String, targetID: String, folder: String,
    progress: @escaping @Sendable (Int64, Int64) -> Void
  ) throws -> Manifest {
    let before = try listing(source)
    let total = before.reduce(Int64(0)) { $0 + ($1.2.directory ? 0 : $1.2.size) }
    var completed: Int64 = 0
    var entries: [ManifestEntry] = []
    for (rel, url, sig) in before {
      try Task.checkCancellation()
      if sig.directory {
        entries.append(ManifestEntry(path: rel, type: "dir", metadata: try attributes(url)))
      } else {
        // Hashing runs on a detached task; the callback reports cumulative bytes.
        let counter = ByteCounter(completed)
        let hash = try digest(url) { delta in
          let done = counter.add(delta)
          progress(done, total)
        }
        completed = counter.value
        entries.append(
          ManifestEntry(
            path: rel, type: "file", size: sig.size, sha256: hash,
            mtime: Int64(sig.modified.timeIntervalSince1970 * 1000), metadata: try attributes(url)))
      }
    }
    let after = try listing(source)
    guard before.count == after.count,
      zip(before, after).allSatisfy({ $0.0.0 == $0.1.0 && $0.0.2 == $0.1.2 })
    else { throw RelayFailure("建立清單期間素材仍在變動，請複製完成後重試") }
    return Manifest(
      id: id, name: source.lastPathComponent, targetID: targetID, folder: folder, entries: entries)
  }
  public static func verify(
    source: URL, manifest: Manifest, progress: @escaping @Sendable (Int64, Int64) -> Void
  ) throws {
    let items = try listing(source)
    guard Set(items.map { $0.0 }) == Set(manifest.entries.map(\.path)) else {
      throw RelayFailure("原始素材清單已變動")
    }
    let expected = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.path, $0) })
    let counter = ByteCounter(0)
    for (rel, url, sig) in items {
      guard let e = expected[rel], (e.type == "dir") == sig.directory else {
        throw RelayFailure("素材型態已變動")
      }
      if !sig.directory {
        guard sig.size == e.size,
          try digest(url, progress: { delta in progress(counter.add(delta), manifest.bytes) })
            == e.sha256
        else { throw RelayFailure("原始素材內容已變動，請重新加入新版本") }
      }
    }
  }
}
private final class ByteCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count: Int64
  init(_ value: Int64) { count = value }
  func add(_ value: Int64) -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    count += value
    return count
  }
  var value: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
