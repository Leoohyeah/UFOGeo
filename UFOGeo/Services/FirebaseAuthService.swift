import Combine
import Foundation

@MainActor
final class FirebaseAuthService: ObservableObject {
    static let shared = FirebaseAuthService()

    struct Session: Codable, Equatable {
        let uid: String
        let email: String
        var emailVerified: Bool
        var idToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    enum AuthError: LocalizedError {
        case notConfigured
        case notSignedIn
        case invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "登入功能目前無法使用，請稍後再試。"
            case .notSignedIn:
                return "請先登入 UFOGeo 帳號。"
            case .invalidResponse:
                return "暫時無法完成操作，請稍後再試。"
            case let .server(message):
                return message
            }
        }
    }

    @Published private(set) var session: Session?
    @Published private(set) var isWorking = false

    private static let keychainService = "tw.ufogeo.firebase-auth"
    private static let keychainAccount = "current-session"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var tokenRefreshTask: Task<String, Error>?
    private var tokenRefreshID: UUID?
    private var workingRequestCount = 0
    private var lastAccountReloadAt: Date?
    nonisolated private static let accountReloadFreshnessSeconds: TimeInterval = 2

    private init() {
        if let data = KeychainStore.data(
            service: Self.keychainService,
            account: Self.keychainAccount
        ) {
            session = try? decoder.decode(Session.self, from: data)
        }
    }

    var isSignedIn: Bool { session != nil }

    func register(email: String, password: String) async throws {
        try await performWorking {
            let response: TokenResponse = try await identityRequest(
                endpoint: "accounts:signUp",
                body: [
                    "email": normalizedEmail(email),
                    "password": password,
                    "returnSecureToken": true
                ]
            )
            try save(tokenResponse: response, emailVerified: false)
            try await sendVerificationEmailImpl()
        }
    }

    func signIn(email: String, password: String) async throws {
        try await performWorking {
            let response: TokenResponse = try await identityRequest(
                endpoint: "accounts:signInWithPassword",
                body: [
                    "email": normalizedEmail(email),
                    "password": password,
                    "returnSecureToken": true
                ]
            )
            try save(tokenResponse: response, emailVerified: false)
            try await reloadAccountImpl()
        }
    }

    func sendVerificationEmail() async throws {
        try await performWorking { try await sendVerificationEmailImpl() }
    }

    func reloadAccount(force: Bool = false) async throws {
        if !force,
           Self.accountReloadIsFresh(completedAt: lastAccountReloadAt) {
            return
        }
        try await performWorking { try await reloadAccountImpl() }
    }

    func sendPasswordReset(email: String) async throws {
        try await performWorking {
            let _: EmailActionResponse = try await identityRequest(
                endpoint: "accounts:sendOobCode",
                body: ["requestType": "PASSWORD_RESET", "email": normalizedEmail(email)],
                locale: "zh-TW"
            )
        }
    }

    func validIDToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = session else { throw AuthError.notSignedIn }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > 120 {
            return current.idToken
        }
        if let tokenRefreshTask {
            return try await tokenRefreshTask.value
        }

        let refreshID = UUID()
        let task = Task { @MainActor in
            try await refreshIDToken(from: current)
        }
        tokenRefreshID = refreshID
        tokenRefreshTask = task
        defer {
            if tokenRefreshID == refreshID {
                tokenRefreshTask = nil
                tokenRefreshID = nil
            }
        }
        return try await task.value
    }

    func signOut() {
        cancelTokenRefresh()
        lastAccountReloadAt = nil
        session = nil
        KeychainStore.remove(service: Self.keychainService, account: Self.keychainAccount)
        NotificationCenter.default.post(name: .firebaseAuthDidSignOut, object: nil)
    }

    private func sendVerificationEmailImpl() async throws {
        let idToken = try await validIDToken()
        let _: EmailActionResponse = try await identityRequest(
            endpoint: "accounts:sendOobCode",
            body: ["requestType": "VERIFY_EMAIL", "idToken": idToken],
            locale: "zh-TW"
        )
    }

    private func reloadAccountImpl() async throws {
        let idToken = try await validIDToken()
        let response: LookupResponse = try await identityRequest(
            endpoint: "accounts:lookup",
            body: ["idToken": idToken]
        )
        guard let user = response.users.first, var current = session else {
            throw AuthError.invalidResponse
        }
        current.emailVerified = user.emailVerified
        try persist(current)
        if user.emailVerified {
            // The email_verified claim is stored in the ID token. Refresh it
            // after the account lookup so checkout does not send the token
            // created before the user completed email verification.
            _ = try await validIDToken(forceRefresh: true)
        }
        lastAccountReloadAt = Date()
    }

    private func refreshIDToken(from current: Session) async throws -> String {
        let apiKey = try configuredAPIKey()
        guard let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(apiKey)") else {
            throw AuthError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedBody([
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken
        ])
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw decodeServerError(data) }
        let refreshed = try decoder.decode(RefreshResponse.self, from: data)
        guard refreshed.userID == current.uid,
              !refreshed.idToken.isEmpty,
              !refreshed.refreshToken.isEmpty,
              let expiresIn = TimeInterval(refreshed.expiresIn),
              expiresIn > 0 else {
            throw AuthError.invalidResponse
        }
        guard session?.uid == current.uid,
              session?.refreshToken == current.refreshToken else {
            throw CancellationError()
        }
        var updated = current
        updated.idToken = refreshed.idToken
        updated.refreshToken = refreshed.refreshToken
        updated.expiresAt = Date().addingTimeInterval(expiresIn)
        try persist(updated)
        return refreshed.idToken
    }

    private func identityRequest<Response: Decodable>(
        endpoint: String,
        body: [String: Any],
        locale: String? = nil
    ) async throws -> Response {
        let apiKey = try configuredAPIKey()
        guard let url = URL(
            string: "https://identitytoolkit.googleapis.com/v1/\(endpoint)?key=\(apiKey)"
        ) else { throw AuthError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Firebase uses this BCP-47 locale when it sends Auth emails. Keep it
        // optional so non-email Auth calls do not carry an unnecessary header.
        if let locale, !locale.isEmpty {
            request.setValue(locale, forHTTPHeaderField: "X-Firebase-Locale")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw decodeServerError(data) }
        return try decoder.decode(Response.self, from: data)
    }

    private func configuredAPIKey() throws -> String {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "FirebaseWebAPIKey") as? String,
              !key.isEmpty,
              !key.contains("$(") else { throw AuthError.notConfigured }
        return key
    }

    private func save(tokenResponse: TokenResponse, emailVerified: Bool) throws {
        cancelTokenRefresh()
        lastAccountReloadAt = nil
        let value = Session(
            uid: tokenResponse.localID,
            email: tokenResponse.email,
            emailVerified: emailVerified,
            idToken: tokenResponse.idToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn) ?? 3600)
        )
        try persist(value)
    }

    private func persist(_ value: Session) throws {
        try KeychainStore.set(
            encoder.encode(value),
            service: Self.keychainService,
            account: Self.keychainAccount
        )
        session = value
    }

    private func cancelTokenRefresh() {
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        tokenRefreshID = nil
    }

    nonisolated static func formEncodedBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let value = fields.keys.sorted().map { key in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let encodedValue = fields[key]?.addingPercentEncoding(
                withAllowedCharacters: allowed
            ) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(value.utf8)
    }

    private func performWorking(_ operation: () async throws -> Void) async throws {
        workingRequestCount += 1
        isWorking = true
        defer {
            workingRequestCount = max(0, workingRequestCount - 1)
            isWorking = workingRequestCount > 0
        }
        try await operation()
    }

    nonisolated static func accountReloadIsFresh(
        completedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let completedAt else { return false }
        let age = now.timeIntervalSince(completedAt)
        return age >= 0 && age < accountReloadFreshnessSeconds
    }

    private func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func decodeServerError(_ data: Data) -> AuthError {
        let code = (try? decoder.decode(FirebaseErrorResponse.self, from: data))?.error.message ?? "UNKNOWN"
        let message: String
        switch code.split(separator: ":").first.map(String.init) ?? code {
        case "EMAIL_EXISTS": message = "這個電子郵件已經註冊。"
        case "EMAIL_NOT_FOUND", "INVALID_LOGIN_CREDENTIALS", "INVALID_PASSWORD":
            message = "電子郵件或密碼不正確。"
        case "USER_DISABLED": message = "這個帳號已停用。"
        case "WEAK_PASSWORD": message = "密碼強度不足，請至少輸入 6 個字元。"
        case "INVALID_EMAIL": message = "電子郵件格式不正確。"
        case "TOO_MANY_ATTEMPTS_TRY_LATER": message = "嘗試次數過多，請稍後再試。"
        case "TOKEN_EXPIRED", "INVALID_ID_TOKEN", "USER_NOT_FOUND":
            message = "登入狀態已失效，請重新登入。"
        default: message = "登入失敗，請稍後再試。"
        }
        return .server(message)
    }
}

private struct TokenResponse: Decodable {
    let localID: String
    let email: String
    let idToken: String
    let refreshToken: String
    let expiresIn: String

    enum CodingKeys: String, CodingKey {
        case localID = "localId"
        case email, idToken, refreshToken, expiresIn
    }
}

private struct RefreshResponse: Decodable {
    let userID: String
    let idToken: String
    let refreshToken: String
    let expiresIn: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct LookupResponse: Decodable {
    struct User: Decodable { let emailVerified: Bool }
    let users: [User]
}

private struct EmailActionResponse: Decodable {
    let email: String?
}

private struct FirebaseErrorResponse: Decodable {
    struct Body: Decodable { let message: String }
    let error: Body
}

extension Notification.Name {
    static let firebaseAuthDidSignOut = Notification.Name("firebaseAuthDidSignOut")
}
