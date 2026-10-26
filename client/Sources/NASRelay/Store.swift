import AppKit
import RelayCore
import SwiftUI

struct ServerHealth: Sendable {
  var endpoint: String
  var latency: Double
  var info: ServerInfo
  var targets: [Target]
  var jobs: [ServerJob]
}
private struct PollResult: Sendable {
  let id: String
  let health: ServerHealth?
  let error: String?
}

private final class ProgressGate: @unchecked Sendable {
  private let lock = NSLock()
  private var last: Double = 0
  func allows(_ done: Int64, _ total: Int64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let now = ProcessInfo.processInfo.systemUptime
    if now - last < 0.2 && done < total { return false }
    last = now
    return true
  }
}

@MainActor
final class Store: ObservableObject {
  @Published var profiles: [ServerProfile] = []
  @Published var health: [String: ServerHealth] = [:]
  @Published var connectionErrors: [String: String] = [:]
  @Published var tasks: [LocalTask] = []
  @Published var route = "auto"
  @Published var error: String?
  @Published var refreshing = false
  private var apis: [String: RelayAPI] = [:]
  private var running: [String: Task<Void, Never>] = [:]
  private var resources: [String: URL] = [:]
  private var retries: [String: Date] = [:]
  private var meters: [String: TransferMeter] = [:]
  private var lastProgress: [String: Date] = [:]
  private var controlling = Set<String>()
  private var lastProbe = Date.distantPast
  private var poller: Task<Void, Never>?
  private var selectionPanel: NSOpenPanel?
  let root: URL

  init() {
    root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/NASRelay")
    do {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("tasks"), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      if let data = try? Data(contentsOf: root.appendingPathComponent("profiles.json")) {
        profiles = try JSONDecoder().decode([ServerProfile].self, from: data)
      }
      if let data = try? Data(contentsOf: root.appendingPathComponent("route.json")),
        let saved = try? JSONDecoder().decode(String.self, from: data)
      {
        route = saved
      }
      let folders =
        (try? FileManager.default.contentsOfDirectory(
          at: root.appendingPathComponent("tasks"), includingPropertiesForKeys: nil)) ?? []
      tasks = folders.compactMap {
        try? JSONDecoder().decode(
          LocalTask.self, from: Data(contentsOf: $0.appendingPathComponent("task.json")))
      }.sorted { $0.created > $1.created }
      for i in tasks.indices
      where !tasks[i].accepted
        && ["preparing", "uploading", "checking_source", "checking_destination"].contains(
          tasks[i].state)
      {
        tasks[i].state = "queued"
        tasks[i].speed = 0
        tasks[i].eta = nil
      }
    } catch { self.error = error.localizedDescription }
    poller = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.refresh()
        self.startPending()
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }
  var activeServer: String? {
    let values = Dictionary(uniqueKeysWithValues: health.map { ($0.key, $0.value.latency) })
    return Routing.nearest(values, manual: route == "auto" ? nil : route)
  }
  var selectedProfile: ServerProfile? { profiles.first { $0.id == activeServer } }
  var pendingLocal: Int { tasks.filter { !$0.accepted && !$0.finished }.count }
  func persistProfiles() {
    do {
      try save(profiles, to: root.appendingPathComponent("profiles.json"))
      try save(route, to: root.appendingPathComponent("route.json"))
    } catch { self.error = error.localizedDescription }
  }
  private func save<T: Encodable>(_ value: T, to: URL) throws {
    let data = try JSONEncoder().encode(value)
    try data.write(to: to, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to.path)
  }
  private func directory(_ id: String) -> URL { root.appendingPathComponent("tasks/" + id) }
  private func update(_ id: String, _ change: (inout LocalTask) -> Void) {
    guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
    change(&tasks[i])
    do {
      try FileManager.default.createDirectory(
        at: directory(id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
      )
      try save(tasks[i], to: directory(id).appendingPathComponent("task.json"))
    } catch { self.error = error.localizedDescription }
  }
  private func api(_ id: String) throws -> RelayAPI {
    if let existing = apis[id] { return existing }
    guard let profile = profiles.first(where: { $0.id == id }) else {
      throw RelayFailure("中繼設定已移除")
    }
    let value = RelayAPI(profile: profile, token: try CredentialVault.get(profile.credentialKey))
    apis[id] = value
    return value
  }
  func importConnection(_ text: String) throws {
    let info = try ConnectionInfo.parse(text)
    let profile = ServerProfile(info)
    try CredentialVault.set(info.token, key: profile.credentialKey)
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      guard
        !tasks.contains(where: { $0.serverID == profile.id && !$0.finished && $0.accepted })
          || profiles[index].clientID == profile.clientID
      else { throw RelayFailure("此中繼仍有目前用戶端的任務，請完成後再改用另一個身分") }
      apis[profile.id]?.close()
      apis.removeValue(forKey: profile.id)
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
    persistProfiles()
    lastProbe = .distantPast
    Task { await refresh() }
  }
  func removeProfile(_ id: String) {
    guard !tasks.contains(where: { $0.serverID == id && !$0.finished }) else {
      error = "此中繼仍有未完成任務"
      return
    }
    if let p = profiles.first(where: { $0.id == id }) { CredentialVault.remove(p.credentialKey) }
    apis[id]?.close()
    apis.removeValue(forKey: id)
    profiles.removeAll { $0.id == id }
    health.removeValue(forKey: id)
    if route == id { route = "auto" }
    persistProfiles()
  }

  func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    let probe = Date().timeIntervalSince(lastProbe) > 15
    var candidates: [(ServerProfile, RelayAPI, ServerHealth?)] = []
    for profile in profiles {
      do { candidates.append((profile, try api(profile.id), health[profile.id])) } catch {
        connectionErrors[profile.id] = error.localizedDescription
      }
    }
    let results = await withTaskGroup(of: PollResult.self, returning: [PollResult].self) { group in
      for (profile, api, previous) in candidates {
        group.addTask {
          do {
            let endpoint: String
            let latency: Double
            if probe || previous == nil {
              let samples = await withTaskGroup(
                of: (String, Double)?.self, returning: [(String, Double)].self
              ) { pings in
                for ep in profile.endpoints {
                  pings.addTask {
                    do {
                      var times: [Double] = []
                      for _ in 0..<3 {
                        let start = ContinuousClock.now
                        let ping: Ping = try await api.get(
                          "v1/ping", endpoint: ep, as: Ping.self, timeout: 8)
                        guard ping.server_id == profile.id && ping.client_id == profile.clientID
                        else { throw RelayFailure("伺服器身分不符") }
                        let elapsed = start.duration(to: .now)
                        times.append(
                          Double(elapsed.components.seconds) * 1000 + Double(
                            elapsed.components.attoseconds) / 1e15)
                      }
                      return (ep, times.sorted()[1])
                    } catch { return nil }
                  }
                }
                var output: [(String, Double)] = []
                for await result in pings { if let result { output.append(result) } }
                return output
              }
              guard let fastest = samples.min(by: { $0.1 < $1.1 }) else {
                if let first = profile.endpoints.first {
                  _ = try await api.get("v1/ping", endpoint: first, as: Ping.self, timeout: 8)
                }
                throw RelayFailure("無法連接此中繼的任何位址")
              }
              endpoint = fastest.0
              latency = fastest.1
            } else {
              endpoint = previous!.endpoint
              latency = previous!.latency
            }
            async let info: ServerInfo = api.get("v1/info", endpoint: endpoint, as: ServerInfo.self)
            async let targets: [Target] = api.get(
              "v1/targets", endpoint: endpoint, as: [Target].self)
            async let jobs: [ServerJob] = api.get(
              "v1/jobs", endpoint: endpoint, as: [ServerJob].self)
            return try await PollResult(
              id: profile.id,
              health: ServerHealth(
                endpoint: endpoint, latency: latency, info: info, targets: targets, jobs: jobs),
              error: nil)
          } catch {
            return PollResult(id: profile.id, health: nil, error: error.localizedDescription)
          }
        }
      }
      var out: [PollResult] = []
      for await r in group { out.append(r) }
      return out
    }
    if probe { lastProbe = Date() }
    for result in results {
      if let value = result.health {
        health[result.id] = value
        connectionErrors.removeValue(forKey: result.id)
        for remote in value.jobs {
          guard let local = tasks.first(where: { $0.id == remote.id }) else { continue }
          update(remote.id) { t in
            t.remote = remote
            t.accepted = remote.accepted
            if remote.stage == "completed" {
              t.state = "completed"
              t.speed = 0
              t.eta = nil
              t.message = nil
            } else if remote.stage == "cancelled" {
              t.state = "cancelled"
              t.speed = 0
              t.eta = nil
            } else if local.state == "cancelled" || local.state == "cancelling" {
              t.pendingAction = "cancel"
              t.state = "cancelling"
            } else if local.state == "paused" && !local.accepted && remote.action == "running" {
              t.pendingAction = "pause"
            } else if t.pendingAction != nil {
              // Keep an undelivered control request visible until acknowledged.
            } else if remote.action == "paused" {
              t.state = "paused"
              t.speed = 0
              t.eta = nil
            } else if remote.accepted && !["paused", "cancelling"].contains(t.state) {
              t.state = "handed_off"
              t.uploaded = t.bytes
              t.speed = 0
              t.eta = nil
            } else if !remote.accepted && remote.stage == "failed" && local.state != "preparing" {
              t.state = "error"
              t.message = remote.error
            }
          }
        }
      } else {
        health.removeValue(forKey: result.id)
        connectionErrors[result.id] = result.error
      }
    }
    for item in tasks where item.pendingAction != nil && health[item.serverID] != nil {
      if let action = item.pendingAction { await control(item.id, action) }
    }
  }
  func targetID(_ server: String) -> String {
    profiles.first { $0.id == server }?.preferredTarget ?? health[server]?.info.default_target ?? ""
  }
  func folder(_ server: String) -> String {
    if let value = profiles.first(where: { $0.id == server })?.preferredFolder { return value }
    if let info = health[server]?.info, !info.default_folder.isEmpty { return info.default_folder }
    return health[server]?.targets.first { $0.id == targetID(server) }?.default_folder ?? ""
  }
  func setTarget(_ value: String, server: String) {
    if let i = profiles.firstIndex(where: { $0.id == server }) {
      profiles[i].preferredTarget = value
      profiles[i].preferredFolder = nil
      persistProfiles()
    }
  }
  func setFolder(_ value: String, server: String) {
    if let i = profiles.firstIndex(where: { $0.id == server }) {
      profiles[i].preferredFolder = value
      persistProfiles()
    }
  }
  func choose() {
    guard selectionPanel == nil, let server = activeServer else { return }
    let chosenTarget = targetID(server)
    let chosenFolder = folder(server)
    let panel = NSOpenPanel()
    selectionPanel = panel
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.prompt = "加入歸檔"
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self else { return }
      self.selectionPanel = nil
      if response == .OK {
        self.add(panel.urls, server: server, target: chosenTarget, folder: chosenFolder)
      }
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }
  func add(
    _ urls: [URL], server chosenServer: String? = nil, target chosenTarget: String? = nil,
    folder chosenFolder: String? = nil
  ) {
    guard let server = chosenServer ?? activeServer, let h = health[server] else {
      error = "請先連接可用的中繼伺服器"
      return
    }
    let target = chosenTarget ?? targetID(server)
    let subfolder = chosenFolder ?? folder(server)
    guard h.targets.contains(where: { $0.id == target && $0.enabled }) else {
      error = "請先設定此中繼的 NAS 目標"
      return
    }
    guard Routing.safeFolder(subfolder) else {
      error = "預設歸檔資料夾必須是相對路徑"
      return
    }
    for url in urls {
      let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      if url.startAccessingSecurityScopedResource() { resources[id] = url }
      let bookmark = try? url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      let task = LocalTask(
        id: id, name: url.lastPathComponent, source: url.path, bookmark: bookmark, serverID: server,
        targetID: target, folder: subfolder)
      tasks.insert(task, at: 0)
      update(id) { _ in }
    }
    error = nil
    startPending()
  }
  private func source(_ task: LocalTask) throws -> URL {
    if let existing = resources[task.id] { return existing }
    var stale = false
    let url: URL
    if let data = task.bookmark {
      url =
        (try? URL(
          resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
          bookmarkDataIsStale: &stale)) ?? URL(fileURLWithPath: task.source)
    } else {
      url = URL(fileURLWithPath: task.source)
    }
    if url.startAccessingSecurityScopedResource() { resources[task.id] = url }
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw RelayFailure("找不到原始素材，請接回磁碟或重新加入")
    }
    return url
  }
  private func startPending() {
    guard running.count < 2 else { return }
    for task in tasks.reversed()
    where !task.accepted && ["queued", "retry_pending"].contains(task.state)
      && running[task.id] == nil && (retries[task.id] ?? .distantPast) <= Date()
    {
      guard health[task.serverID] != nil else { continue }
      let id = task.id
      running[id] = Task { [weak self] in
        guard let self else { return }
        defer { self.running.removeValue(forKey: id) }
        do { try await self.run(id) } catch is CancellationError {} catch {
          if self.tasks.first(where: { $0.id == id })?.state != "paused"
            && self.tasks.first(where: { $0.id == id })?.state != "cancelled"
          {
            let failure = error as? RelayFailure
            let retry =
              (error is URLError || failure?.status == 500 || failure?.status == 503
                || failure?.status == 507)
            self.update(id) { t in
              t.state = retry ? "retry_pending" : "error"
              t.message = error.localizedDescription
              t.speed = 0
              t.eta = nil
            }
            self.retries[id] = Date().addingTimeInterval(20)
          }
        }
      }
      if running.count >= 2 { break }
    }
  }
  private func run(_ id: String) async throws {
    guard let item = tasks.first(where: { $0.id == id }), let health = health[item.serverID] else {
      throw RelayFailure("中繼未連線")
    }
    let api = try api(item.serverID)
    let endpoint = health.endpoint
    var existing: ServerJob?
    do {
      existing = try await api.get("v1/jobs/" + id, endpoint: endpoint, as: ServerJob.self)
    } catch { if (error as? RelayFailure)?.status != 404 { throw error } }
    if let remote = existing, remote.accepted {
      update(id) {
        $0.accepted = true
        $0.remote = remote
        $0.state = remote.stage == "completed" ? "completed" : "handed_off"
      }
      return
    }
    if existing == nil && item.duplicateChoice == nil {
      update(id) { $0.state = "checking_destination" }
      let body = try JSONSerialization.data(withJSONObject: [
        "name": item.name, "target_id": item.targetID, "folder": item.folder,
      ])
      // This early check is advisory. An unavailable NAS must not prevent relay handoff.
      if let reply: PreflightReply = try? await api.send(
        "v1/preflight", body: body, endpoint: endpoint, as: PreflightReply.self, timeout: 5),
        reply.exists
      {
        update(id) {
          $0.state = "awaiting_duplicate_local"
          $0.message = nil
        }
        return
      }
    }
    let url = try source(item)
    let manifestURL = directory(id).appendingPathComponent("manifest.json")
    var manifest: Manifest
    update(id) {
      $0.state = "preparing"
      $0.message = nil
      $0.preparationDone = 0
    }
    let preparingGate = ProgressGate()
    let progress: @Sendable (Int64, Int64) -> Void = { [weak self] done, total in
      guard preparingGate.allows(done, total) else { return }
      Task { @MainActor in
        guard let self, self.tasks.first(where: { $0.id == id })?.state == "preparing" else {
          return
        }
        self.update(id) {
          $0.preparationDone = done
          $0.bytes = total
        }
      }
    }
    if let data = try? Data(contentsOf: manifestURL) {
      manifest = try JSONDecoder().decode(Manifest.self, from: data)
      let existing = manifest
      let work = Task.detached {
        try ManifestBuilder.verify(source: url, manifest: existing, progress: progress)
      }
      try await withTaskCancellationHandler(
        operation: { try await work.value }, onCancel: { work.cancel() })
    } else {
      let work = Task.detached {
        try ManifestBuilder.build(
          source: url, id: id, targetID: item.targetID, folder: item.folder, progress: progress)
      }
      manifest = try await withTaskCancellationHandler(
        operation: { try await work.value }, onCancel: { work.cancel() })
      try save(manifest, to: manifestURL)
    }
    try Task.checkCancellation()
    if existing == nil {
      manifest.collision_policy = item.duplicateChoice
      try save(manifest, to: manifestURL)
    }
    update(id) { $0.bytes = manifest.bytes }
    var remote: ServerJob = try await api.send(
      "v1/jobs", body: JSONEncoder().encode(manifest), endpoint: endpoint, as: ServerJob.self)
    if remote.accepted {
      update(id) {
        $0.accepted = true
        $0.remote = remote
        $0.state = "handed_off"
      }
      return
    }
    if remote.action == "paused" {
      remote = try await api.send(
        "v1/jobs/" + id + "/resume", endpoint: endpoint, as: ServerJob.self)
    }
    if remote.stage == "verifying_receive" {
      update(id) {
        $0.state = "verifying_receive"
        $0.remote = remote
      }
      return
    }
    guard remote.stage == "receiving" else {
      throw RelayFailure(remote.error ?? "此任務已停止接收資料", status: 409)
    }
    let status: UploadStatus = try await api.get(
      "v1/jobs/" + id + "/upload", endpoint: endpoint, as: UploadStatus.self)
    var completed = status.files.reduce(Int64(0)) { $0 + $1.offset }
    meters[id] = TransferMeter(time: Date().timeIntervalSinceReferenceDate, bytes: completed)
    update(id) {
      $0.state = "uploading"
      $0.uploaded = completed
      $0.speed = 0
      $0.eta = nil
    }
    for file in status.files {
      let entry = manifest.entries[file.index]
      let path = url.deletingLastPathComponent().appendingPathComponent(entry.path)
      var offset = file.offset
      while offset < file.size {
        try Task.checkCancellation()
        let amount = Int(min(health.info.chunk_size, file.size - offset))
        let readOffset = offset
        let chunk = try await Task.detached {
          let input = try FileHandle(forReadingFrom: path)
          defer { try? input.close() }
          try input.seek(toOffset: UInt64(readOffset))
          guard let bytes = try input.read(upToCount: amount), bytes.count == amount else {
            throw RelayFailure("來源檔案變短或無法讀取")
          }
          return bytes
        }.value
        try Task.checkCancellation()
        let baseline = completed
        let total = manifest.bytes
        let result = try await api.upload(
          jobID: id, index: file.index, offset: offset, data: chunk, endpoint: endpoint
        ) { [weak self] bytes in
          Task { @MainActor in
            guard let self, self.tasks.first(where: { $0.id == id })?.state == "uploading",
              Date().timeIntervalSince(self.lastProgress[id] ?? .distantPast) > 0.25
                || baseline + bytes >= total
            else { return }
            self.lastProgress[id] = Date()
            let done = min(total, baseline + bytes)
            var m =
              self.meters[id]
              ?? TransferMeter(time: Date().timeIntervalSinceReferenceDate, bytes: baseline)
            let rate = m.sample(
              time: Date().timeIntervalSinceReferenceDate, bytes: done, total: total)
            self.meters[id] = m
            self.update(id) {
              $0.uploaded = done
              $0.speed = rate.speed
              $0.eta = rate.eta
            }
          }
        }
        guard result == offset + Int64(chunk.count) else { throw RelayFailure("伺服器分塊確認位移不符") }
        offset = result
        completed += Int64(chunk.count)
        var meter =
          meters[id] ?? TransferMeter(time: Date().timeIntervalSinceReferenceDate, bytes: completed)
        let measurement = meter.sample(
          time: Date().timeIntervalSinceReferenceDate, bytes: completed, total: manifest.bytes)
        meters[id] = meter
        update(id) {
          $0.uploaded = completed
          $0.speed = measurement.speed
          $0.eta = measurement.eta
        }
      }
    }
    update(id) {
      $0.state = "checking_source"
      $0.preparationDone = 0
      $0.speed = 0
      $0.eta = nil
    }
    let owner = self
    let checkingGate = ProgressGate()
    let check = Task.detached {
      try ManifestBuilder.verify(source: url, manifest: manifest) { done, total in
        guard checkingGate.allows(done, total) else { return }
        Task { @MainActor in
          guard owner.tasks.first(where: { $0.id == id })?.state == "checking_source" else {
            return
          }
          owner.update(id) {
            $0.preparationDone = done
            $0.bytes = total
          }
        }
      }
    }
    try await withTaskCancellationHandler(
      operation: { try await check.value }, onCancel: { check.cancel() })
    try Task.checkCancellation()
    remote = try await api.send("v1/jobs/" + id + "/commit", endpoint: endpoint, as: ServerJob.self)
    update(id) {
      $0.state = "verifying_receive"
      $0.remote = remote
      $0.uploaded = $0.bytes
      $0.speed = 0
      $0.eta = nil
    }
  }
  func pause(_ id: String) {
    running[id]?.cancel()
    update(id) {
      $0.state = $0.accepted ? "pausing" : "paused"
      $0.pendingAction = "pause"
      $0.speed = 0
      $0.eta = nil
    }
    Task { await control(id, "pause") }
  }
  func resume(_ id: String) {
    update(id) {
      $0.pendingAction = "resume"
      $0.state = "resuming"
      $0.message = nil
    }
    Task {
      await control(id, "resume")
      retries.removeValue(forKey: id)
      startPending()
    }
  }
  func resolveDuplicate(_ id: String, keepBoth: Bool) {
    if tasks.first(where: { $0.id == id })?.state == "awaiting_duplicate_local" {
      update(id) {
        $0.duplicateChoice = keepBoth ? "keep-both" : "use-existing"
        $0.state = "queued"
        $0.message = nil
      }
      startPending()
      return
    }
    let action = keepBoth ? "keep-both" : "use-existing"
    update(id) {
      $0.pendingAction = action
      $0.state = "resuming"
      $0.message = nil
    }
    Task { await control(id, action) }
  }
  func cancel(_ id: String) {
    running[id]?.cancel()
    update(id) {
      $0.state = "cancelling"
      $0.pendingAction = "cancel"
      $0.speed = 0
      $0.eta = nil
    }
    Task {
      await control(id, "cancel")
    }
  }
  private func control(_ id: String, _ action: String) async {
    guard !controlling.contains(id) else { return }
    controlling.insert(id)
    defer { controlling.remove(id) }
    guard let item = tasks.first(where: { $0.id == id }), let h = health[item.serverID] else {
      update(id) { $0.message = "連線恢復後才能將控制指令送到中繼" }
      return
    }
    do {
      let remote: ServerJob = try await api(item.serverID).send(
        "v1/jobs/" + id + "/" + action, endpoint: h.endpoint, as: ServerJob.self)
      update(id) {
        $0.remote = remote
        $0.accepted = remote.accepted
        guard $0.pendingAction == action else { return }
        $0.pendingAction = nil
        $0.message = nil
        if remote.stage == "completed" {
          $0.state = "completed"
        } else if remote.stage == "cancelled" {
          $0.state = "cancelled"
        } else if action == "pause" {
          $0.state = remote.stage == "pausing" ? "pausing" : "paused"
        } else if action == "cancel" {
          $0.state = "cancelling"
        } else {
          $0.state =
            remote.accepted
            ? "handed_off" : remote.stage == "verifying_receive" ? "verifying_receive" : "queued"
        }
      }
    } catch {
      if (error as? RelayFailure)?.status == 409 {
        update(id) {
          $0.pendingAction = nil
          $0.message = error.localizedDescription
        }
      } else if (error as? RelayFailure)?.status == 404 {
        update(id) {
          guard $0.pendingAction == action else { return }
          $0.pendingAction = nil
          $0.message = nil
          $0.state = action == "cancel" ? "cancelled" : action == "pause" ? "paused" : "queued"
        }
      } else {
        update(id) { $0.message = error.localizedDescription }
      }
    }
  }
  func reroute(_ id: String, to server: String) {
    Task {
      guard let old = tasks.first(where: { $0.id == id }), !old.accepted, old.state == "paused",
        let h = health[old.serverID], let next = health[server]
      else {
        error = "請先暫停尚未交接的任務，並確認兩台中繼已連線"
        return
      }
      do {
        if let job: ServerJob = try? await api(old.serverID).get(
          "v1/jobs/" + id, endpoint: h.endpoint, as: ServerJob.self)
        {
          guard !job.accepted && job.action == "paused" else {
            throw RelayFailure("任務已交接或尚未暫停，不能切換中繼")
          }
          let _: ServerJob = try await api(old.serverID).send(
            "v1/jobs/" + id + "/cancel", endpoint: h.endpoint, as: ServerJob.self)
        }
        let target = targetID(server)
        guard next.targets.contains(where: { $0.id == target && $0.enabled }) else {
          throw RelayFailure("新中繼未設定預設 NAS")
        }
        update(id) { $0.state = "cancelled" }
        let newID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let new = LocalTask(
          id: newID, name: old.name, source: old.source, bookmark: old.bookmark, serverID: server,
          targetID: target, folder: folder(server))
        tasks.insert(new, at: 0)
        update(newID) { _ in }
        startPending()
      } catch { self.error = error.localizedDescription }
    }
  }
  func saveTarget(_ input: TargetInput, server: String) async throws -> Target {
    guard let h = health[server] else { throw RelayFailure("中繼未連線") }
    let path = input.id.isEmpty ? "v1/targets" : "v1/targets/" + input.id
    let result: Target = try await api(server).send(
      path, method: input.id.isEmpty ? "POST" : "PUT", body: JSONEncoder().encode(input),
      endpoint: h.endpoint, as: Target.self)
    await refresh()
    return result
  }
  func testTarget(_ target: Target, server: String) async throws -> TargetTest {
    guard let h = health[server] else { throw RelayFailure("中繼未連線") }
    return try await api(server).send(
      "v1/targets/" + target.id + "/test", endpoint: h.endpoint, as: TargetTest.self)
  }
  func deleteTarget(_ target: Target, server: String) async throws {
    guard let h = health[server] else { throw RelayFailure("中繼未連線") }
    let _: OKReply = try await api(server).send(
      "v1/targets/" + target.id, method: "DELETE", endpoint: h.endpoint, as: OKReply.self)
    await refresh()
  }
  func defaults(server: String, target: String, folder: String) async throws {
    guard let h = health[server], Routing.safeFolder(folder) else {
      throw RelayFailure("中繼未連線或資料夾路徑不正確")
    }
    let body = try JSONSerialization.data(withJSONObject: [
      "default_target": target, "default_folder": folder,
    ])
    let _: OKReply = try await api(server).send(
      "v1/settings", method: "PUT", body: body, endpoint: h.endpoint, as: OKReply.self)
    if let i = profiles.firstIndex(where: { $0.id == server }) {
      profiles[i].preferredTarget = nil
      profiles[i].preferredFolder = nil
      persistProfiles()
    }
    await refresh()
  }
  func invite(server: String, name: String, role: String) async throws -> Invitation {
    guard let h = health[server] else { throw RelayFailure("中繼未連線") }
    let data = try JSONSerialization.data(withJSONObject: ["name": name, "role": role])
    return try await api(server).send(
      "v1/clients", body: data, endpoint: h.endpoint, as: Invitation.self)
  }
  func stop() {
    poller?.cancel()
    for task in running.values { task.cancel() }
    for api in apis.values { api.close() }
    for url in resources.values { url.stopAccessingSecurityScopedResource() }
  }
}
