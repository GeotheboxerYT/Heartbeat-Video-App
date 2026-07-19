import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var authStore: AuthStore

    @AppStorage(AppSettings.Keys.defaultCameraPosition) private var defaultCameraPosition = "back"
    @AppStorage(AppSettings.Keys.rememberLastUsedCamera) private var rememberLastUsedCamera = true
    @AppStorage(AppSettings.Keys.autoPlayOnSessionOpen) private var autoPlayOnSessionOpen = false
    @AppStorage(AppSettings.Keys.chartScrubMode) private var chartScrubMode = "normal"
    @AppStorage(AppSettings.Keys.pvtResponseTimeoutSeconds) private var pvtResponseTimeoutSeconds = 2.0
    @AppStorage(AppSettings.Keys.pvtSoundEffectsEnabled) private var pvtSoundEffectsEnabled = true
    @AppStorage(AppSettings.Keys.pvtFlashFeedbackEnabled) private var pvtFlashFeedbackEnabled = true
    @AppStorage(AppSettings.Keys.requirePrePostPVTForRecording) private var requirePrePostPVTForRecording = false
    @AppStorage(AppSettings.Keys.pvtComparisonDurationSeconds) private var pvtComparisonDurationSeconds = 300
    @AppStorage(AppSettings.Keys.keepScreenAwakeDuringRecording) private var keepScreenAwakeDuringRecording = true
    @AppStorage(AppSettings.Keys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(AppSettings.Keys.apiBaseURL) private var apiBaseURL = "http://127.0.0.1:3000"
    @AppStorage(AppSettings.Keys.apiKey) private var apiKey = "pp_local_9f3k2m8x7q1w4z6r"

    @State private var storageBytes: Int64 = 0
    @State private var clearErrorMessage: String?
    @State private var showClearConfirm = false
    @State private var showDeleteAccountWarning = false
    @State private var showDeleteAccountFinalConfirm = false
    @State private var apiTestMessage: String?
    @State private var accountMessage: String?
    @State private var isDeletingAccount = false

    private let storage = SessionStorage()

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera") {
                    Picker("Default Camera", selection: $defaultCameraPosition) {
                        Text("Back").tag("back")
                        Text("Front").tag("front")
                    }
                    Toggle("Remember Last Used Camera", isOn: $rememberLastUsedCamera)
                }

                Section("Playback") {
                    Toggle("Auto-Play On Session Open", isOn: $autoPlayOnSessionOpen)
                    Picker("Chart Scrubbing", selection: $chartScrubMode) {
                        Text("Normal").tag("normal")
                        Text("Smooth").tag("smooth")
                    }
                }

                Section("PVT") {
                    Stepper(value: $pvtResponseTimeoutSeconds, in: 0.5...5.0, step: 0.1) {
                        Text("Miss Timeout: \(pvtResponseTimeoutSeconds, specifier: "%.1f")s")
                    }
                    Toggle("Sound Effects", isOn: $pvtSoundEffectsEnabled)
                    Toggle("Flash Feedback", isOn: $pvtFlashFeedbackEnabled)
                    Toggle("Require Pre/Post PVT for Recording", isOn: $requirePrePostPVTForRecording)
                    Picker("Comparison PVT Duration", selection: $pvtComparisonDurationSeconds) {
                        Text("5 Mins").tag(300)
                        Text("10 Mins").tag(600)
                    }
                }

                Section("App Behavior") {
                    Toggle("Keep Screen Awake During Recording", isOn: $keepScreenAwakeDuringRecording)
                    Toggle("Haptics", isOn: $hapticsEnabled)
                }

                Section("Backend API") {
                    TextField("API Base URL", text: $apiBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)

                    TextField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    Text("Use your live domain URL for production (example: https://api.yourdomain.com). Simulator can use 127.0.0.1; physical iPhone must use LAN IP or live domain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Test API Connection") {
                        Task {
                            await testAPIConnection()
                        }
                    }

                    if let apiTestMessage {
                        Text(apiTestMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Data") {
                    HStack {
                        Text("Local Storage Used")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text("Clear All Local Sessions")
                    }

                    if let clearErrorMessage {
                        Text(clearErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Account") {
                    if let username = authStore.currentUsername {
                        HStack {
                            Text("User")
                            Spacer()
                            Text(username)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let email = authStore.currentUserEmail {
                        HStack {
                            Text("Email")
                            Spacer()
                            Text(email)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteAccountWarning = true
                    } label: {
                        if isDeletingAccount {
                            ProgressView()
                        } else {
                            Text("Delete Account")
                        }
                    }
                    .disabled(isDeletingAccount)

                    Text("Deletes only account login data (username, email, password). Local sessions stay on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let accountMessage {
                        Text(accountMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        authStore.signOut()
                    } label: {
                        Text("Sign Out")
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersionLabel)
                            .foregroundStyle(.secondary)
                    }
                    Text("Workout video and heart-rate data are stored on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .task {
                refreshStorageUsage()
            }
            .onAppear {
                if ![300, 600].contains(pvtComparisonDurationSeconds) {
                    pvtComparisonDurationSeconds = 300
                }
                refreshStorageUsage()
            }
            .alert("Clear all local sessions?", isPresented: $showClearConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    clearAllSessions()
                }
            } message: {
                Text("This deletes all saved videos and heart-rate files on this device.")
            }
            .alert("Delete account?", isPresented: $showDeleteAccountWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Continue", role: .destructive) {
                    showDeleteAccountFinalConfirm = true
                }
            } message: {
                Text("This will remove your username, email, and password from this device.")
            }
            .alert("Final warning", isPresented: $showDeleteAccountFinalConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Account", role: .destructive) {
                    Task {
                        await deleteAccount()
                    }
                }
            } message: {
                Text("Local workout sessions will NOT be deleted.")
            }
        }
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func refreshStorageUsage() {
        storageBytes = storage.totalStorageBytes()
    }

    private func clearAllSessions() {
        do {
            try storage.clearAllSessions()
            clearErrorMessage = nil
            refreshStorageUsage()
        } catch {
            clearErrorMessage = "Could not clear sessions: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func deleteAccount() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        do {
            try await authStore.deleteCurrentAccountKeepSessions()
            accountMessage = nil
        } catch {
            accountMessage = "Could not delete account: \(error.localizedDescription). Try signing in again, then delete."
        }
    }

    @MainActor
    private func testAPIConnection() async {
        do {
            let health = try await APIClient.shared.healthCheck()
            apiTestMessage = "API: \(health.status), DB: \(health.db ?? "unknown")"
        } catch {
            apiTestMessage = "API test failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AuthStore())
}
