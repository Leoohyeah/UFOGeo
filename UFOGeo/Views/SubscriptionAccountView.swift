import SwiftUI

struct SubscriptionAccountView: View {
    private static let privacyPolicyURL = URL(
        string: "https://ufogeo-adac7.web.app/privacy/"
    )!
    private static let supportURL = URL(
        string: "mailto:leoohyeah.app@gmail.com"
    )!

    private enum EntryMode: String, CaseIterable, Identifiable {
        case signIn = "登入"
        case register = "註冊"
        var id: String { rawValue }
    }

    @Environment(\.openURL) private var openURL
    @ObservedObject private var auth = FirebaseAuthService.shared
    @StateObject private var portaly = PortalyCheckoutService.shared
    @State private var entryMode: EntryMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var showDeleteConfirmation = false
    @State private var initialSubscriptionSyncCompleted = false
    @State private var initialSubscriptionSyncFailed = false
    @State private var initialSubscriptionSyncInFlight = false
    private static let initialSyncRetryDelayNanoseconds: UInt64 = 1_000_000_000

    var body: some View {
        Form {
            if let session = auth.session {
                signedInSection(session)
                subscriptionSection
                actionsSection
            } else {
                signInSection
            }
            legalSection
        }
        .navigationTitle("帳號與訂閱")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isBusy)
        .overlay {
            if isBusy {
                ProgressView()
                    .controlSize(.large)
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .confirmationDialog(
            "確定要永久刪除會員？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("永久刪除會員", role: .destructive) {
                Task { await deleteMemberAccount() }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("會員帳號和個人資料將永久刪除。若目前有 Pro 方案，系統會先停止下期續訂；刪除後將立即無法使用會員功能。依法必須保存的付款紀錄仍會保留。尚待確認的付款流程不會在此被取消，且可能暫時阻止帳號刪除。")
        }
        .task(id: auth.session?.uid) {
            initialSubscriptionSyncCompleted = false
            initialSubscriptionSyncFailed = false
            guard let uid = auth.session?.uid else { return }
            await refreshInitialAccountAndSubscription(expectedUID: uid)
        }
    }

    @ViewBuilder
    private func signedInSection(_ session: FirebaseAuthService.Session) -> some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.email)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("UFOGeo 會員")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Label(
                    session.emailVerified ? "已驗證" : "待驗證",
                    systemImage: session.emailVerified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(session.emailVerified ? .green : .orange)
            }
            .padding(.vertical, 6)

            if !session.emailVerified {
                Button {
                    Task {
                        do {
                            try await auth.sendVerificationEmail()
                            present("驗證信已寄出", "請到信箱完成驗證，再回到這裡按「我已完成驗證」。")
                        } catch { presentError(error) }
                    }
                } label: {
                    Label("重新寄送驗證信", systemImage: "envelope.fill")
                }

                Button {
                    Task {
                        await refreshAccountAndSubscription(
                            force: true,
                            showError: true,
                            forceAuthReload: true
                        )
                    }
                } label: {
                    Label("我已完成驗證", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text("會員資料")
        }
    }

    private var subscriptionSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                Text("UFOGeo Pro")
                    .font(.headline)

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(membershipProjection.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(membershipColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(membershipColor.opacity(0.12), in: Capsule())

                    Text(membershipProjection.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.vertical, 4)

            if membershipProjection.entitlement == .checking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在確認最新會員狀態…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(membershipProjection.guidance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(membershipProjection.notices.enumerated()), id: \.offset) { _, notice in
                let style = noticeStyle(for: notice.kind)
                Label(notice.text, systemImage: style.icon)
                    .font(.caption)
                    .foregroundStyle(style.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if membershipProjection.isTestMode {
                Label("目前為測試付款模式，不會扣款。", systemImage: "testtube.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if membershipProjection.action.opensCheckout {
                Button {
                    Task {
                        do {
                            let url = try await portaly.createCheckoutURL()
                            openURL(url)
                        }
                        catch { presentError(error) }
                    }
                } label: {
                    Label(checkoutActionTitle, systemImage: "creditcard.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(portaly.isCheckoutLocked)
            }

            if membershipProjection.action.opensPortal {
                Button {
                    Task {
                        do {
                            let url = try await portaly.createPortalURL()
                            openURL(url)
                        }
                        catch { presentError(error) }
                    }
                } label: {
                    Label(
                        portaly.isPortalRequestInFlight
                            ? "正在開啟訂閱管理…"
                            : membershipProjection.action.title ?? "管理訂閱",
                        systemImage: "creditcard.and.123"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if membershipProjection.action == .refresh {
                Button {
                    guard let uid = auth.session?.uid else { return }
                    initialSubscriptionSyncFailed = false
                    Task {
                        await refreshAccountAndSubscription(
                            force: true,
                            showError: true,
                            expectedUID: uid
                        )
                    }
                } label: {
                    Label(
                        membershipProjection.action.title ?? "重新同步",
                        systemImage: "arrow.clockwise"
                    )
                }
            }

        } header: {
            Text("方案與訂閱")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                portaly.clearLocalState()
                auth.signOut()
                password = ""
            } label: {
                Label("登出", systemImage: "rectangle.portrait.and.arrow.right")
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("刪除會員", systemImage: "person.crop.circle.badge.minus")
            }
        } header: {
            Text("帳號操作")
        } footer: {
            Text("刪除會員時會先停止有效 Pro 方案的下期續訂；尚待確認的付款流程不會在此被取消。刪除後無法復原。")
        }
    }

    private var legalSection: some View {
        Section("隱私與支援") {
            Link(destination: Self.privacyPolicyURL) {
                Label("隱私權政策", systemImage: "hand.raised.fill")
            }
            Link(destination: Self.supportURL) {
                Label("Email 聯絡與支援", systemImage: "envelope.fill")
            }
        }
    }

    private var signInSection: some View {
        Section {
            Picker("帳號動作", selection: $entryMode) {
                ForEach(EntryMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)

            TextField("電子郵件", text: $email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .autocorrectionDisabled()

            SecureField("密碼（至少 6 個字元）", text: $password)
                .textContentType(entryMode == .register ? .newPassword : .password)

            if entryMode == .register {
                SecureField("再次輸入密碼", text: $passwordConfirmation)
                    .textContentType(.newPassword)

                if !passwordConfirmation.isEmpty, password != passwordConfirmation {
                    Label("兩次輸入的密碼不一致", systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .trailing, spacing: 10) {
                if entryMode == .signIn {
                    Button("忘記密碼？") {
                        Task {
                            do {
                                try await auth.sendPasswordReset(email: email)
                                present("重設信已寄出", "請到信箱開啟密碼重設連結。")
                            } catch { presentError(error) }
                        }
                    }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button {
                    Task { await submitCredentials() }
                } label: {
                    Text(entryMode.rawValue)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!credentialsAreValid)
            }
        } header: {
            Text("UFOGeo 帳號")
        }
    }

    private var isBusy: Bool {
        auth.isWorking
            || portaly.isLoading
            || portaly.isCheckoutRequestInFlight
            || portaly.isPortalRequestInFlight
            || initialSubscriptionSyncInFlight
    }

    private var membershipProjection: PortalyCheckoutService.MembershipProjection {
        portaly.membershipProjection(
            initialSyncCompleted: initialSubscriptionSyncCompleted,
            syncFailed: initialSubscriptionSyncFailed
        )
    }

    private var membershipColor: Color {
        switch membershipProjection.tone {
        case .neutral: .secondary
        case .positive: .green
        case .attention: .orange
        case .progress: .blue
        }
    }

    private func noticeStyle(
        for kind: PortalyCheckoutService.MembershipProjection.Notice.Kind
    ) -> (icon: String, color: Color) {
        switch kind {
        case .grant: ("checkmark.seal.fill", .green)
        case .cancellation: ("calendar.badge.clock", .orange)
        }
    }

    private var credentialsAreValid: Bool {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              password.count >= 6 else { return false }
        return entryMode == .signIn || password == passwordConfirmation
    }

    private var checkoutActionTitle: String {
        if portaly.isCheckoutRequestInFlight {
            return "正在建立付款頁面…"
        }
        if portaly.isCheckoutLocked {
            return "付款頁面已建立，請稍候…"
        }
        return membershipProjection.action.title ?? "訂閱 UFOGeo Pro"
    }

    private func submitCredentials() async {
        do {
            switch entryMode {
            case .signIn:
                try await auth.signIn(email: email, password: password)
            case .register:
                guard password == passwordConfirmation else {
                    present("無法註冊", "兩次輸入的密碼不一致，請重新確認。")
                    return
                }
                try await auth.register(email: email, password: password)
                present("帳號已建立", "驗證信已寄出。完成驗證後即可開始訂閱。")
            }
            password = ""
            passwordConfirmation = ""
        } catch {
            presentError(error)
        }
    }

    private func refreshAccountAndSubscription(
        force: Bool,
        showError: Bool,
        expectedUID: String? = nil,
        forceAuthReload: Bool = false
    ) async {
        do {
            while auth.isWorking {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if auth.session?.emailVerified != true {
                try await auth.reloadAccount(force: forceAuthReload)
            }
            _ = try await portaly.refreshSubscription(force: force)
            guard expectedUID == nil || auth.session?.uid == expectedUID else { return }
            if force {
                initialSubscriptionSyncCompleted = true
                initialSubscriptionSyncFailed = false
            }
        } catch {
            guard expectedUID == nil || auth.session?.uid == expectedUID else { return }
            if force, !initialSubscriptionSyncCompleted {
                initialSubscriptionSyncFailed = true
            }
            if showError { presentError(error) }
        }
    }

    private func refreshInitialAccountAndSubscription(expectedUID: String) async {
        guard !initialSubscriptionSyncInFlight else { return }
        if portaly.hasRecentlyValidatedEntitlement,
           auth.session?.uid == expectedUID {
            initialSubscriptionSyncCompleted = true
            initialSubscriptionSyncFailed = false
            return
        }
        initialSubscriptionSyncInFlight = true
        defer { initialSubscriptionSyncInFlight = false }
        for attempt in 0..<2 {
            guard !Task.isCancelled else { return }
            if attempt > 0 {
                do {
                    try await Task.sleep(nanoseconds: Self.initialSyncRetryDelayNanoseconds)
                } catch {
                    return
                }
            }
            await refreshAccountAndSubscription(
                force: true,
                showError: false,
                expectedUID: expectedUID
            )
            guard !Task.isCancelled else { return }
            guard auth.session?.uid == expectedUID else { return }
            if initialSubscriptionSyncCompleted { return }
        }
    }

    private func deleteMemberAccount() async {
        do {
            try await portaly.deleteMemberAccount()
            auth.signOut()
            email = ""
            password = ""
            passwordConfirmation = ""
            present("會員已刪除", "會員帳號與個人資料已刪除。")
        } catch {
            presentError(error)
        }
    }

    private func present(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }

    private func presentError(_ error: Error) {
        present("操作失敗", userFacingErrorMessage(error))
    }

    private func userFacingErrorMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "目前沒有網路連線，請確認網路後再試一次。"
            case .timedOut:
                return "連線時間過久，請稍後再試。"
            default:
                return "目前無法連線，請稍後再試。"
            }
        } else if error is DecodingError {
            return "暫時無法完成操作，請稍後再試。"
        } else {
            return error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { SubscriptionAccountView() }
}
