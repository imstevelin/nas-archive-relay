# v0.2.0 驗證紀錄

2026-10-26，以下分開記錄自動測試與實際設備驗證。

## 自動測試

- Go：16 項，使用 race detector；涵蓋區塊雜湊失敗回復、斷線尾端截斷、重啟 offset、暫停/恢復/終止、用戶隔離、權限、NAS 故障保留與重試、同名衝突、來源損毀、併發上傳、路徑/符號連結拒絕、完成後清理回復、憑證續期與憑證設定失敗回復。
- Swift：10 項離線測試，涵蓋連線資訊/指紋/HTTPS 限制、持久化不含 token、手動/自動路由、續傳速度基準、素材 SHA 清單、空目錄、來源變更與符號連結。
- Swift opt-in live TLS：使用 `NAS_RELAY_CONNECTION=/private/path/connection.json swift test --package-path client --filter LiveConnectionTests`，驗證三個實際 HTTPS 端點。此測試在沒有私密連線檔時會略過。
- Linux amd64 / arm64 靜態執行檔及 macOS arm64 / x86_64 Universal App 建置與簽章驗證。

## 實機

- Ubuntu 實際安裝，與既有原型服務、設定及工作分開。
- 32 MiB NFS 歸檔：錯誤 chunk hash 回復、第一段暫停/恢復、兩個用戶相互隔離、一般用戶不能設定 NAS、終止後清理，最終由 Mac 的另一個 NFS 掛載讀回完整 SHA-256 相符。
- 16 MiB SMB 3.1.1 歸檔：實際掛載、fsync/read/link 測試、完成後清理，再透過 NFS 讀回 SHA-256 相符。測試中發現 CIFS deferred-close hard-link EINVAL，採用 nolease / closetimeo=0 後重測通過。
- 原生 App：匯入私密連線 JSON、Keychain 保存、顯示實際延遲、選取 64 MiB 素材、兩段速度與 ETA、完整交接後顯示可帶走 Mac、NAS 完成後獨立 SHA-256 相符。
- 兩個獨立 daemon、不同 state/cert/port：App 同時連接，自動選擇當下最低延遲、手動切換成功。透過 App 新增第二個 NFS 目標、讀寫校驗及儲存預設 NAS/資料夾。

這些結果是此版本與當次設備的驗證，沒有把單元測試視為所有 NAS、VPN 或 macOS 權限組合的保證。NFS hard I/O 在網路失聯時仍可能等待核心恢復；實際作業期間 App 關閉後，只要已交接，NAS 段仍由服務繼續執行。公開 Mac 預覽版尚未 Apple 公證。
