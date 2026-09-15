import SwiftUI

/// 版本更新提示視圖
struct UpdateAvailableView: View {
    @ObservedObject var updateManager: UpdateCheckManager
    @State private var isShowingUpdateAlert = false
    @State private var presentedVersion: String?
    @State private var isShowingOpenError = false
    @State private var openErrorMessage = ""

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("有新版本可用", isPresented: $isShowingUpdateAlert) {
                Button("前往 UFOGeo 首頁點擊安裝最新版") {
                    openUpdate(.liveContainer)
                }
                Button("下載 IPA") {
                    openUpdate(.downloadIPA)
                }
                Button("稍後", role: .cancel) { }
            } message: {
                Text(updateAlertMessage)
            }
            .alert("無法開啟更新", isPresented: $isShowingOpenError) {
                Button("確定", role: .cancel) {
                    openErrorMessage = ""
                }
            } message: {
                Text(openErrorMessage)
            }
            .onAppear {
                presentUpdateAlertIfNeeded()
            }
            .onChange(of: updateManager.hasUpdate) { _, _ in
                presentUpdateAlertIfNeeded()
            }
            .onChange(of: updateManager.latestVersion?.versionNumber) { _, _ in
                presentUpdateAlertIfNeeded()
            }
    }

    private var updateAlertMessage: String {
        guard let latestVersion = updateManager.latestVersion else { return "" }

        let body = latestVersion.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return "v\(latestVersion.versionNumber)"
        }

        let shortenedBody = String(body.prefix(100))
        let suffix = body.count > 100 ? "..." : ""
        return "v\(latestVersion.versionNumber)\n\(shortenedBody)\(suffix)"
    }

    private func presentUpdateAlertIfNeeded() {
        guard updateManager.hasUpdate,
              let version = updateManager.latestVersion?.versionNumber,
              presentedVersion != version,
              !isShowingUpdateAlert,
              !isShowingOpenError else { return }

        presentedVersion = version
        isShowingUpdateAlert = true
    }

    private func openUpdate(_ target: UpdateInstallTarget) {
        isShowingUpdateAlert = false

        updateManager.openUpdate(target: target) { success in
            guard !success else { return }

            switch target {
            case .liveContainer:
                openErrorMessage = "無法開啟 UFOGeo 安裝網頁。請確認網路連線後，在瀏覽器開啟 https://leoohyeah.github.io/UFOGeo/，再點擊「安裝最新版」。"
            case .downloadIPA:
                openErrorMessage = "無法開啟 IPA 下載頁面，請確認網路連線後再試。"
            }
            isShowingOpenError = true
        }
    }
}
