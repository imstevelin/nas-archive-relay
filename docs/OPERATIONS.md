# 部署與維護

預設服務 `nas-archive-relay.service`、HTTPS 8743、程式 `/usr/local/bin/nas-relay`、狀態 `/var/lib/nas-archive-relay`。狀態目錄包含 TLS 私鑰、SMB 憑證、設定、工作清單、暫存與收據，權限應維持 root 0700。

```sh
sudo systemctl status nas-archive-relay
sudo journalctl -u nas-archive-relay -f
sudo nas-relay client add --name 'Editor Mac' --role client
sudo nas-relay client list
sudo nas-relay client revoke --id CLIENT_ID
sudo nas-relay info
```

`client add` 預設建立一般使用者，只可操作自己的工作；admin 可管理 NAS、預設值與新增/撤銷使用者。權杖僅發出一次，遺失時建立新連線並撤銷舊連線。CLI 變更無須重啟服務。App 的管理頁可建立新用戶端邀請；撤銷亦可使用 CLI。

每個用戶端都有獨立 token，伺服器只保存 SHA-256。Mac token 放於 Keychain，磁碟設定不含 token。HTTPS 要求 TLS 1.3，App 比對匯入的憑證指紋、主機名稱與有效期，不接受重新導向。請透過可信任方式交換首次連線資訊；憑證或端點改變時須重新配對。

中繼需 root 權限掛載 NAS，管理員連線應視同可設定該主機的 NAS 存取。建議限制 HTTPS 端口只允許 LAN 或私人 VPN，不直接開放公網。NFS 權限與 VPN 回呼端口仍由 NAS/網路端管理；NFSv4 可減少 NFSv3 動態 RPC 的配置需求。

服務使用受限制的 systemd 檔案系統命名空間；NAS 掛載位於服務的 mount namespace，主機 shell 的 `mount` 清單可能不同。可用 `sudo nsenter -t $(systemctl show -p MainPID --value nas-archive-relay) -m findmnt` 檢查。

NFS 採用 hard mount。若 NAS 無回應，核心 I/O 可能等待網路恢復，暫停/終止會先保存意圖，於 I/O 安全邊界生效。App 顯示「正在暫停／終止」時，並不代表已完成。重啟服務不保證能中止核心正在等待的 NFS I/O，請先恢復 NAS 連線。

重新執行安裝器可升級，保留原設定與工作；舊執行檔保存在 `/usr/local/lib/nas-relay/backups`。更改 `--port` 或公開端點時，既有 TLS 憑證不會自動重建；應依既有設定部署，或維護時另建狀態目錄並重新配對。請勿讓多個 daemon 共用同一狀態目錄。

預設保留 10 GiB 空間。中繼磁碟需能容納待歸檔內容；未完成任務會保留資料。清理只移除自己管理的 payload 與 NAS staging，工作歷史與收據持續保留。完成工作仍有清理待辦時，目標不可刪除或變更。

本版本使用新協定與獨立狀態目錄，不自動接管早期原型的進行中任務。升級前請讓舊工作完成；兩套服務可以分開運作。

TLS 憑證有效期一年，符合 macOS 的伺服器憑證期限檢查。維護時可停止服務，執行 `sudo nas-relay certificate-renew`，再啟動服務。憑證更新後，舊指紋將被 App 拒絕，請以新連線資訊重新匯入；既有 token 與工作不會刪除。請在到期前安排維護。

App 允許使用者指定採用私有自簽憑證的主機，因此在 Info.plist 停用系統預設 ATS 信任限制，改由專用 RelayAPI 強制 HTTPS、TLS 1.3、匯入憑證的精確 SHA-256 指紋、SAN 主機與有效期檢查；不使用系統全域憑證信任、不接受 HTTP 或重新導向。SMB 採用 cache=none、actimeo=0、closetimeo=0、nolease，避免部分 CIFS 核心在 hard link 發布後重用舊 handle 而回傳 EINVAL，並確保校驗重新讀取 NAS。


## 互動安裝與儲存位置（v0.4）

單行命令透過 `/dev/tty` 互動，即使腳本經由 pipe 執行，也能選擇設定。新安裝可選預設目錄、已掛載磁碟的專用子目錄，或自訂絕對目錄（含空白與中文）；此位置同時保存暫存、設定、憑證與任務紀錄。請使用持久儲存，並先掛載需要的磁碟；安裝器不會格式化磁碟或使用含有其他資料的非空目錄。

systemd 記錄儲存位置所屬掛載點，並加上 RequiresMountsFor / ConditionPathIsMountPoint，避免預期的磁碟未掛載時直接寫到裸目錄。`/etc/nas-archive-relay/data-path` 記錄服務資料位置，CLI 預設會讀取它，所以自訂位置不必每次再加 --data。升級會保留資料與現有端點；搬移進行中工作不在安裝器內自動執行。

自動化部署使用 `--non-interactive`；也可用 `--interactive` 明確要求終端機互動。`nas-relay discover --port 8743` 列出系統偵測到的可用端點，`nas-relay info --field endpoints` 列出已設定端點。

Mac 編輯位址時保留既有憑證釘選。新 IP 或 DNS 必須符合伺服器憑證；如果伺服器更新憑證，可重新匯入更新的連線資訊。尚有未完成任務時不能改成另一個用戶端身分。

## 外接硬碟來源（v0.4.1）

暫停、重新開啟 App 或磁碟重新連線後，每次續傳都重新解析來源書籤，更新實際來源路徑。一般與安全範圍書籤都可解析；解析時不會自動掛載未連線磁碟或跳出系統視窗。

來源暫時不存在或發生暫時 I/O 錯誤時，任務保留已接收進度並等待重試。權限被拒時會顯示讀取授權說明；錯誤保留檔案路徑與系統錯誤碼，避免把所有失敗都顯示為找不到素材。

在未完整交接的錯誤、暫停或等待重試任務下，按「重新選取來源…」可透過系統選取視窗重新授權或指定搬移後的同名素材。開啟選取視窗時任務會暫停；取消選取便保持暫停。任務 ID 與中繼進度保留，已有清單必須通過原 SHA-256 校驗才會續傳，不會把內容不同的檔案接到舊任務。完成完整交接後不需繼續連接來源硬碟。
