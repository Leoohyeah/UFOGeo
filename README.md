<p align="center">
  <img src="https://github.com/Leoohyeah/UFOGeo/blob/main/assets/UFOGeo.png" alt="UFOGeo app icon" width="220" />
</p>

UFOGeo 是一款面向 iOS 裝置開發與測試場景的定位模擬與路線模擬工具，主要用於在已連線裝置上進行 GPS 位置模擬與移動軌跡控制。

## 專案簡介

本專案聚焦於 iOS 裝置的定位模擬、路線模擬與裝置連線流程，主要功能包括：

- GPS 位置模擬
- 路線移動模擬
- 背景定位處理
- 裝置配對與連線控制
- 開發者與測試場景下的地理位置驗證

## 安裝與設定

### 1. 首次準備必要工具

因需取得 `pairingFile.plist` 並側載 IPA，請先準備以下工具與裝置。

需要一台 Mac 或 Windows 電腦，以及一台 iOS 裝置。

- Mac
  - iLoader for [Mac](https://github.com/nab138/iloader/releases/latest/download/iloader-darwin-universal.dmg)
- Windows
  - [iTunes](https://apple.co/ms)
  - [Apple Devices](https://apps.microsoft.com/detail/9np83lwlpz9k?hl=zh-TW&gl=TW)
  - iLoader [exe](https://github.com/nab138/iloader/releases/latest/download/iloader-windows-x64.exe) 或 [msi](https://github.com/nab138/iloader/releases/latest/download/iloader-windows-x64.msi) 擇一
- iOS
  - 安裝 [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)，用於 iOS 開發環境下的 VPN / 通訊設定
  - 請務必開啟 `開發者模式`

### 2. 取得 Pairing File

1. 電腦請先安裝對應的 iLoader
2. 安裝後打開 iLoader
3. 登入 Apple ID，並與 iPhone 完成配對
4. 在 iLoader 中選擇「管理配對檔案」
5. 點選「匯出」手動匯出 `pairingFile.plist`
6. 將 `pairingFile.plist` 檔案傳輸到 iOS 裝置的「檔案」App
- Mac 可使用 AirDrop
- Windows 可使用 Apple Devices

### 3. 側載 UFOGeo IPA

1. 下載最新的 [UFOGeo IPA](https://github.com/Leoohyeah/UFOGeo/releases/latest)
2. 開啟 iLoader
3. 登入 Apple ID，並與 iPhone 完成配對
4. 在 iLoader 選擇「匯入IPA」，選擇匯入剛下載的 UFOGeo IPA

### 4. 在 iOS 執行 UFOGeo App

1. 前往「設定 → 一般 → VPN 與裝置管理」，信任用來簽署 UFOGeo 的開發者憑證
2. 開啟 LocalDevVPN 點選 Connect
3. 開啟 UFOGeo App
4. 在匯入配對檔案的地方選擇剛剛放進裝置的 `pairingFile.plist`
5. Wi-Fi 情況下可正常使用；使用行動數據時，請先 `開關一次` 行動數據或飛航模式

## 致謝

- [StikDebug](https://github.com/StephenDev0/StikDebug)：提供相關裝置配對與通訊模式的參考範例
- [idevice](https://github.com/jkcoxson/idevice)：提供 iDevice 連線、配對 tunnel 與定位模擬能力
- [iLoader](https://github.com/nab138/iloader)：提供 macOS / Windows 環境下的配對與裝置連線工具支援

## 授權

本專案中由作者持有權利的程式碼採用 GNU Affero General Public License v3.0（AGPL-3.0）授權。

您可以依 AGPL-3.0 複製、修改及分發本專案。分發原始碼或執行檔，以及透過網路向使用者提供符合授權條件的修改版本時，須遵守 AGPL-3.0 對應條款，包括在適用情況下提供相對應來源程式碼與授權資訊。

完整授權條款請參閱 [LICENSE](LICENSE)；第三方元件適用各自的授權條款，詳見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

Copyright (C) 2026 Leoohyeah

## 隱私與資料處理

UFOGeo 會在使用者主動匯入後，將 pairing file 保存於 App 的本機沙盒，並僅用於與使用者自己的裝置建立本機開發測試連線。Pairing file 包含敏感的裝置信任憑證與私鑰，請勿分享給不信任的人員或服務。

UFOGeo 不會將 pairing file、收藏位置或模擬路線上傳至開發者控制的伺服器。解除安裝 UFOGeo 將一併移除 App 沙盒內保存的 pairing file 與相關資料。

UFOGeo 可能定期連線至 GitHub Releases API 檢查專案更新，GitHub 可能依其隱私權政策處理 IP 位址與標準網路請求資訊。地圖、位置搜尋及目前位置功能使用 Apple 提供的系統服務，相關資料處理由 Apple 的條款與隱私權政策規範。

## 使用聲明與免責

UFOGeo 的設計目的為合法的開發、測試、研究與教育用途。使用者應只操作自己擁有或已獲授權管理的裝置，並自行遵守所在地法律、平台規範及第三方服務條款。

請勿將本專案用於詐欺、冒用身分、偽造出勤紀錄、未經授權的裝置操作，或規避第三方服務的安全措施。

本段為專案用途與風險聲明，不構成對 AGPL-3.0 所授予權利的額外限制。軟體按現況提供，完整免責與責任限制以 [LICENSE](LICENSE) 中的 AGPL-3.0 條款為準。

## 第三方元件與授權

- [idevice](https://github.com/jkcoxson/idevice)：MIT License；本專案包含其 FFI 靜態函式庫

完整第三方授權通知請參閱 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 贊助

如果您喜歡這個專案，並希望支持後續維護與開發，歡迎透過以下方式贊助：

- :heart: [Portaly](https://portaly.cc/leoohyeah/support)

您的支持有助於維持專案開發、測試環境與持續更新。

## 備註

本專案依照實際用途與開發環境進行配置，使用者應自行確認相關工具、設備支援與平台規範。
