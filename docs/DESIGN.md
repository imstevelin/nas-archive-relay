# 介面設計

依 Apple [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)、[Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback)、[Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) 的原則，透過實際操作帶入設定，在操作附近提供說明，並讓提示對應可執行的選擇。

- 首次開啟只引導「連接中繼 → 設定 NAS → 加入素材」。已有設定時直接進入歸檔。
- 主畫面用單一歸檔位置卡片，配合拖放區及「選擇檔案」；子資料夾、協定與帳號集中於位置選擇及伺服器設定。
- NAS 新增後必須通過讀寫、校驗及排他發布測試才完成設定。
- 中繼用標準 macOS sidebar 選取，顯示連線狀態；內部 IP 與診斷資訊留在設定頁。
- 兩段傳輸分開呈現，尚未完整交接前不會把第一段的接收速度顯示成 NAS 上傳速度。
- 暫停、繼續及終止使用文字標籤。同名項目在任務旁提供比對、另存副本、取消，不連續彈出通知。
- 檔案選擇採非阻塞 sheet，開啟時固定目的地，避免背景延遲探測改變這次選擇。
- NAS 狀態資料夾與任務 ID 對應；只有校驗完成的內容能以原名發布。
