import SwiftUI

/// 版本更新提示視圖
struct UpdateAvailableView: View {
    @ObservedObject var updateManager: UpdateCheckManager
    @State private var isDismissed = false

    var body: some View {
        if !isDismissed, updateManager.hasUpdate, let latestVersion = updateManager.latestVersion {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("有新版本可用")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text("v\(latestVersion.versionNumber)")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }

                    Spacer()

                    Button(action: {
                        isDismissed = true
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                if !latestVersion.body.isEmpty {
                    Text(latestVersion.body.prefix(100) + "...")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button(action: {
                        updateManager.openUpdatePage()
                    }) {
                        Text("立即更新")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .cornerRadius(6)
                    }

                    Button(action: {
                        isDismissed = true
                    }) {
                        Text("稍後")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(12)
            .background(Color.gray.opacity(0.3))
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

#Preview {
    VStack {
        UpdateAvailableView(
            updateManager: {
                let manager = UpdateCheckManager()
                manager.hasUpdate = true
                manager.latestVersion = AppVersion(
                    tagName: "v1.1.0",
                    name: "Version 1.1.0",
                    body: "新增路線回放功能、修復位置更新延遲問題",
                    releaseDate: "2026-07-29",
                    downloadUrl: "https://github.com/Leoohyeah/UFOGeo-Health/releases"
                )
                return manager
            }()
        )

        Spacer()
    }
    .background(Color(.systemBackground))
}
