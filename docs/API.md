# HTTPS API v1

所有端點要求 `Authorization: Bearer TOKEN`；JSON 使用 UTF-8。連線資訊 schema 1 包含 server_id、client_id、name、role、endpoints、certificate（DER/base64）、fingerprint（SHA-256 hex）與 token。`nasrelay://connect?data=...` 的 data 是此 JSON 的 base64url。

| 方法與路徑 | 功能 |
| --- | --- |
| GET `/v1/ping` | 已驗證延遲探測 |
| GET `/v1/info` | 名稱、版本、空間、預設目標與 chunk 大小 |
| PUT `/v1/settings` | admin 設定 default_target / default_folder |
| GET / POST `/v1/targets` | 列出 / admin 新增 NAS |
| PUT / DELETE `/v1/targets/{id}` | admin 編輯 / 刪除 |
| POST `/v1/targets/{id}/test` | admin 測試掛載、讀寫、hash、hard link |
| GET / POST `/v1/clients` | admin 列出 / 建立連線 |
| DELETE `/v1/clients/{id}` | admin 撤銷連線 |
| GET / POST `/v1/jobs` | 列出自己的工作 / 建立 manifest |
| GET `/v1/jobs/{id}` | 階段、accepted、bytes_done、speed_bps、eta_seconds |
| GET `/v1/jobs/{id}/upload` | 每個檔案已持久化的 offset |
| PUT `/v1/jobs/{id}/files/{index}` | 上傳最多 8 MiB 原始 body，帶 Upload-Offset 與 X-Chunk-SHA256 |
| POST `/v1/jobs/{id}/commit` | 檔案長度齊全後排入完整校驗 |
| POST `/v1/jobs/{id}/{pause,resume,cancel,retry}` | 保存控制意圖 |

Manifest 具有隨機32位小寫hex `id`、`name`、`target_id`、相對 `folder`、`entries`。Entry 包含相對 `path`、`type`（dir/file）、檔案 `size`、`sha256`、可選 Unix 毫秒 `mtime` 與 base64 metadata。父目錄必須列出，大小寫不敏感的重名、路徑穿越與內部保留名稱會拒絕。

建立同一 ID 與相同 manifest 是冪等操作。GET upload 後從確認 offset 繼續。chunk 僅在 SHA 與 fsync、持久化 offset journal 成功後回覆；斷線未確認區塊會回復到前次 offset。commit 回覆202不等於已交接，必須輪詢直到 `accepted: true`。`completed` 表示最終內容與收據已確認；`relay_clean` / `nas_clean` 表示兩端暫存清理已完成。

一般用戶端只可讀寫自己工作。admin 查詢 `/v1/jobs?all=true` 可列出全部。權限不足403、不可見工作404、狀態或offset衝突409、空間不足507。NAS 故障保留 payload 並重試；來源校驗失敗、同名衝突需要人工處理。

## v0.3 同名內容與 NAS 狀態

`POST /v1/preflight` 傳入 `name`、`target_id`、`folder`，回覆 `exists`。這是不建立檔案的預檢；NAS 不可用時可先交接到中繼，之後仍會再次檢查。NAS 檢查併發上限為2，避免失聯的 hard mount 累積無限等待。

Manifest 可帶 `collision_policy: "use-existing" | "keep-both"`，表示使用者已在上傳前做出選擇。省略時，如果 NAS 已有同名內容，工作進入 `awaiting_duplicate`，必須 POST `use-existing`、`keep-both` 或 `cancel`。普通 resume 不能代替確認。use-existing 只接受完整相同內容，差異會進入 conflict；keep-both 以獨立副本名稱歸檔，`archive_name` 回覆實際名稱。

NAS 暫存位於可見的 `素材名（上傳中）.nasrelay-JOB_ID`、`素材名（校驗中）.nasrelay-JOB_ID` 目錄，ID 隔離多用戶的同名任務。全部內容校驗通過後才建立原名。錯誤或終止清除具有正確任務標記的暫存；中繼的已驗證來源在歸檔完成前保留，終止時才清除。網路失聯導致清理暫時不可行時，狀態保留 pending 並在恢復後重試。
