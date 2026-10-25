import AppKit
import RelayCore
import SwiftUI
import UniformTypeIdentifiers

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
func speed(_ n: Double) -> String { n > 0 ? bytes(Int64(n)) + "/s" : "—" }
func remaining(_ n: Double?) -> String {
  guard let n, n.isFinite, n >= 0 else { return "估算中" }
  if n < 60 { return "約 \(max(1,Int(n))) 秒" }
  if n < 3600 { return "約 \(Int(n/60)) 分" }
  return "約 \(Int(n/3600)) 小時 \(Int(n.truncatingRemainder(dividingBy:3600)/60)) 分"
}
func phase(_ value: String) -> String {
  [
    "queued": "等待歸檔", "receiving": "等待素材上傳", "preparing": "建立 SHA-256 清單", "uploading": "傳送素材",
    "checking_source": "確認原始素材", "verifying_receive": "中繼接收校驗", "handed_off": "已完整交接",
    "paused": "已暫停", "pausing": "正在暫停", "resuming": "正在恢復", "copying": "上傳 NAS",
    "checking_relay": "檢查中繼內容", "checking_existing": "比對 NAS 既有內容", "verifying_nas": "校驗 NAS 內容",
    "publishing": "發佈並作最終校驗", "completed": "歸檔完成", "cancelled": "已終止", "cancelling": "正在終止",
    "retry_pending": "等待自動重試", "failed": "需要處理", "error": "需要處理", "conflict": "同名內容衝突",
  ][value] ?? value
}

struct ImportView: View {
  @ObservedObject var store: Store
  @Environment(\.dismiss) var dismiss
  @State private var text = ""
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("連接中繼伺服器").font(.title2.bold())
      Text("貼上服務端提供的連線資訊，或選取連線 JSON 檔案。").foregroundStyle(.secondary)
      TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 150).padding(
        8
      ).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      Text("連線憑證會儲存在 macOS 鑰匙圈。").font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Button("匯入連線檔…") {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = false
          panel.allowedContentTypes = [.json, .plainText]
          if panel.runModal() == .OK, let url = panel.url {
            do { text = try String(contentsOf: url, encoding: .utf8) } catch {
              self.error = error.localizedDescription
            }
          }
        }
        Spacer()
        Button("取消") { dismiss() }
        Button("連接") {
          do {
            try store.importConnection(text)
            text = ""
            dismiss()
          } catch { self.error = error.localizedDescription }
        }.buttonStyle(.borderedProminent).disabled(
          text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 570)
  }
}
struct TargetEditor: View {
  @ObservedObject var store: Store
  let server: String
  @Environment(\.dismiss) var dismiss
  @State var target: Target
  @State private var password = ""
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(target.id.isEmpty ? "新增 NAS 目標" : "編輯 NAS 目標").font(.title2.bold())
      Form {
        TextField("名稱", text: $target.name)
        Picker("通訊協定", selection: $target.protocol) {
          Text("NFS").tag("nfs")
          Text("SMB").tag("smb")
        }.pickerStyle(.segmented)
        TextField("NAS 主機或 IP", text: $target.host)
        if target.protocol == "nfs" {
          TextField("NFS 匯出路徑", text: $target.export)
          Picker("NFS 版本", selection: $target.nfs_version) {
            Text("4.2（建議）").tag("4.2")
            Text("4.1").tag("4.1")
            Text("4.0").tag("4")
            Text("3").tag("3")
          }
        } else {
          TextField("SMB 共享名稱", text: $target.share)
          TextField(
            "帳號", text: Binding(get: { target.username ?? "" }, set: { target.username = $0 }))
          SecureField(target.has_credentials ? "密碼（留空沿用）" : "密碼", text: $password)
          TextField(
            "網域（可留空）", text: Binding(get: { target.domain ?? "" }, set: { target.domain = $0 }))
        }
        TextField("預設歸檔資料夾", text: $target.default_folder, prompt: Text("相對路徑；留空表示共享根目錄"))
        Toggle("啟用此目標", isOn: $target.enabled)
      }.formStyle(.grouped)
      if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        if busy { ProgressView().controlSize(.small) }
        Spacer()
        Button("取消") { dismiss() }.disabled(busy)
        Button("儲存") {
          busy = true
          Task {
            do {
              _ = try await store.saveTarget(
                TargetInput(target: target, password: password.isEmpty ? nil : password),
                server: server)
              password = ""
              dismiss()
            } catch {
              self.error = error.localizedDescription
              busy = false
            }
          }
        }.buttonStyle(.borderedProminent).disabled(
          busy || target.name.isEmpty || target.host.isEmpty
            || !Routing.safeFolder(target.default_folder))
      }
    }.padding(22).frame(width: 570)
  }
}
struct ServerManager: View {
  @ObservedObject var store: Store
  let server: String
  @Environment(\.dismiss) var dismiss
  @State private var edit: Target?
  @State private var add = false
  @State private var defaultTarget = ""
  @State private var defaultFolder = ""
  @State private var message: String?
  @State private var busy = false
  @State private var inviteName = ""
  @State private var inviteRole = "client"
  @State private var invitation: String?
  @State private var deleting: Target?
  var profile: ServerProfile? { store.profiles.first { $0.id == server } }
  var info: ServerHealth? { store.health[server] }
  var canManage: Bool { profile?.role == "admin" }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(profile?.name ?? "中繼設定").font(.title2.bold())
          Text(canManage ? "管理員連線" : "用戶端連線 · NAS 設定由管理員管理").font(.caption).foregroundStyle(
            .secondary)
        }
        Spacer()
        Button("完成") { dismiss() }
      }
      if let info {
        Label(info.endpoint + String(format: "  ·  %.1f ms", info.latency), systemImage: "network")
          .font(.caption).foregroundStyle(.secondary)
      }
      GroupBox("NAS 目標") {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(info?.targets ?? []) { target in
            HStack {
              Image(
                systemName: target.protocol == "smb"
                  ? "externaldrive.connected.to.line.below" : "externaldrive.badge.wifi"
              ).foregroundStyle(.tint)
              VStack(alignment: .leading) {
                Text(target.name).font(.headline)
                Text(
                  "\(target.protocol.uppercased()) · \(target.host) · \(target.protocol=="smb" ? target.share:target.export)"
                ).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if canManage {
                Button("測試") {
                  busy = true
                  Task {
                    do {
                      let result = try await store.testTarget(target, server: server)
                      message = "讀寫、校驗與發佈測試通過，可用 \(bytes(result.free_bytes))"
                    } catch { message = error.localizedDescription }
                    busy = false
                  }
                }.disabled(busy)
                Button("編輯") { edit = target }
                Button(role: .destructive) {
                  deleting = target
                } label: {
                  Image(systemName: "trash")
                }
              }
            }
          }
          if (info?.targets ?? []).isEmpty { Text("尚未設定 NAS").foregroundStyle(.secondary) }
          if canManage { Button("新增 NAS…", systemImage: "plus") { add = true } }
        }.padding(8)
      }
      GroupBox("服務端預設歸檔位置") {
        VStack(alignment: .leading, spacing: 10) {
          Picker("預設 NAS", selection: $defaultTarget) {
            Text("未設定").tag("")
            ForEach(info?.targets ?? []) { Text($0.name).tag($0.id) }
          }
          TextField("相對資料夾", text: $defaultFolder, prompt: Text("留空使用 NAS 目標的預設資料夾"))
          if canManage {
            Button("儲存預設") {
              busy = true
              Task {
                do {
                  try await store.defaults(
                    server: server, target: defaultTarget, folder: defaultFolder)
                  message = "預設位置已儲存"
                } catch { message = error.localizedDescription }
                busy = false
              }
            }.disabled(busy || !Routing.safeFolder(defaultFolder))
          }
        }.padding(8).disabled(!canManage)
      }
      if canManage {
        DisclosureGroup("讓其他用戶端連接此中繼") {
          VStack(alignment: .leading, spacing: 10) {
            TextField("用戶端名稱", text: $inviteName)
            Picker("權限", selection: $inviteRole) {
              Text("用戶端：上傳與管理自己的任務").tag("client")
              Text("管理員：也能設定 NAS 與用戶端").tag("admin")
            }
            Button("產生專屬連線資訊") {
              busy = true
              Task {
                do {
                  invitation = try await store.invite(
                    server: server, name: inviteName, role: inviteRole
                  ).uri
                  message = "已建立獨立用戶端憑證"
                } catch { message = error.localizedDescription }
                busy = false
              }
            }.disabled(inviteName.isEmpty || busy)
            if let invitation {
              Text("連線資訊只在此顯示；請交給指定使用者。").font(.caption).foregroundStyle(.secondary)
              Button("複製連線資訊") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(invitation, forType: .string)
              }
            }
          }.padding(.top, 8)
        }
      }
      if busy { ProgressView().controlSize(.small) }
      if let message { Text(message).font(.caption).textSelection(.enabled) }
    }.padding(22).frame(width: 700).onAppear {
      defaultTarget = info?.info.default_target ?? ""
      defaultFolder = info?.info.default_folder ?? ""
    }
    .sheet(item: $edit) { TargetEditor(store: store, server: server, target: $0) }.sheet(
      isPresented: $add
    ) { TargetEditor(store: store, server: server, target: Target()) }
    .alert(
      "移除 NAS 目標設定？",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    ) {
      Button("取消", role: .cancel) {}
      Button("移除設定", role: .destructive) {
        if let target = deleting {
          Task {
            do { try await store.deleteTarget(target, server: server) } catch {
              message = error.localizedDescription
            }
          }
        }
      }
    } message: {
      Text("已歸檔的 NAS 檔案會保留；仍有未完成任務時會拒絕移除。")
    }
  }
}

struct ProgressCard: View {
  let title, label: String
  let value: Double
  let rate: Double
  let eta: Double?
  let complete: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Spacer()
        if complete { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
      }
      ProgressView(value: min(1, max(0, value))).tint(complete ? .green : .accentColor)
      HStack {
        Text(label).lineLimit(1)
        Spacer()
        if !complete {
          Text(String(format: "%.0f%%", min(1, max(0, value)) * 100)).monospacedDigit()
        }
      }.font(.caption)
      if !complete {
        HStack {
          Text(speed(rate))
          Spacer()
          Text(remaining(eta))
        }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
      }
    }
  }
}
struct TaskRow: View {
  @ObservedObject var store: Store
  let task: LocalTask
  @State private var confirmCancel = false
  var remote: ServerJob? { task.remote }
  var paused: Bool { task.state == "paused" || remote?.action == "paused" }
  var completed: Bool { remote?.stage == "completed" }
  var localProgress: Double {
    if task.accepted { return 1 }
    if task.state == "preparing" { return 0 }
    return task.bytes > 0 ? Double(task.uploaded) / Double(task.bytes) : 0
  }
  var nasProgress: Double {
    guard let remote else { return 0 }
    if ["verifying_nas", "publishing", "completed"].contains(remote.stage) { return 1 }
    return remote.bytes_total > 0 ? Double(remote.bytes_done) / Double(remote.bytes_total) : 0
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        Image(
          systemName: completed
            ? "checkmark.seal.fill" : task.finished ? "stop.circle" : "folder.fill"
        ).font(.title2).foregroundStyle(completed ? .green : .accentColor)
        VStack(alignment: .leading, spacing: 3) {
          Text(task.name).font(.headline).textSelection(.enabled)
          Text(
            (store.profiles.first { $0.id == task.serverID }?.name ?? "中繼") + " · "
              + bytes(task.bytes)
          ).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if task.accepted && !task.finished {
          Label("可帶走 Mac", systemImage: "laptopcomputer").font(.caption).foregroundStyle(.green)
        }
        if !task.finished {
          if paused || ["error", "retry_pending"].contains(task.state)
            || ["failed", "conflict"].contains(remote?.stage ?? "")
          {
            Button {
              store.resume(task.id)
            } label: {
              Image(systemName: "play.fill")
            }.help("繼續／重試")
          } else {
            Button {
              store.pause(task.id)
            } label: {
              Image(systemName: "pause.fill")
            }.help("暫停")
          }
          Button(role: .destructive) {
            confirmCancel = true
          } label: {
            Image(systemName: "stop.fill")
          }.help("終止任務")
          if paused && !task.accepted {
            Menu {
              ForEach(store.profiles.filter { $0.id != task.serverID }) { profile in
                Button(profile.name) { store.reroute(task.id, to: profile.id) }.disabled(
                  store.health[profile.id] == nil)
              }
            } label: {
              Image(systemName: "arrow.triangle.swap")
            }.help("切換到其他中繼")
          }
        }
      }
      HStack(alignment: .top, spacing: 24) {
        ProgressCard(
          title: "Mac → 中繼", label: task.accepted ? "完整接收並校驗" : phase(task.state),
          value: localProgress, rate: task.speed, eta: task.eta, complete: task.accepted)
        ProgressCard(
          title: "中繼 → NAS", label: remote.map { phase($0.stage) } ?? "等待完整交接", value: nasProgress,
          rate: remote?.speed_bps ?? 0, eta: remote?.eta_seconds, complete: completed)
      }
      if let message = task.message ?? remote?.error, !message.isEmpty {
        Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
          .orange
        ).textSelection(.enabled)
      }
    }.padding(.vertical, 12).accessibilityElement(children: .contain).contextMenu {
      Button("在 Finder 顯示原始素材") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: task.source)])
      }
      Button("複製任務 ID") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task.id, forType: .string)
      }
    }
    .alert("終止這項歸檔任務？", isPresented: $confirmCancel) {
      Button("繼續執行", role: .cancel) {}
      Button("終止", role: .destructive) { store.cancel(task.id) }
    } message: {
      Text("中繼暫存會清理。Mac 原檔與已發佈的 NAS 內容會保留。")
    }
  }
}
struct MainView: View {
  @ObservedObject var store: Store
  @State private var importing = false
  @State private var managing: String?
  @State private var drop = false
  @State private var filter = "active"
  var body: some View {
    NavigationSplitView {
      List {
        Button {
          store.route = "auto"
          store.persistProfiles()
        } label: {
          Label("自動選擇最低延遲", systemImage: store.route == "auto" ? "bolt.circle.fill" : "bolt.circle")
        }.buttonStyle(.plain).padding(.vertical, 6)
        Section("已連接的中繼") {
          ForEach(store.profiles) { profile in
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Button {
                  store.route = profile.id
                  store.persistProfiles()
                } label: {
                  Label(
                    profile.name,
                    systemImage: store.activeServer == profile.id
                      ? "server.rack" : "externaldrive.connected.to.line.below")
                }.buttonStyle(.plain)
                Spacer()
                Circle().fill(store.health[profile.id] == nil ? Color.orange : Color.green).frame(
                  width: 7, height: 7)
              }
              if let h = store.health[profile.id] {
                Text(
                  String(format: "%.1f ms", h.latency) + " · "
                    + (URL(string: h.endpoint)?.host ?? h.endpoint)
                ).font(.caption).foregroundStyle(.secondary)
              } else {
                Text(store.connectionErrors[profile.id] ?? "連線中…").font(.caption).foregroundStyle(
                  .secondary
                ).lineLimit(2)
              }
            }.padding(.vertical, 5).accessibilityElement(children: .contain).accessibilityAction {
              store.route = profile.id
              store.persistProfiles()
            }.contextMenu {
              Button("設定與 NAS…") { managing = profile.id }
              Button("移除中繼", role: .destructive) { store.removeProfile(profile.id) }
            }
          }
        }
        Button("連接中繼…", systemImage: "plus") { importing = true }
      }.navigationTitle("中繼伺服器").navigationSplitViewColumnWidth(min: 210, ideal: 250)
    } detail: {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("NAS Relay").font(.largeTitle.bold())
              Text(store.route == "auto" ? "新任務自動使用最低延遲的中繼" : "新任務使用指定中繼").foregroundStyle(
                .secondary)
            }
            Spacer()
            if let id = store.activeServer {
              Button("NAS 與預設位置…", systemImage: "gearshape") { managing = id }
            }
            Button {
              Task { await store.refresh() }
            } label: {
              Image(systemName: "arrow.clockwise")
            }.disabled(store.refreshing)
          }
          if let id = store.activeServer, let h = store.health[id] {
            HStack {
              Label(store.profiles.first { $0.id == id }?.name ?? "中繼", systemImage: "network")
                .font(.headline)
              Spacer()
              Text("中繼可用 " + bytes(h.info.free_bytes)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
              Picker(
                "歸檔 NAS",
                selection: Binding(
                  get: { store.targetID(id) }, set: { store.setTarget($0, server: id) })
              ) {
                Text("選擇 NAS").tag("")
                ForEach(h.targets.filter(\.enabled)) { Text($0.name).tag($0.id) }
              }
              TextField(
                "預設相對資料夾",
                text: Binding(get: { store.folder(id) }, set: { store.setFolder($0, server: id) })
              ).textFieldStyle(.roundedBorder)
            }
          }
          VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.up.fill").font(.system(size: 28)).foregroundStyle(
              .tint)
            Text("將素材資料夾或檔案拖到這裡").font(.headline)
            Text("原始素材保留；完整交接後，由中繼獨立歸檔與校驗。").font(.caption).foregroundStyle(.secondary)
            Button("加入素材…") { store.choose() }.buttonStyle(.borderedProminent).disabled(
              store.activeServer == nil)
          }.frame(maxWidth: .infinity).padding(18).background(
            drop ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 12)
          ).overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(
              drop ? Color.accentColor : Color.secondary.opacity(0.3),
              style: StrokeStyle(lineWidth: 1.5, dash: [6]))
          ).onDrop(of: [UTType.fileURL.identifier], isTargeted: $drop) { providers in
            for provider in providers {
              _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in store.add([url]) } }
              }
            }
            return !providers.isEmpty
          }
          if let error = store.error {
            HStack {
              Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
                .orange)
              Spacer()
              Button("關閉") { store.error = nil }.buttonStyle(.plain)
            }
          }
        }.padding(22)
        Divider()
        HStack {
          Picker("任務", selection: $filter) {
            Text("進行中").tag("active")
            Text("全部").tag("all")
            Text("已完成").tag("done")
          }.pickerStyle(.segmented).frame(width: 280)
          Spacer()
          Text("\(store.tasks.count) 項任務").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.vertical, 10)
        let visible = store.tasks.filter {
          filter == "all" || (filter == "done" ? $0.finished : !$0.finished)
        }
        if visible.isEmpty {
          ContentUnavailableView(
            store.profiles.isEmpty ? "先連接一台中繼" : store.tasks.isEmpty ? "尚未加入素材" : "目前沒有符合條件的任務",
            systemImage: "shippingbox",
            description: Text(store.profiles.isEmpty ? "使用服務端安裝後提供的連線資訊。" : "加入素材後可監看兩段傳輸與校驗。")
          ).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List(visible) { TaskRow(store: store, task: $0) }.listStyle(.inset)
        }
        Divider()
        HStack {
          Image(systemName: store.pendingLocal == 0 ? "checkmark.circle" : "laptopcomputer")
            .foregroundStyle(store.pendingLocal == 0 ? .green : .secondary)
          Text(
            store.pendingLocal == 0
              ? "已交接任務由中繼獨立處理，可帶走 Mac。" : "\(store.pendingLocal) 項任務尚需 Mac；暫停或退出後可續傳。"
          ).font(.caption)
          Spacer()
          Text("關閉視窗會繼續傳送").font(.caption).foregroundStyle(.secondary)
        }.padding(14)
      }.frame(minWidth: 760, minHeight: 700)
    }.sheet(isPresented: $importing) { ImportView(store: store) }.sheet(
      isPresented: Binding(get: { managing != nil }, set: { if !$0 { managing = nil } })
    ) { if let id = managing { ServerManager(store: store, server: id) } }
  }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var store: Store?
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationWillTerminate(_ notification: Notification) { store?.stop() }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { sender.windows.first?.makeKeyAndOrderFront(nil) }
    return true
  }
}
@main struct NASRelayApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var store = Store()
  var body: some Scene {
    WindowGroup("NAS Relay") { MainView(store: store).onAppear { delegate.store = store } }
      .defaultSize(width: 1120, height: 800).commands {
        CommandGroup(after: .newItem) {
          Button("加入素材…") { store.choose() }.keyboardShortcut("o")
          Button("重新整理連線") { Task { await store.refresh() } }.keyboardShortcut("r")
        }
      }
  }
}
