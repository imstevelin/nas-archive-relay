import Foundation

/// Pure selection: never query an unresponsive volume on the main actor.
public enum SourceFaultPolicy {
  public static func shouldSuspend(_ task: LocalTask, after failed: LocalTask) -> Bool {
    guard !task.accepted, !task.finished,
      !["paused", "cancelling", "cancelled"].contains(task.state) else { return false }
    if task.id == failed.id { return true }
    if let a = task.sourceVolumeID, let b = failed.sourceVolumeID { return a == b }
    guard let a = externalMount(task.source), let b = externalMount(failed.source) else { return false }
    return a == b
  }
  private static func externalMount(_ path: String) -> String? {
    let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    guard parts.count > 2, parts[1] == "Volumes" else { return nil }
    return parts[2]
  }
}
