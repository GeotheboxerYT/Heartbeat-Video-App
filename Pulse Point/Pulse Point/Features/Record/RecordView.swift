import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var authStore: AuthStore
    @Environment(\.layoutViewportSize) private var layoutViewportSize
    @StateObject private var viewModel = RecordViewModel()
    @State private var isBluetoothPickerPresented = false
    @State private var isIntervalSettingsPresented = false

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: scaled(12)) {
                ZStack(alignment: .top) {
                    topStatusRow

                    recordingClockBadge
                }

                if !viewModel.isRecording {
                    recordingModeToggle
                    intervalBellPanel
                }

                Spacer(minLength: 0)

                if viewModel.captureVideoEnabled {
                    LiveHeartRateGraphOverlayView(
                        bpmPoints: viewModel.liveBPMGraphPoints,
                        primaryStrapPoints: viewModel.shouldRenderDualBluetoothGraph ? viewModel.firstStrapGraphPoints : nil,
                        secondaryStrapPoints: viewModel.shouldRenderDualBluetoothGraph ? viewModel.secondStrapGraphPoints : nil,
                        recordingElapsedSeconds: viewModel.recordingElapsedSeconds,
                        isLiveRecording: viewModel.isRecording
                    )
                        .frame(height: viewModel.isRecording ? scaled(120) : scaled(100))
                        .allowsHitTesting(false)
                        .padding(.bottom, viewModel.isRecording ? scaled(118) : scaled(132))
                } else {
                    dataOnlyPanel()
                        .padding(.bottom, viewModel.isRecording ? scaled(72) : 0)
                }
            }
            .padding(.horizontal, scaled(10))
            .padding(.top, scaled(viewModel.isRecording ? 22 : 18))
            .padding(.bottom, scaled(8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottomTrailing) {
            if !viewModel.isRecording {
                sourceOverlay
                    .padding(.trailing, scaled(10))
                    .padding(.bottom, scaled(78))
            }
        }
        .overlay(alignment: .top) {
            if viewModel.isRecording, viewModel.intervalBellEnabled {
                intervalLiveBadge
                    .padding(.top, scaled(58))
            }
        }
        .overlay(alignment: .bottom) {
            controlOverlay
                .padding(.horizontal, scaled(10))
                .padding(.bottom, scaled(viewModel.isRecording ? 10 : 10))
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    viewModel.updateCameraZoomGesture(scale: scale)
                }
                .onEnded { _ in
                    viewModel.endCameraZoomGesture()
                }
        )
        .toolbar(viewModel.isRecording ? .hidden : .visible, for: .tabBar)
        .task {
            syncViewModelUser()
            viewModel.loadParticipantProfiles(ownerKey: currentOwnerKey)
            await viewModel.prepare()
        }
        .onChange(of: authStore.currentUserEmail) { _, _ in
            syncViewModelUser()
            viewModel.loadParticipantProfiles(ownerKey: currentOwnerKey)
        }
        .onChange(of: authStore.currentUsername) { _, _ in
            syncViewModelUser()
        }
        .onChange(of: authStore.currentFirebaseUID) { _, _ in
            syncViewModelUser()
        }
        .onChange(of: authStore.currentUserProfile) { _, _ in
            syncViewModelUser()
        }
        .sheet(isPresented: $isBluetoothPickerPresented) {
            bluetoothDevicePickerSheet
        }
        .sheet(isPresented: $isIntervalSettingsPresented) {
            intervalSettingsSheet
        }
        .fullScreenCover(isPresented: $viewModel.isComparisonPVTPresented) {
            RecordPVTSessionView(
                durationSeconds: viewModel.comparisonPVTDurationSeconds,
                title: viewModel.activeComparisonPVTPhase == .pre ? "Pre-PVT" : "Post-PVT",
                onCancel: {
                    viewModel.cancelComparisonPVT()
                },
                onComplete: { result in
                    viewModel.completeComparisonPVT(with: result)
                }
            )
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if viewModel.captureVideoEnabled {
            CameraPreviewView(session: viewModel.cameraRecorder.captureSession)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .ignoresSafeArea(.container, edges: .all)
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.45),
                            Color.clear,
                            Color.black.opacity(0.55)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(.container, edges: .all)
                }
        } else {
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.03, green: 0.03, blue: 0.08),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea(.container, edges: .all)
        }
    }

    private var bpmStatusBadge: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(viewModel.primaryBPMLabel)
                .font(.system(size: scaled(14), weight: .black, design: .rounded))
                .italic()
                .foregroundStyle(bpmZoneColor(for: viewModel.currentBPM))

            if viewModel.selectedHeartRateSource == .bluetooth,
               !viewModel.displayedBluetoothReadings.isEmpty {
                let readings = Array(viewModel.displayedBluetoothReadings.prefix(3))
                ForEach(Array(readings.enumerated()), id: \.element.id) { index, reading in
                    HStack(spacing: 6) {
                        Text(viewModel.displayName(for: reading))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(reading.bpm > 0 ? "\(reading.bpm)" : "--")
                            .fontWeight(.bold)
                    }
                    .font(.system(size: scaled(10), weight: .semibold, design: .rounded))
                    .foregroundStyle(readingRowColor(at: index))
                }

                if viewModel.displayedBluetoothReadings.count > 3 {
                    Text("+\(viewModel.displayedBluetoothReadings.count - 3) more")
                        .font(.system(size: scaled(9), weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            if viewModel.captureVideoEnabled {
                Text(viewModel.cameraZoomLabel)
                    .font(.system(size: scaled(10), weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(scaled(10))
        .background(Color.black.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: scaled(10)))
    }

    @ViewBuilder
    private var topStatusRow: some View {
        if shouldShowDualTopBadges {
            HStack(alignment: .top) {
                if let first = dualTopReadings.first {
                    dualDeviceStatusBadge(for: first, index: 0, alignLeading: true)
                }

                Spacer(minLength: 0)

                if dualTopReadings.count > 1 {
                    dualDeviceStatusBadge(for: dualTopReadings[1], index: 1, alignLeading: false)
                }
            }
        } else {
            HStack(alignment: .top) {
                bpmStatusBadge
                Spacer(minLength: 0)
            }
        }
    }

    private func dualDeviceStatusBadge(
        for reading: ConnectedHeartRateReading,
        index: Int,
        alignLeading: Bool
    ) -> some View {
        VStack(alignment: alignLeading ? .leading : .trailing, spacing: 4) {
            Text(viewModel.displayName(for: reading))
                .lineLimit(1)
                .truncationMode(.tail)

            Text(reading.bpm > 0 ? "\(reading.bpm) BPM" : "--")
                .fontWeight(.bold)
                .foregroundStyle(readingRowColor(at: index))

            if viewModel.captureVideoEnabled && index == 0 {
                Text(viewModel.cameraZoomLabel)
                    .font(.system(size: scaled(9), weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .font(.system(size: scaled(10), weight: .semibold, design: .rounded))
        .padding(.horizontal, scaled(10))
        .padding(.vertical, scaled(7))
        .background(Color.black.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: scaled(10)))
        .frame(maxWidth: scaled(154), alignment: alignLeading ? .leading : .trailing)
    }

    private var recordingClockBadge: some View {
        Text(viewModel.isRecording ? viewModel.recordingElapsedLabel() : "00:00")
            .font(.system(size: scaled(16), weight: .black, design: .rounded))
            .italic()
            .monospacedDigit()
            .foregroundStyle(viewModel.isRecording ? .white : .white.opacity(0.82))
            .padding(.horizontal, scaled(12))
            .padding(.vertical, scaled(7))
            .background(
                Color.black.opacity(viewModel.isRecording ? (viewModel.captureVideoEnabled ? 0.50 : 0.75) : 0.32)
            )
            .clipShape(Capsule())
            .padding(.top, scaled(2))
            .zIndex(2)
    }

    private var recordingModeToggle: some View {
        HStack(spacing: scaled(8)) {
            modeButton(
                title: "Video + HR",
                icon: "video.fill",
                enabled: viewModel.captureVideoEnabled
            ) {
                viewModel.setCaptureVideoEnabled(true)
            }

            modeButton(
                title: "HR Only",
                icon: "waveform.path.ecg",
                enabled: !viewModel.captureVideoEnabled
            ) {
                viewModel.setCaptureVideoEnabled(false)
            }
        }
        .padding(scaled(7))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: scaled(15)))
    }

    private func modeButton(
        title: String,
        icon: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: scaled(13), weight: .black, design: .rounded))
                .italic()
                .foregroundStyle(enabled ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, scaled(12))
                .background(enabled ? Color.white : Color.black.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: scaled(13)))
        }
        .buttonStyle(.plain)
    }

    private var intervalBellPanel: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            HStack(spacing: scaled(8)) {
                Toggle(isOn: $viewModel.intervalBellEnabled) {
                    Label("Round Bell", systemImage: "bell.badge.fill")
                        .font(.system(size: scaled(13), weight: .black, design: .rounded))
                        .italic()
                }
                .tint(.orange)

                Button {
                    isIntervalSettingsPresented = true
                } label: {
                    Label("Set", systemImage: "slider.horizontal.3")
                        .font(.system(size: scaled(12), weight: .black, design: .rounded))
                        .padding(.horizontal, scaled(8))
                        .padding(.vertical, scaled(7))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange.opacity(0.9))
            }

            Text(intervalSetupSummary)
                .font(.system(size: scaled(10), weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(scaled(12))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: scaled(15)))
    }

    private var intervalLiveBadge: some View {
        HStack(spacing: scaled(7)) {
            Image(systemName: "bell.fill")
                .font(.system(size: scaled(11), weight: .black))
            Text(viewModel.intervalLiveLabel)
                .font(.system(size: scaled(12), weight: .black, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, scaled(10))
        .padding(.vertical, scaled(6))
        .background(Color.black.opacity(0.42))
        .clipShape(Capsule())
    }

    private func dataOnlyPanel() -> some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            LiveHeartRateGraphOverlayView(
                bpmPoints: viewModel.liveBPMGraphPoints,
                primaryStrapPoints: viewModel.shouldRenderDualBluetoothGraph ? viewModel.firstStrapGraphPoints : nil,
                secondaryStrapPoints: viewModel.shouldRenderDualBluetoothGraph ? viewModel.secondStrapGraphPoints : nil,
                recordingElapsedSeconds: viewModel.recordingElapsedSeconds,
                isLiveRecording: viewModel.isRecording
            )
                .frame(height: viewModel.isRecording ? scaled(180) : scaled(220))
                .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(scaled(12))
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: scaled(16)))
    }

    private var controlOverlay: some View {
        HStack(spacing: scaled(10)) {
            if viewModel.isRecording {
                Button {
                    viewModel.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .recordPrimaryButtonLabel(scale: uiScale)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: scaled(18)))
            } else {
                Button {
                    viewModel.startRecording()
                } label: {
                    Label("Start", systemImage: "record.circle.fill")
                        .recordPrimaryButtonLabel(scale: uiScale)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .background(viewModel.canStartRecording ? Color.white : Color.white.opacity(0.35))
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: scaled(18)))
                .disabled(!viewModel.canStartRecording)

                if viewModel.captureVideoEnabled {
                    Button {
                        viewModel.toggleCamera()
                    } label: {
                        Label("Flip", systemImage: "camera.rotate.fill")
                            .font(.system(size: scaled(13), weight: .black, design: .rounded).italic())
                            .padding(.horizontal, scaled(16))
                            .padding(.vertical, scaled(14))
                            .frame(minHeight: scaled(50))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Color.black.opacity(0.48))
                    .clipShape(RoundedRectangle(cornerRadius: scaled(18)))
                }
            }
        }
        .padding(scaled(10))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: scaled(20)))
    }

    private var sourceOverlay: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: scaled(12), weight: .black))

                Picker("Source", selection: $viewModel.selectedHeartRateSource) {
                    ForEach(HeartRateInputSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.system(size: scaled(13), weight: .black, design: .rounded))
            }

            if viewModel.selectedHeartRateSource == .bluetooth {
                HStack(spacing: 6) {
                    Button {
                        isBluetoothPickerPresented = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.text.square")
	                            Text(viewModel.bluetoothSelectionSummary)
	                                .lineLimit(1)
	                                .truncationMode(.tail)
	                        }
	                        .font(.system(size: scaled(12), weight: .black, design: .rounded))
	                        .padding(.horizontal, scaled(10))
	                        .padding(.vertical, scaled(10))
	                        .frame(width: scaled(146), alignment: .trailing)
	                    }
	                    .buttonStyle(.plain)
	                    .foregroundStyle(.white)
	                    .background(Color.white.opacity(0.16))
	                    .clipShape(RoundedRectangle(cornerRadius: scaled(13)))

	                    Button {
	                        viewModel.rescanBluetoothHeartRateDevices()
	                    } label: {
	                        Image(systemName: "arrow.clockwise")
	                            .font(.system(size: scaled(13), weight: .black))
	                            .padding(scaled(10))
	                    }
	                    .buttonStyle(.plain)
	                    .foregroundStyle(.white)
	                    .background(Color.white.opacity(0.16))
	                    .clipShape(RoundedRectangle(cornerRadius: scaled(13)))
	                }

                if !viewModel.selectedBluetoothDeviceIDs.isEmpty {
                    Text("\(viewModel.displayedBluetoothReadings.count)/\(viewModel.selectedBluetoothDeviceIDs.count) connected")
                        .font(.system(size: scaled(10), weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            viewModel.displayedBluetoothReadings.count == viewModel.selectedBluetoothDeviceIDs.count
                                ? Color.green
                                : Color.orange
                        )
                }
            } else {
                Button("Health Access") {
                    viewModel.requestAppleWatchPermission()
                }
                .buttonStyle(.plain)
                .font(.system(size: scaled(12), weight: .black, design: .rounded))
                .padding(.horizontal, scaled(12))
                .padding(.vertical, scaled(10))
                .foregroundStyle(.white)
                .background(Color.white.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: scaled(13)))
            }
        }
        .font(.system(size: scaled(12), weight: .semibold, design: .rounded))
        .padding(scaled(10))
        .background(Color.black.opacity(0.38))
        .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
    }

    private func readingRowColor(at index: Int) -> Color {
        guard shouldShowDualTopBadges || viewModel.shouldRenderDualBluetoothGraph else {
            return .white.opacity(0.95)
        }
        if index == 0 {
            return .blue
        }
        if index == 1 {
            return .red
        }
        return .white.opacity(0.95)
    }

    private func compactDeviceName(_ name: String) -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Device" }

        let tokens = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let candidate = tokens.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) ?? tokens.first ?? normalized

        if candidate.count <= 4 {
            return candidate
        }

        return "\(candidate.prefix(4))..."
    }

    private var bluetoothDevicePickerSheet: some View {
        NavigationStack {
            List {
                Section("Available Monitors") {
                    if viewModel.availableBluetoothDevices.isEmpty {
                        Text("No monitors found yet. Tap Rescan.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.availableBluetoothDevices) { device in
                            Button {
                                viewModel.toggleBluetoothDeviceSelection(device.id)
                            } label: {
                                pickerRow(
                                    title: device.displayName,
                                    subtitle: device.signalLabel,
                                    detail: viewModel.participantDetailLabel(for: device.id),
                                    isSelected: viewModel.isBluetoothDeviceSelected(device.id)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !viewModel.selectedBluetoothDeviceIDs.isEmpty {
                    Section("Participant Assignment") {
                        if viewModel.participantProfiles.isEmpty {
                            Text("Add participants in Extras -> PvP first.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(viewModel.selectedDevicesForParticipantAssignment) { device in
                                HStack(spacing: 10) {
                                    Text(compactDeviceName(device.displayName))
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)

                                    Spacer(minLength: 8)

                                    Menu {
                                        Button("Unassigned") {
                                            viewModel.assignParticipant(nil, to: device.id)
                                        }
                                        Divider()
                                        ForEach(viewModel.participantProfiles) { profile in
                                            Button {
                                                viewModel.assignParticipant(profile.id, to: device.id)
                                            } label: {
                                                if viewModel.participantAssignmentsByDevice[device.id] == profile.id {
                                                    Label(profile.displayName, systemImage: "checkmark")
                                                } else {
                                                    Text(profile.displayName)
                                                }
                                            }
                                        }
                                    } label: {
                                        Text(viewModel.participantName(for: device.id) ?? "Assign")
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Select Monitor")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Rescan") {
                        viewModel.rescanBluetoothHeartRateDevices()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isBluetoothPickerPresented = false
                    }
                }
            }
        }
    }

    private func pickerRow(
        title: String,
        subtitle: String?,
        detail: String?,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .green : .secondary)
        }
        .contentShape(Rectangle())
    }

    private var pvtOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PVT Comparison")
                .font(.subheadline.bold())

            ViewThatFits {
                HStack(spacing: 10) {
                    Button("Pre-PVT") {
                        viewModel.beginPrePVT()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canRunPrePVT)

                    Button("Post-PVT") {
                        viewModel.beginPostPVT()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canRunPostPVT)
                }

                VStack(spacing: 8) {
                    Button("Pre-PVT") {
                        viewModel.beginPrePVT()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canRunPrePVT)

                    Button("Post-PVT") {
                        viewModel.beginPostPVT()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canRunPostPVT)
                }
            }

            Text("Pre: \(viewModel.preSummaryText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("Post: \(viewModel.postSummaryText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func bpmZoneColor(for bpm: Int) -> Color {
        guard bpm > 0 else { return .white }

        switch HeartRateZone.zone(for: bpm) {
        case .easy:
            return .gray
        case .light:
            return Color(red: 0.47, green: 0.82, blue: 0.98)
        case .aerobic:
            return .green
        case .hard:
            return .yellow
        case .peak:
            return .red
        }
    }

    private var shouldShowDualTopBadges: Bool {
        viewModel.selectedHeartRateSource == .bluetooth && dualTopReadings.count >= 2
    }

    private var dualTopReadings: [ConnectedHeartRateReading] {
        viewModel.dualDisplayedBluetoothReadings
    }

    private var uiScale: CGFloat {
        let referenceWidth: CGFloat = 393 // iPhone 16 Pro width in points
        let referenceHeight: CGFloat = 852
        let measuredWidth = layoutViewportSize.width > 0 ? layoutViewportSize.width : UIScreen.main.bounds.width
        let measuredHeight = layoutViewportSize.height > 0 ? layoutViewportSize.height : UIScreen.main.bounds.height
        let rawScale = min(measuredWidth / referenceWidth, measuredHeight / referenceHeight)
        return min(max(rawScale, 0.88), 1.18)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        value * uiScale
    }

    private var intervalSetupSummary: String {
        guard viewModel.intervalBellEnabled else { return "Off" }
        return "Round \(viewModel.intervalRoundLabel) • Rest \(viewModel.intervalRestLabel) • Warn \(viewModel.intervalWarningLabel)"
    }

    private var intervalRoundBinding: Binding<Int> {
        Binding(
            get: { viewModel.intervalRoundSeconds },
            set: { viewModel.updateIntervalRoundSeconds($0) }
        )
    }

    private var intervalRestBinding: Binding<Int> {
        Binding(
            get: { viewModel.intervalRestSeconds },
            set: { viewModel.updateIntervalRestSeconds($0) }
        )
    }

    private var intervalWarningBinding: Binding<Int> {
        Binding(
            get: { viewModel.intervalWarningSeconds },
            set: { viewModel.updateIntervalWarningSeconds($0) }
        )
    }

    private var currentOwnerKey: String {
        authStore.currentUserEmail ?? authStore.currentUsername ?? "default"
    }

    private func syncViewModelUser() {
        viewModel.setCurrentUser(
            email: authStore.currentUserEmail,
            displayName: authStore.currentUsername,
            firebaseUID: authStore.currentFirebaseUID,
            profile: authStore.currentUserProfile
        )
    }

    private var intervalSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("Round Bell") {
                    Toggle("Enabled", isOn: $viewModel.intervalBellEnabled)
                }

                Section("Timing") {
                    Stepper(value: intervalRoundBinding, in: 10...3600, step: 5) {
                        HStack {
                            Text("Round")
                            Spacer()
                            Text(viewModel.intervalRoundLabel)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(value: intervalRestBinding, in: 0...1800, step: 5) {
                        HStack {
                            Text("Rest")
                            Spacer()
                            Text(viewModel.intervalRestLabel)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(value: intervalWarningBinding, in: 0...max(0, viewModel.intervalRoundSeconds - 1), step: 1) {
                        HStack {
                            Text("Warning")
                            Spacer()
                            Text(viewModel.intervalWarningLabel)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Round Bell")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isIntervalSettingsPresented = false
                    }
                }
            }
        }
    }
}

private extension View {
    func recordPrimaryButtonLabel(scale: CGFloat) -> some View {
        self
            .font(.system(size: 15 * scale, weight: .black, design: .rounded))
            .italic()
            .padding(.vertical, 15 * scale)
            .frame(minHeight: 54 * scale)
    }
}

#Preview {
    RecordView()
        .environmentObject(AuthStore())
}
