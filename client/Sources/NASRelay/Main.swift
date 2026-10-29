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
func issue(_ text: String) -> String {
  if text.contains("NAS already contains") { return "NAS 已有同名項目，請選擇比對、另存副本或取消。" }
  if text.contains("payload is damaged") { return "中繼副本校驗失敗。請取消此任務，再重新加入原始素材。" }
  if text.contains("SHA-256") || text.contains("digest") { return "檔案校驗未通過。來源已保留，可重新嘗試歸檔。" }
  if text.contains("cleanup pending") { return "NAS 暫存尚待清理。連線恢復後會自動重試，原始素材已保留。" }
  if text.contains("mount failed") || text.contains("target unavailable") {
    return "無法連接 NAS。請確認 NAS 與 VPN 連線；中繼會保留素材並自動重試。"
  }
  if text.contains("offset changed") { return "正在重新確認續傳位置，請稍候再試。" }
  return text
}
func phase(_ value: String) -> String {
  [
    "checking_destination": "檢查歸檔位置", "awaiting_duplicate_local": "NAS 已有同名項目，請選擇處理方式",
    "awaiting_duplicate": "NAS 已有同名項目，請選擇處理方式", "queued": "等待歸檔", "receiving": "等待素材上傳",
    "resolving_source": "確認來源磁碟", "waiting_source": "等待同一顆硬碟完成校驗", "checking_resume": "確認素材與續傳位置",
    "preparing": "建立 SHA-256 清單",
    "uploading": "傳送素材",
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
          panel.begin { response in
            if response == .OK, let url = panel.url {
              do { text = try String(contentsOf: url, encoding: .utf8) } catch {
                self.error = error.localizedDescription
              }
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
struct ConnectionEditor: View {
  @ObservedObject var store: Store
  let profile: ServerProfile
  @Environment(\.dismiss) var dismiss
  @State private var name = ""
  @State private var addresses = ""
  @State private var error: String?
  @State private var importing = false
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("編輯中繼連線").font(.title2.bold())
      TextField("顯示名稱", text: $name)
      Text("連線 IP 或 HTTPS 位址（每行一個）").font(.headline)
      TextEditor(text: $addresses).font(.system(.body, design: .monospaced)).frame(height: 110)
        .padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
      Text("直接輸入 IP 會沿用目前服務埠號。可在離線時儲存；連線仍會檢查原本的憑證與主機名稱。").font(.caption).foregroundStyle(.secondary)
      DisclosureGroup("更新憑證或用戶端身分") {
        VStack(alignment: .leading, spacing: 8) {
          Text("如果新位址不在憑證內，請向服務端取得更新的連線資訊。仍有任務時，可更新原身分的位址與憑證，不能改成另一個用戶端身分。").font(.caption)
            .foregroundStyle(.secondary)
          Button("重新匯入連線資訊…") { importing = true }
        }.padding(.top, 8)
      }
      if let error { Text(error).foregroundStyle(.red).font(.callout) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("儲存") {
          do {
            try store.editConnection(profile.id, name: name, addresses: addresses)
            dismiss()
          } catch { self.error = error.localizedDescription }
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 560).onAppear {
      name = profile.name
      addresses = profile.endpoints.joined(separator: "\n")
    }
    .sheet(isPresented: $importing) { ImportView(store: store) }
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
        TextField("NAS 位址", text: $target.host, prompt: Text("例如 192.168.1.10 或 nas.local"))
        if target.protocol == "nfs" {
          TextField(
            "共用路徑", text: $target.export, prompt: Text("由 NAS 的 NFS 設定提供，例如 /mnt/pool/archive"))
          Picker("NFS 版本", selection: $target.nfs_version) {
            Text("4.2（建議）").tag("4.2")
            Text("4.1").tag("4.1")
            Text("4.0").tag("4")
            Text("3").tag("3")
          }
        } else {
          TextField("共用資料夾名稱", text: $target.share, prompt: Text("例如 Archive，無須輸入 smb://"))
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
        Button("測試連線並儲存") {
          busy = true
          Task {
            do {
              target = try await store.saveTarget(
                TargetInput(target: target, password: password.isEmpty ? nil : password),
                server: server)
              password = ""
              _ = try await store.testTarget(target, server: server)
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
  @State private var editingConnection = false
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
        Button("連線設定…") { editingConnection = true }
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
    .sheet(isPresented: $editingConnection) {
      if let profile { ConnectionEditor(store: store, profile: profile) }
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
  var localProgress: Double { task.uploadFraction }
  var nasProgress: Double {
    guard let remote, remote.accepted else { return 0 }
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
              + (task.bytes == 0
                && [
                  "preparing", "checking_destination", "awaiting_duplicate_local", "waiting_source",
                  "resolving_source",
                ].contains(
                  task.state)
                ? "尚未傳送" : bytes(task.bytes))
          ).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if task.accepted && !task.finished {
          Label("可帶走 Mac", systemImage: "laptopcomputer").font(.caption).foregroundStyle(.green)
        }
        if !task.finished && !["completed", "cancelled"].contains(remote?.stage ?? "")
          && task.state != "awaiting_duplicate_local"
          && !["awaiting_duplicate", "conflict"].contains(remote?.stage ?? "")
        {
          if paused || ["error", "retry_pending"].contains(task.state)
            || ["failed", "conflict"].contains(remote?.stage ?? "")
          {
            Button {
              store.resume(task.id)
            } label: {
              Label("繼續", systemImage: "play.fill")
            }.help("繼續／重試")
          } else {
            Button {
              store.pause(task.id)
            } label: {
              Label("暫停", systemImage: "pause.fill")
            }.help("暫停")
          }
          Button(role: .destructive) {
            confirmCancel = true
          } label: {
            Label("終止", systemImage: "stop.fill")
          }.help("終止任務")
          if paused && !task.accepted && store.profiles.contains(where: { $0.id != task.serverID })
          {
            Menu {
              ForEach(store.profiles.filter { $0.id != task.serverID }) { profile in
                Button(profile.name) { store.reroute(task.id, to: profile.id) }.disabled(
                  store.health[profile.id] == nil)
              }
            } label: {
              Label("更換中繼", systemImage: "arrow.triangle.swap")
            }.menuStyle(.borderlessButton).fixedSize().help("使用另一台中繼重新傳送素材")
          }
        }
      }
      if ["preparing", "checking_resume", "checking_source"].contains(task.state), task.bytes > 0 {
        Text(
          "素材校驗：\(bytes(task.preparationDone)) / \(bytes(task.bytes))（\(Int(min(1, max(0, Double(task.preparationDone) / Double(task.bytes))) * 100))%）"
        )
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      if task.state == "awaiting_duplicate_local"
        || ["awaiting_duplicate", "conflict"].contains(remote?.stage ?? "")
      {
        VStack(alignment: .leading, spacing: 10) {
          Label(
            remote?.stage == "conflict" ? "NAS 的同名內容與這份素材不同" : "NAS 已有「\(task.name)」",
            systemImage: "doc.on.doc"
          ).font(.headline)
          Text("比對會先將素材交給中繼，再校驗 NAS 既有內容；相同便略過 NAS 寫入，不同則停止並保留來源。另存副本會使用新名稱。").font(.callout)
            .foregroundStyle(
              .secondary)
          HStack {
            Button("比對既有內容") { store.resolveDuplicate(task.id, keepBoth: false) }
            Button("另存副本") { store.resolveDuplicate(task.id, keepBoth: true) }.buttonStyle(
              .borderedProminent)
            Button("取消這項任務", role: .destructive) { confirmCancel = true }
          }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
          .quaternary, in: RoundedRectangle(cornerRadius: 10))
      }
      if let name = remote?.archive_name, !name.isEmpty {
        Label("NAS 名稱：" + name, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
      }
      HStack(alignment: .top, spacing: 24) {
        ProgressCard(
          title: "Mac → 中繼", label: task.accepted ? "完整接收並校驗" : phase(task.state),
          value: localProgress, rate: task.speed, eta: task.eta, complete: task.accepted)
        ProgressCard(
          title: "中繼 → NAS", label: remote?.accepted == true ? phase(remote!.stage) : "等待完整交接",
          value: nasProgress,
          rate: remote?.accepted == true ? remote!.speed_bps : 0,
          eta: remote?.accepted == true ? remote!.eta_seconds : nil, complete: completed)
      }
      if let remote, ["completed", "cancelled"].contains(remote.stage),
        remote.nas_clean == false || remote.relay_clean == false
      {
        Label("正在清理任務暫存，完成後會自動移到已結束。", systemImage: "clock").font(.caption).foregroundStyle(
          .secondary)
      }
      if let cleanup = remote?.cleanup_error, !cleanup.isEmpty {
        Label("NAS 暫存尚待清理；中繼會自動重試。", systemImage: "exclamationmark.triangle").font(.caption)
          .foregroundStyle(.orange)
      }
      if !task.accepted && ["error", "paused", "retry_pending"].contains(task.state) {
        Button("重新選取來源…") { store.reselectSource(task.id) }
          .help("重新授權讀取外接硬碟，或指定搬移後的原始素材；既有進度會保留。")
      }
      if let message = task.message ?? remote?.error, !message.isEmpty {
        Label(issue(message), systemImage: "exclamationmark.triangle").font(.caption)
          .foregroundStyle(
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
struct DestinationView: View {
  @ObservedObject var store: Store
  @Environment(\.dismiss) var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("選擇歸檔位置").font(.title2.bold())
      Form {
        Picker(
          "中繼伺服器",
          selection: Binding(
            get: { store.route },
            set: {
              store.route = $0
              store.persistProfiles()
            })
        ) {
          Text("自動選擇最快的連線").tag("auto")
          ForEach(store.profiles) { Text($0.name).tag($0.id) }
        }
        if let id = store.activeServer, let h = store.health[id] {
          Picker(
            "歸檔到",
            selection: Binding(
              get: { store.targetID(id) }, set: { store.setTarget($0, server: id) })
          ) {
            Text("選擇 NAS 資料夾").tag("")
            ForEach(h.targets.filter(\.enabled)) { Text($0.name).tag($0.id) }
          }
          TextField(
            "其中的子資料夾",
            text: Binding(get: { store.folder(id) }, set: { store.setFolder($0, server: id) }),
            prompt: Text("留空使用共用資料夾本身"))
          Text("使用相對路徑，例如「2026/Podcast」。這裡的選擇只影響之後加入的任務。").font(.caption).foregroundStyle(
            .secondary)
        } else {
          Text("這台中繼暫時無法連線。請確認它已開機，且目前網路或 VPN 可以到達。").foregroundStyle(.secondary)
        }
      }.formStyle(.grouped)
      HStack {
        Spacer()
        Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 540)
  }
}
struct MainView: View {
  @ObservedObject var store: Store
  @State private var importing = false
  @State private var destination = false
  @State private var managing: String?
  @State private var filter = "active"
  @State private var drop = false
  var ready: Bool {
    guard let id = store.activeServer else { return false }
    return store.health[id]?.targets.contains { $0.id == store.targetID(id) && $0.enabled } ?? false
  }
  var activeName: String { store.selectedProfile?.name ?? "尚未連線" }
  var targetName: String {
    guard let id = store.activeServer else { return "選擇 NAS 資料夾" }
    return store.health[id]?.targets.first { $0.id == store.targetID(id) }?.name ?? "設定 NAS 資料夾"
  }
  var visible: [LocalTask] {
    store.tasks.filter { filter == "all" || (filter == "done" ? $0.finished : !$0.finished) }
  }
  var body: some View {
    NavigationSplitView {
      List(
        selection: Binding<String?>(
          get: { store.route },
          set: {
            if let value = $0 {
              store.route = value
              store.persistProfiles()
            }
          })
      ) {
        Label("自動選擇", systemImage: "bolt.horizontal.circle").tag("auto")
        Section("中繼伺服器") {
          ForEach(store.profiles) { profile in
            HStack(alignment: .top, spacing: 9) {
              Image(systemName: "server.rack").foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).fontWeight(.medium)
                if let h = store.health[profile.id] {
                  Text(String(format: "已連線 · %.0f ms", h.latency)).font(.caption).foregroundStyle(
                    .secondary)
                } else {
                  Text(store.connectionErrors[profile.id] == nil ? "連線中…" : "無法連線").font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Circle().fill(store.health[profile.id] == nil ? Color.orange : .green).frame(
                width: 6, height: 6
              ).padding(.top, 6)
            }.padding(.vertical, 5).tag(profile.id).contextMenu {
              Button("伺服器設定…") { managing = profile.id }
              Button("移除連線", role: .destructive) { store.removeProfile(profile.id) }
            }
          }
        }
      }.navigationTitle("NAS Relay").navigationSplitViewColumnWidth(min: 200, ideal: 230)
        .safeAreaInset(edge: .bottom) {
          Button("加入伺服器…", systemImage: "plus") { importing = true }.buttonStyle(.borderless)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    } detail: {
      VStack(spacing: 0) {
        if store.profiles.isEmpty {
          VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "tray.and.arrow.up.fill").font(.system(size: 44)).foregroundStyle(
              .tint)
            Text("把歸檔工作交給中繼").font(.largeTitle.bold())
            Text("先將素材完整交給小主機，再由它上傳 NAS。完成交接後，你就能帶走 Mac。").font(.title3).foregroundStyle(.secondary)
            setupStep("1", "連接中繼", "貼上安裝服務端時提供的連線資訊。")
            setupStep("2", "設定 NAS 資料夾", "選擇要存放素材的共享位置，並測試連線。")
            setupStep("3", "加入素材", "拖入檔案或資料夾，就能追蹤歸檔進度。")
            Button("連接第一台中繼…", systemImage: "plus") { importing = true }.buttonStyle(
              .borderedProminent
            ).controlSize(.large)
          }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
          VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                Text("檔案歸檔").font(.largeTitle.bold())
                Text("原始素材會留在 Mac，完成歸檔後自動清空中繼暫存。").foregroundStyle(.secondary)
              }
              Spacer()
              if let id = store.activeServer {
                Button {
                  managing = id
                } label: {
                  Label("伺服器設定", systemImage: "gearshape")
                }.help("設定 NAS、預設資料夾與用戶端")
              }
            }
            if ready {
              HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.checkmark").font(.title2).foregroundStyle(
                  .tint)
                VStack(alignment: .leading, spacing: 4) {
                  Text("歸檔到「\(targetName)」").font(.headline)
                  let folder = store.activeServer.map { store.folder($0) } ?? ""
                  Text(activeName + (folder.isEmpty ? " · 共用資料夾" : " · " + folder)).font(.caption)
                    .foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("變更…") { destination = true }
              }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
              VStack(spacing: 10) {
                Image(systemName: "arrow.up.doc").font(.system(size: 26)).foregroundStyle(.tint)
                Text("將檔案或資料夾拖到這裡").font(.headline)
                Button("選擇檔案…") { store.choose() }.buttonStyle(.borderedProminent)
              }.padding(20).frame(maxWidth: .infinity).background(
                drop ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                  drop ? Color.accentColor : Color.secondary.opacity(0.35),
                  style: StrokeStyle(lineWidth: 1, dash: [5]))
              )
              .onDrop(of: [UTType.fileURL.identifier], isTargeted: $drop) { providers in
                for p in providers {
                  _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in store.add([url]) } }
                  }
                }
                return !providers.isEmpty
              }
            } else {
              VStack(alignment: .leading, spacing: 12) {
                Label(
                  store.activeServer == nil ? "中繼目前無法連線" : "接著，設定歸檔位置",
                  systemImage: store.activeServer == nil
                    ? "wifi.exclamationmark" : "folder.badge.gearshape"
                ).font(.headline)
                Text(
                  store.activeServer == nil
                    ? "請確認小主機已開機，且網路或 VPN 已連線。任務會保留，恢復連線後可繼續。" : "告訴中繼要連接哪一台 NAS，選擇共用資料夾，再測試是否能讀寫。"
                ).font(.callout).foregroundStyle(.secondary)
                if let id = store.activeServer {
                  Button("設定 NAS 資料夾…") { managing = id }.buttonStyle(.borderedProminent)
                } else {
                  Button("重新連線") { Task { await store.refresh() } }
                }
              }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(
                .quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            if let error = store.error {
              HStack {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                  .foregroundStyle(.orange)
                Spacer()
                Button("關閉") { store.error = nil }
              }
            }
          }.padding(24)
          Divider()
          HStack {
            Picker("顯示任務", selection: $filter) {
              Text("進行中").tag("active")
              Text("全部").tag("all")
              Text("已結束").tag("done")
            }.pickerStyle(.segmented).frame(width: 270)
            Spacer()
            Text("\(visible.count) 項任務").font(.caption).foregroundStyle(.secondary)
          }.padding(.horizontal, 24).padding(.vertical, 12)
          if visible.isEmpty {
            ContentUnavailableView(
              filter == "active" ? "沒有進行中的歸檔" : "尚無歸檔紀錄", systemImage: "tray",
              description: Text(ready ? "加入素材後，這裡會顯示兩段傳輸與校驗進度。" : "完成上方設定後即可開始。")
            ).frame(maxHeight: .infinity)
          } else {
            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(visible) { task in
                  TaskRow(store: store, task: task).padding(.horizontal, 24)
                  Divider().padding(.horizontal, 24)
                }
              }
            }
          }
        }
        Divider()
        HStack(spacing: 8) {
          Image(systemName: store.pendingLocal == 0 ? "checkmark.circle.fill" : "laptopcomputer")
            .foregroundStyle(store.pendingLocal == 0 ? .green : .secondary)
          Text(
            store.pendingLocal == 0
              ? (store.tasks.isEmpty ? "準備好後就能加入素材" : "沒有需要保持 Mac 連線的任務。")
              : "\(store.pendingLocal) 項任務尚未完整交接，請保持 Mac 連線。"
          ).font(.caption)
          Spacer()
          Text("關閉視窗會繼續傳送").font(.caption).foregroundStyle(.secondary)
        }.padding(14)
      }.frame(minWidth: 670, minHeight: 650)
        .navigationTitle("歸檔")
        .toolbar {
          ToolbarItem {
            Button {
              Task { await store.refresh() }
            } label: {
              Label("重新連線", systemImage: "arrow.clockwise")
            }.disabled(store.refreshing)
          }
        }
    }
    .sheet(isPresented: $importing) { ImportView(store: store) }
    .sheet(isPresented: $destination) { DestinationView(store: store) }
    .sheet(isPresented: Binding(get: { managing != nil }, set: { if !$0 { managing = nil } })) {
      if let id = managing { ServerManager(store: store, server: id) }
    }
  }
  func setupStep(_ number: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text(number).font(.headline).foregroundStyle(.tint).frame(width: 30, height: 30).background(
        Color.accentColor.opacity(0.12), in: Circle())
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline)
        Text(detail).foregroundStyle(.secondary)
      }
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var store: Store?
  var showMainWindow: (() -> Void)?
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationWillTerminate(_ notification: Notification) { store?.stop() }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    showMainWindow?()
    sender.activate(ignoringOtherApps: true)
    return false
  }
}
struct MainWindowContent: View {
  @ObservedObject var store: Store
  let delegate: AppDelegate
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    MainView(store: store).onAppear {
      delegate.store = store
      delegate.showMainWindow = { openWindow(id: "main") }
    }
  }
}
struct TransferSettings: View {
  let store: Store
  let delegate: AppDelegate
  @Environment(\.openWindow) private var openWindow
  @AppStorage(SourceReadProtection.preferenceKey) private var protectExternal = false
  var body: some View {
    Form {
      Toggle("外接磁碟限速讀取", isOn: $protectExternal)
      Text("同一顆外接磁碟的讀取共用 24 MiB/s 上限，校驗依序進行，降低大量素材同時校驗造成的負載。內建磁碟與 NAS 來源不受此設定影響。")
        .font(.callout).foregroundStyle(.secondary)
      Text("調整後，請暫停並繼續現有任務以套用設定。關閉後會恢復原本的讀取速度。")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(24).frame(width: 440).navigationTitle("傳輸")
      .onAppear {
        delegate.store = store
        delegate.showMainWindow = { openWindow(id: "main") }
      }
  }
}
@main struct NASRelayApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var store = Store()
  var body: some Scene {
    Window("NAS Relay", id: "main") { MainWindowContent(store: store, delegate: delegate) }
      .defaultSize(width: 1120, height: 800).commands {
        CommandGroup(after: .newItem) {
          Button("顯示歸檔視窗") { delegate.showMainWindow?() }.keyboardShortcut("1")
          Button("加入素材…") { store.choose() }.keyboardShortcut("o")
          Button("重新整理連線") { Task { await store.refresh() } }.keyboardShortcut("r")
        }
      }
    Settings { TransferSettings(store: store, delegate: delegate) }
  }
}
