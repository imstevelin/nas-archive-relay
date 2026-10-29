import Darwin
import Foundation

/// Protect local external volumes without slowing internal disks or NAS mounts.
public enum SourceReadProtection {
  public static let preferenceKey = "protectExternalSourceReads"
  public static let bytesPerSecond: Double = 24 * 1024 * 1024
  public static var enabled: Bool {
    UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
  }
  static func isExternalLocal(internalDisk: Bool?, local: Bool?) -> Bool {
    internalDisk == false && local == true
  }
  static func gate(for source: URL) throws -> SourceReadGate? {
    guard enabled else { return nil }
    let values: URLResourceValues
    do {
      values = try source.resourceValues(forKeys: [
        .volumeIsInternalKey, .volumeIsLocalKey, .volumeUUIDStringKey, .volumeURLKey,
      ])
    } catch { throw SourceAccess.failure(error, url: source) }
    guard isExternalLocal(internalDisk: values.volumeIsInternal, local: values.volumeIsLocal) else {
      return nil
    }
    let key = values.volumeUUIDString ?? values.volume?.path ?? source.path
    return SourceReadRegistry.shared.gate(for: key)
  }
  static func configure(_ input: FileHandle, url: URL, gate: SourceReadGate?) throws {
    guard gate != nil else { return }
    guard fcntl(input.fileDescriptor, F_NOCACHE, 1) == 0 else {
      throw SourceAccess.failure(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), url: url)
    }
  }
}

/// A single budget is shared by hashes, verification and upload reads of a volume.
final class SourceReadRegistry: @unchecked Sendable {
  static let shared = SourceReadRegistry()
  private let lock = NSLock()
  private var gates: [String: SourceReadGate] = [:]
  func gate(for key: String) -> SourceReadGate {
    lock.lock()
    defer { lock.unlock() }
    if let gate = gates[key] { return gate }
    let gate = SourceReadGate(bytesPerSecond: SourceReadProtection.bytesPerSecond)
    gates[key] = gate
    return gate
  }
}

final class SourceReadGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var preparing = false
  private var nextRead: Double = 0
  private let rate: Double
  init(bytesPerSecond: Double) { rate = bytesPerSecond }

  func acquirePreparation(waiting: @Sendable (Bool) -> Void) throws {
    var announced = false
    condition.lock()
    while preparing {
      if !announced {
        condition.unlock()
        waiting(true)
        announced = true
        condition.lock()
        continue
      }
      _ = condition.wait(until: Date().addingTimeInterval(0.05))
      do { try Task.checkCancellation() } catch {
        condition.unlock()
        throw error
      }
    }
    do { try Task.checkCancellation() } catch {
      condition.unlock()
      throw error
    }
    preparing = true
    condition.unlock()
    waiting(false)
  }
  func releasePreparation() {
    condition.lock()
    preparing = false
    condition.broadcast()
    condition.unlock()
  }
  func pace(bytes: Int) throws {
    try Task.checkCancellation()
    condition.lock()
    let now = ProcessInfo.processInfo.systemUptime
    let start = max(now, nextRead)
    nextRead = start + Double(bytes) / rate
    condition.unlock()
    while ProcessInfo.processInfo.systemUptime < start {
      try Task.checkCancellation()
      Thread.sleep(forTimeInterval: min(0.05, max(0, start - ProcessInfo.processInfo.systemUptime)))
    }
    try Task.checkCancellation()
  }
}
