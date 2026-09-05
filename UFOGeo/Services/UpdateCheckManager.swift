import Combine
import Foundation
import UIKit

final class UpdateCheckManager: ObservableObject {
    @Published var hasUpdate = false
    @Published var latestVersion: AppVersion?
    @Published var isChecking = false
    @Published var lastCheckDate: Date? {
        didSet {
            UserDefaults.standard.set(lastCheckDate, forKey: UserDefaults.Keys.lastUpdateCheckDate)
        }
    }

    private let repositoryOwner = "Leoohyeah"
    private let repositoryName = "UFOGeo"
    private let checkInterval: TimeInterval = 86400 // 24小時檢查一次
    private var cancellables = Set<AnyCancellable>()

    init() {
        lastCheckDate = UserDefaults.standard.object(forKey: UserDefaults.Keys.lastUpdateCheckDate) as? Date
    }

    /// 檢查是否應該進行版本檢查（24小時內不再檢查）
    func shouldCheckForUpdates() -> Bool {
        guard let lastCheck = lastCheckDate else { return true }
        return Date().timeIntervalSince(lastCheck) > checkInterval
    }

    /// 檢查是否有新版本
    func checkForUpdates() {
        guard !isChecking else { return }

        isChecking = true
        fetchLatestRelease()
    }

    /// 從 GitHub API 獲取最新 Release 信息
    private func fetchLatestRelease() {
        let urlString = "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest"
        
        guard let url = URL(string: urlString) else {
            isChecking = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response in
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: AppVersion.self, decoder: JSONDecoder())
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.isChecking = false
                    if case .failure(let error) = completion {
                        // 失敗時不寫入 lastCheckDate，讓下次啟動可以重試。
                        print("版本檢查失敗: \(error.localizedDescription)")
                    } else {
                        self?.lastCheckDate = Date()
                    }
                },
                receiveValue: { [weak self] version in
                    self?.latestVersion = version
                    self?.compareVersions(version)
                }
            )
            .store(in: &cancellables)
    }

    /// 比較版本
    private func compareVersions(_ remoteVersion: AppVersion) {
        let currentVersion = getCurrentAppVersion()
        hasUpdate = remoteVersion.isNewerThan(currentVersion)

        if hasUpdate {
            print("有新版本可用: \(remoteVersion.versionNumber) (當前: \(currentVersion))")
        }
    }

    /// 獲取當前應用版本
    private func getCurrentAppVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return "0.0.1"
    }

    /// 打開更新頁面
    func openUpdatePage() {
        guard let url = URL(string: "sidestore://install?url=https://github.com/Leoohyeah/UFOGeo/releases/latest/download/UFOGeo.ipa") else {
            return
        }
        UIApplication.shared.open(url)
    }
}
