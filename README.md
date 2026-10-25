# NAS Relay

原生 macOS 用戶端與 Ubuntu 中繼服務。把素材交給中繼後，即可讓 Mac 離線；中繼會獨立上傳 NAS、校驗內容並清除自己的暫存。

## 下載與安裝

[下載 macOS App 與 Ubuntu 執行檔](https://github.com/imstevelin/nas-archive-relay/releases/latest)。Mac 需要 macOS 14 以上，提供 Apple Silicon / Intel Universal App。預覽版尚未公證，首次開啟可能需要在系統設定的「隱私權與安全性」允許。

Ubuntu Server 22.04 以上，amd64 / arm64：

```sh
curl -fL https://raw.githubusercontent.com/imstevelin/nas-archive-relay/main/server/install.sh -o install-nas-relay.sh
sudo bash install-nas-relay.sh --name 'My Relay' --endpoint https://192.168.1.20:8743
```

安裝器會下載發行檔並校對 SHA-256，安裝 NFS/SMB 工具、建立獨立的 systemd 服務，顯示管理員連線 URI 與 JSON。可重複指定 `--endpoint` 加入 LAN、VPN 或 DNS 位址。連線資訊包含存取權杖，請私下保管。

## 使用方式

1. 在 App 按「新增中繼」，貼上服務端連線 URI，或匯入 JSON。可加入多台伺服器。
2. 開啟「管理伺服器」，新增 SMB 或 NFS 目標，測試讀寫與校驗，設定預設歸檔資料夾。
3. 選擇或拖入素材。App 顯示 Mac→中繼、中繼→NAS 的階段、速度與預估時間。只有出現「可帶走 Mac」才代表完整交接成功。
4. 每項任務可暫停、繼續、終止。網路恢復後會從已確認的區塊續傳。

「自動選擇」會比較各伺服器可連線端點的三次驗證請求延遲，為新任務選擇最低延遲的中繼。也可手動指定。進行中的任務維持原伺服器；尚未完整交接的任務可先暫停，再改用另一台中繼。

## 資料處理

- Mac 原始素材不會被移動或刪除。
- 每個 8 MiB 區塊及完整檔案均使用 SHA-256 校驗。中繼收到所有檔案、完整校驗成功後才允許 Mac 離線。
- NAS 寫入專屬暫存，fsync 後重讀校驗，再以排他的 hard link 發布，避免覆寫既有不同內容。NAS 需要支援 hard link；目標測試會檢查。
- 完成最終校驗並保存收據後才清除中繼 payload。相同內容可驗證後略過；同名不同內容保留來源並顯示衝突。
- 清理可在重啟後接續。終止不會刪除已發布的 NAS 檔案。
- 空資料夾與修改時間會保存。macOS 延伸屬性記錄於收據，沒有自動還原 ACL、Finder 標籤或 resource fork；符號連結與特殊檔案會拒絕。

## 用戶端與服務端

| 位置 | 內容 |
| --- | --- |
| `client/` | SwiftUI App、TLS 憑證釘選、Keychain、素材清單與上傳引擎 |
| `server/` | Go 標準函式庫 HTTPS API、工作佇列、NAS 掛載與命令列 |
| `scripts/` | macOS Universal App 與 Linux 跨平台打包 |
| `docs/` | API、部署維護與驗證說明 |

```sh
swift test --package-path client
UNIVERSAL=1 bash scripts/build-client.sh
(cd server && go test -race ./... && go vet ./...)
bash scripts/build-server.sh
```

服務端不需要 Python、Node 或 Docker；Mac App 不需要外部 rsync。CI 在 Linux 與 macOS 分別執行測試及建置。

[維護與安全](docs/OPERATIONS.md) · [API](docs/API.md) · [驗證紀錄](docs/VALIDATION.md)
