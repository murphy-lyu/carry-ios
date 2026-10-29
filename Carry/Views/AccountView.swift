import SwiftUI
import AuthenticationServices

struct CarryAccountAvatar: View {
    let profile: CarryAccountProfile?
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(profile == nil ? Color(UIColor.tertiarySystemFill) : CarryAccent.color.opacity(0.15))
            if let initials = profile?.initials {
                Text(verbatim: initials)
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(CarryAccent.color)
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct CarryAccountEntry: View {
    @EnvironmentObject private var account: CarryAccountStore

    var body: some View {
        HStack(spacing: 14) {
            CarryAccountAvatar(profile: account.profile, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                if let name = account.profile?.displayName, !name.isEmpty {
                    Text(verbatim: name).font(.headline)
                } else {
                    Text(LocalizedStringKey(account.profile == nil ? "account.sign_in" : "account.title")).font(.headline)
                }
                Text(LocalizedStringKey(account.profile == nil ? "account.entry.detail" : account.statusKey))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension CarryAccountStore {
    var statusKey: String {
        switch state {
        case .signedOut: return "account.entry.detail"
        case .checking: return "account.status.checking"
        case .signedIn: return "account.status.no_trips"
        case .offline: return "account.status.offline"
        case .temporarilyUnavailable: return "account.status.unavailable"
        case .needsReauthentication: return "account.status.expired"
        case .deleting: return "account.delete.pending.title"
        }
    }

    /// Development inspection is session-only; it cannot create an authenticated identity.
    var showsEntry: Bool {
        #if DEBUG
        return isAvailable || ProcessInfo.processInfo.arguments.contains("--carry-account-design")
        #else
        return isAvailable
        #endif
    }
}

struct AccountView: View {
    @EnvironmentObject private var account: CarryAccountStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var showSignOut = false
    @State private var showDelete = false
    @State private var reauthorizingDeletion = false

    var body: some View {
        Group {
            if account.isDeleting { deletionProgress }
            else if let profile = account.profile { accountDetails(profile) }
            else { signInPage }
        }
        .navigationTitle(account.profile == nil && !account.isDeleting ? Text("account.sign_in") : Text("account.title"))
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.carryCanvas)
        .confirmationDialog("account.sign_out.confirm", isPresented: $showSignOut, titleVisibility: .visible) {
            Button("account.sign_out", role: .destructive) { Task { await account.signOut() } }
        } message: { Text("account.sign_out.detail") }
        .confirmationDialog("account.delete.confirm", isPresented: $showDelete, titleVisibility: .visible) {
            Button("account.delete.continue", role: .destructive) { reauthorizingDeletion = true }
        } message: { Text("account.delete.detail") }
        .onChange(of: account.state) { _, state in
            if state == .signedOut { reauthorizingDeletion = false }
        }
    }

    private var deletionProgress: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CarryAccountAvatar(profile: account.profile, size: 64)
                    .padding(.top, 32)
                Text("account.delete.pending.title")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text("account.delete.pending.detail")
                    .font(.body).foregroundStyle(.secondary)
                Button("account.delete.pending.refresh") { Task { await account.refresh() } }
                    .buttonStyle(.bordered).controlSize(.large).frame(minHeight: 44).disabled(account.isBusy)
                if account.isBusy { ProgressView() }
                errorMessage
            }
            .padding(.horizontal, 24).padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var signInPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CarryAccountAvatar(profile: nil, size: 64)
                    .padding(.top, 32)
                VStack(alignment: .leading, spacing: 12) {
                    Text("account.sign_in")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text("account.login.detail").font(.body).foregroundStyle(.secondary)
                }
                appleButton(.signIn)
                if !account.isAvailable {
                    Text("account.error.unavailable").font(.footnote).foregroundStyle(.secondary)
                }
                errorMessage
                Text("account.local_usage").font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 20) {
                    NavigationLink { PrivacyView() } label: { Text("settings.legal.privacy") }
                    NavigationLink { TermsView() } label: { Text("settings.legal.terms") }
                }
                .font(.footnote)
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func accountDetails(_ profile: CarryAccountProfile) -> some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    CarryAccountAvatar(profile: profile, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        if let name = profile.displayName, !name.isEmpty { Text(verbatim: name).font(.headline) }
                        else { Text("account.title").font(.headline) }
                        if let email = profile.email { Text(verbatim: email).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                Text(LocalizedStringKey(account.statusKey)).foregroundStyle(.secondary)
            }
            if !account.hasVerifiedSession {
                Section {
                    appleButton(.signIn)
                    Button("account.retry") { Task { await account.refresh() } }
                        .disabled(account.isBusy)
                }
            }
            Section {
                // Data migration and the new account API have their own release gates.
                // Never route this identity to the legacy device executor or auto-upload old trips.
                Text("account.sync.not_enabled").foregroundStyle(.secondary)
            } header: { Text("account.sync.title") }
              footer: { Text("account.sync.consent") }
            Section {
                Button("account.sign_out", role: .destructive) { showSignOut = true }
                    .disabled(account.isBusy)
                Button("account.delete", role: .destructive) { showDelete = true }
                    .disabled(account.isBusy)
                if reauthorizingDeletion {
                    Text("account.delete.reauthorize").font(.footnote).foregroundStyle(.secondary)
                    appleButton(.deleteAccount)
                    Button("Cancel", role: .cancel) { reauthorizingDeletion = false }
                        .disabled(account.isBusy)
                }
            }
            if account.error != nil { Section { errorMessage } }
        }
        .scrollContentBackground(.hidden)
    }

    private func appleButton(_ action: CarryAccountStore.AppleAction) -> some View {
        SignInWithAppleButton(.continue) { request in
            do {
                let challenge = try account.beginAppleAction(action)
                request.requestedScopes = [.fullName, .email]
                request.nonce = challenge.hashedNonce
                request.state = challenge.state
            } catch {
                // The button is disabled while unavailable/busy. No dummy nonce or fake session.
                account.failAppleAction(cancelled: false)
            }
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
                      let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) else {
                    account.failAppleAction(cancelled: false)
                    return
                }
                let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
                let value = CarryAppleCredential(idToken: token, authorizationCode: code,
                    appleUserID: credential.user, fullName: name, state: credential.state)
                Task { await account.completeAppleAction(value) }
            case .failure(let error):
                let cancelled = (error as? ASAuthorizationError)?.code == .canceled
                account.failAppleAction(cancelled: cancelled)
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(minHeight: 50, maxHeight: 50)
        .disabled(!account.isAvailable || account.isBusy)
        .accessibilityHint(Text("account.local_usage"))
        .overlay(alignment: .trailing) {
            if account.isBusy { ProgressView().padding(.trailing, 16).allowsHitTesting(false) }
        }
    }

    @ViewBuilder private var errorMessage: some View {
        if let error = account.error {
            Text(LocalizedStringKey(error.messageKey)).font(.footnote).foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
