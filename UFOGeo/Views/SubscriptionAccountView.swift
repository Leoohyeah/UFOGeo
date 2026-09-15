import SwiftUI

struct SubscriptionAccountView: View {
    private static let privacyPolicyURL = URL(
        string: "https://leoohyeah.github.io/UFOGeo/privacy/"
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

    var body: some View {
        // Intentionally avoid lifecycle-triggered sync here. This screen is a
        // read/write surface only; refreshes are driven by explicit user actions
        // or the app-owned auth/session sync path, not by view appearance.
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
        .onChange(of: auth.session?.uid) { _, _ in
            // The view can survive a sign-out/sign-in cycle. Do not let the
            // previous UID's terminal sync flags make the new account appear
            // unavailable before its own membership request completes.
            initialSubscriptionSyncCompleted = false
            initialSubscriptionSyncFailed = false
        }
        .disabled(isBusy)
        .overlay {
            if isBusy {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text(busyStatusMessage)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
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

            if let expiringStage = portaly.subscription?.expiringStage {
                let (alertText, alertColor, alertIcon) = expiringStageAlert(expiringStage)
                if !alertText.isEmpty {
                    Label(alertText, systemImage: alertIcon)
                        .font(.caption)
                        .foregroundStyle(alertColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let recoveryStatusMessage = portaly.recoveryStatusMessage {
                Label(recoveryStatusMessage, systemImage: portaly.recoveryStatusIcon)
                    .font(.caption)
                    .foregroundStyle(recoveryStatusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            if portaly.shouldOfferSubscriptionRecovery {
                Button {
                    Task { await recoverExistingSubscription() }
                } label: {
                    Label(recoveryActionTitle, systemImage: "arrow.uturn.backward.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if membershipProjection.action.opensCheckout && !portaly.recoveryBlocksCheckout {
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
                        portaly.isPortalRequestInFlightForCurrentSession
                            ? "正在開啟訂閱管理…"
                            : "管理訂閱",
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
            || portaly.isLoadingForCurrentSession
            || portaly.isCheckoutRequestInFlightForCurrentSession
            || portaly.isPortalRequestInFlightForCurrentSession
            || portaly.isRecoveryRequestInFlight
    }

    private var membershipProjection: PortalyCheckoutService.MembershipProjection {
        let sharedSyncFlags = portaly.membershipSyncFlagsForCurrentSession
        return portaly.membershipProjection(
            initialSyncCompleted: initialSubscriptionSyncCompleted || sharedSyncFlags.completed,
            syncFailed: initialSubscriptionSyncFailed || sharedSyncFlags.failed
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

    private var recoveryStatusColor: Color {
        switch portaly.recoveryState {
        case .recovered, .alreadyBound:
            return .green
        case .inFlight:
            return .blue
        case .notFound:
            return .secondary
        case .ambiguous, .unavailable, .conflict, .safetyHold:
            return .orange
        case .idle:
            return .secondary
        }
    }

    private var busyStatusMessage: String {
        if portaly.isRecoveryRequestInFlight {
            return "正在從 Portaly 恢復…"
        }
        if portaly.isLoadingForCurrentSession {
            return "正在確認最新會員狀態…"
        }
        if portaly.isCheckoutRequestInFlightForCurrentSession {
            return "正在建立付款頁面…"
        }
        if portaly.isPortalRequestInFlightForCurrentSession {
            return "正在開啟訂閱管理…"
        }
        return "請稍候…"
    }

    private func noticeStyle(
        for kind: PortalyCheckoutService.MembershipProjection.Notice.Kind
    ) -> (icon: String, color: Color) {
        switch kind {
        case .grant: ("checkmark.seal.fill", .green)
        case .cancellation: ("calendar.badge.clock", .orange)
        }
    }

    private func expiringStageAlert(_ stage: String) -> (text: String, color: Color, icon: String) {
        let daysUntil = portaly.subscription?.daysUntilRenewal ?? 0
        let days = Int(ceil(daysUntil))
        
        switch stage {
        case "today":
            let daysText = days == 0 ? "今天" : "\(days) 天內"
            return (
                text: "Pro 訂閱將於 \(daysText)到期或續訂。請確認付款方式有效。",
                color: .red,
                icon: "exclamationmark.circle.fill"
            )
        case "soon":
            let daysText = days == 1 ? "1 天" : "\(days) 天"
            return (
                text: "Pro 訂閱將在 \(daysText)後到期。請確認付款方式有效，避免中斷。",
                color: .orange,
                icon: "exclamationmark.triangle.fill"
            )
        case "far":
            return (
                text: "Pro 訂閱即將到期；系統將於到期日期進行續訂。",
                color: .yellow,
                icon: "info.circle"
            )
        default:
            return (text: "", color: .secondary, icon: "")
        }
    }

    private var credentialsAreValid: Bool {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              password.count >= 6 else { return false }
        return entryMode == .signIn || password == passwordConfirmation
    }

    private var checkoutActionTitle: String {
        if portaly.isCheckoutRequestInFlightForCurrentSession {
            return "正在建立付款頁面…"
        }
        if portaly.isCheckoutLocked {
            return "付款頁面已建立，請稍候…"
        }
        return "訂閱 UFOGeo Pro"
    }

    private var recoveryActionTitle: String {
        switch portaly.recoveryState {
        case .notFound:
            return "再次尋找既有訂閱"
        case .ambiguous, .unavailable, .conflict, .safetyHold:
            return "重新嘗試恢復訂閱"
        default:
            return "從 Portaly 恢復既有訂閱"
        }
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
                present(
                    "帳號已建立",
                    "驗證信已寄出。完成驗證後，若你曾用這個 Email 在 Portaly 付款，系統會協助恢復既有 Pro 訂閱，不需要重新付款。"
                )
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
            guard expectedUID == nil || auth.session?.uid == expectedUID else { return }
            _ = try await portaly.refreshSubscription(force: force)
            guard expectedUID == nil || auth.session?.uid == expectedUID else { return }
            if portaly.shouldAttemptAutomaticSubscriptionRecovery {
                _ = try await portaly.recoverSubscription()
                guard expectedUID == nil || auth.session?.uid == expectedUID else { return }
            }
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

    private func recoverExistingSubscription() async {
        guard let expectedUID = auth.session?.uid else { return }
        do {
            let outcome = try await portaly.recoverSubscription(force: true)
            guard auth.session?.uid == expectedUID else { return }
            initialSubscriptionSyncCompleted = true
            initialSubscriptionSyncFailed = false
            switch outcome {
            case .recovered:
                present(
                    "Pro 訂閱已恢復",
                    "已將既有 Portaly Pro 訂閱綁定到目前 UFOGeo 帳號，不需要重新付款。"
                )
            case .alreadyBound:
                present(
                    "訂閱已確認",
                    "目前 UFOGeo 帳號已綁定既有 Portaly 訂閱，不需要重新付款。"
                )
            case .notFound:
                present(
                    "沒有找到既有訂閱",
                    "目前沒有符合此 Email、付款環境與方案的有效 Portaly Pro 訂閱。若要使用 Pro，可以開始新的訂閱。"
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard auth.session?.uid == expectedUID else { return }
            // The service records ambiguous, conflicting, and unavailable
            // recovery as checkout-blocking states. Keep the user-facing
            // error explicit so they do not mistake it for a payment failure.
            present("無法恢復既有訂閱", recoveryErrorMessage(for: error))
        }
    }

    private func recoveryErrorMessage(for error: Error) -> String {
        if let statusMessage = portaly.recoveryStatusMessage,
           portaly.recoveryState != .inFlight,
           portaly.recoveryState != .notFound {
            return statusMessage
        }
        return userFacingErrorMessage(error)
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
