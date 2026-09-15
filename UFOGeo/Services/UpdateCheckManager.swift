import Combine
import Foundation
import UIKit

enum UpdateInstallTarget {
    case liveContainer
    case downloadIPA
}

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

    static let latestIPADownloadURLString =
        "https://github.com/Leoohyeah/UFOGeo/releases/latest/download/UFOGeo.ipa"

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

    /// 開啟更新方式。LiveContainer 安裝透過網站上的按鈕交給 LiveContainer。
    static func updateURL(for target: UpdateInstallTarget) -> URL? {
        switch target {
        case .liveContainer:
            return URL(string: "https://leoohyeah.github.io/UFOGeo/")
        case .downloadIPA:
            return URL(string: latestIPADownloadURLString)
        }
    }

    func openUpdate(
        target: UpdateInstallTarget,
        completion: @escaping (Bool) -> Void
    ) {
        guard let url = Self.updateURL(for: target) else {
            DispatchQueue.main.async {
                completion(false)
            }
            return
        }

        // UIApplication.open 的 completion handler 不保證在主執行緒呼叫，
        // 讓畫面安全更新錯誤提示與按鈕狀態。
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { success in
                DispatchQueue.main.async {
                    completion(success)
                }
            }
        }
    }

    /// 保留舊呼叫介面，預設開啟更新安裝網頁。
    func openUpdatePage(completion: @escaping (Bool) -> Void = { _ in }) {
        openUpdate(target: .liveContainer, completion: completion)
    }
}
