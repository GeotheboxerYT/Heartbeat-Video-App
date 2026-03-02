import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.Keys.defaultCameraPosition) private var defaultCameraPosition = "back"
    @AppStorage(AppSettings.Keys.rememberLastUsedCamera) private var rememberLastUsedCamera = true
    @AppStorage(AppSettings.Keys.autoPlayOnSessionOpen) private var autoPlayOnSessionOpen = false
    @AppStorage(AppSettings.Keys.chartScrubMode) private var chartScrubMode = "normal"
    @AppStorage(AppSettings.Keys.pvtResponseTimeoutSeconds) private var pvtResponseTimeoutSeconds = 2.0
    @AppStorage(AppSettings.Keys.pvtSoundEffectsEnabled) private var pvtSoundEffectsEnabled = true
    @AppStorage(AppSettings.Keys.pvtFlashFeedbackEnabled) private var pvtFlashFeedbackEnabled = true
    @AppStorage(AppSettings.Keys.requirePrePostPVTForRecording) private var requirePrePostPVTForRecording = false
    @AppStorage(AppSettings.Keys.pvtComparisonDurationSeconds) private var pvtComparisonDurationSeconds = 60
    @AppStorage(AppSettings.Keys.keepScreenAwakeDuringRecording) private var keepScreenAwakeDuringRecording = true
    @AppStorage(AppSettings.Keys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(AppSettings.Keys.apiBaseURL) private var apiBaseURL = "http://127.0.0.1:3000"
    @AppStorage(AppSettings.Keys.apiKey) private var apiKey = "pp_local_9f3k2m8x7q1w4z6r"

    @State private var storageBytes: Int64 = 0
    @State private var clearErrorMessage: String?
    @State private var showClearConfirm = false
    @State private var apiTestMessage: String?

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
                        Text("1 Mins").tag(60)
                        Text("3 Mins").tag(180)
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

                    Text("Simulator can use 127.0.0.1. Physical iPhone must use your Mac's LAN IP.")
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
}
