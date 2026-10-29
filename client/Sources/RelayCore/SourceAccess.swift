import Foundation

/// Source errors must distinguish missing media from macOS privacy / filesystem failures.
public enum SourceAccess {
  public static func resolve(path: String, bookmark: Data?) -> URL {
    if let bookmark {
      // Finder can supply ordinary bookmarks as well as app-scoped bookmarks.
      for options: URL.BookmarkResolutionOptions in [
        [.withSecurityScope, .withoutUI, .withoutMounting], [.withoutUI, .withoutMounting],
      ] {
        var stale = false
        if let url = try? URL(
          resolvingBookmarkData: bookmark, options: options,
          relativeTo: nil, bookmarkDataIsStale: &stale)
        {
          return url
        }
      }
    }
    return URL(fileURLWithPath: path)
  }

  public static func check(_ url: URL) throws {
    do { _ = try FileManager.default.attributesOfItem(atPath: url.path) } catch {
      throw failure(error, url: url)
    }
  }

  public static func failure(_ error: Error, url: URL) -> RelayFailure {
    let ns = error as NSError
    var errors = [ns]
    var next = ns
    for _ in 0..<5 {
      guard let underlying = next.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
      errors.append(underlying)
      next = underlying
    }
    let denied = errors.contains {
      ($0.domain == NSPOSIXErrorDomain && [1, 13].contains($0.code))
        || ($0.domain == NSCocoaErrorDomain && $0.code == NSFileReadNoPermissionError)
    }
    let missing = errors.contains {
      ($0.domain == NSPOSIXErrorDomain && [2, 6, 19].contains($0.code))
        || ($0.domain == NSCocoaErrorDomain
          && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains($0.code))
    }
    let reason =
      denied
      ? "macOS 未允許讀取素材。請按「重新選取來源…」授權；並確認系統設定 → 隱私權與安全性 → 檔案與檔案夾的卸除式卷宗權限。"
      : missing
        ? "來源目前無法存取。請接回硬碟；若位置已變更，請按「重新選取來源…」。"
        : "讀取來源失敗，請確認硬碟連線並重試。"
    let temporary =
      missing || errors.contains { $0.domain == NSPOSIXErrorDomain && [5, 60].contains($0.code) }
    return RelayFailure(
      "\(reason)\n\(url.path)\n\(ns.domain) \(ns.code)：\(ns.localizedDescription)",
      retryable: !denied && temporary)
  }

  /// A short successful read is not EOF. Accumulate until the requested chunk is full.
  public static func readChunk(at url: URL, offset: Int64, count: Int) throws -> Data {
    do {
      let gate = try SourceReadProtection.gate(for: url)
      try gate?.pace(bytes: count)
      return try autoreleasepool {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try SourceReadProtection.configure(input, url: url, gate: gate)
        try input.seek(toOffset: UInt64(offset))
        return try readExactly(count: count) { try input.read(upToCount: $0) }
      }
    } catch is CancellationError { throw CancellationError() } catch let failure as RelayFailure {
      throw failure
    } catch { throw failure(error, url: url) }
  }
  static func readExactly(count: Int, read: (Int) throws -> Data?) throws -> Data {
    var data = Data()
    while data.count < count {
      try Task.checkCancellation()
      guard let part = try read(count - data.count), !part.isEmpty else {
        throw RelayFailure("來源檔案變短，請確認素材複製完成後再重試")
      }
      data.append(part)
    }
    return data
  }
}
