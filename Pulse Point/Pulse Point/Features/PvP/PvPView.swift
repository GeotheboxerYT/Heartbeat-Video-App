import SwiftUI

struct PvPView: View {
    @EnvironmentObject private var authStore: AuthStore

    @State private var profiles: [PvPParticipantProfile] = []
    @State private var persistedAssignments: [UUID: UUID] = [:]
    @State private var activeAssignments: [UUID: UUID] = [:]

    @State private var sessionOptions: [SessionOption] = []
    @State private var selectedSessionID: String?
    @State private var selectedSessionSeries: [HeartRateDeviceSeries] = []

    @State private var profileDraft: ProfileDraft?
    @State private var pendingDeleteProfile: PvPParticipantProfile?
    @State private var saveError: String?

    private let store = PvPProfileStore()
    private let sessionStorage = SessionStorage()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("PvP Heart Rate")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Assign each strap to a person profile, then compare detailed percentage metrics for peak, recovery, and climb consistency with a balanced normalized score.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                participantsCard
                sessionCard

                if !selectedSessionSeries.isEmpty {
                    assignmentsCard
                }

                if competitorResults.count >= 2 {
                    winnersCard
                    scoringModelCard
                    scoreboardCard
                } else if !selectedSessionSeries.isEmpty {
                    Text("Assign at least two straps to profiles to run PvP scoring.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .task {
            reloadAll()
        }
        .onChange(of: authStore.currentUserEmail) { _, _ in
            reloadAll()
        }
        .onChange(of: selectedSessionID) { _, _ in
            loadSelectedSessionSeries()
        }
        .sheet(item: $profileDraft) { draft in
            PvPProfileEditorView(
                draft: draft,
                onCancel: {
                    profileDraft = nil
                },
                onSave: { updated in
                    saveProfile(updated)
                    profileDraft = nil
                }
            )
        }
        .alert(item: $pendingDeleteProfile) { profile in
            Alert(
                title: Text("Delete \(profile.displayName)?"),
                message: Text("This removes the profile from PvP mode. Recorded sessions remain saved."),
                primaryButton: .destructive(Text("Delete")) {
                    deleteProfile(profile)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var participantsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Participants")
                    .font(.headline)
                Spacer()
                Button {
                    profileDraft = .new()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if profiles.isEmpty {
                Text("No participant profiles yet. Add one for each person using a strap.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profiles) { profile in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text(profileDetailLine(profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            profileDraft = .from(profile)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            pendingDeleteProfile = profile
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PvP Session")
                    .font(.headline)
                Spacer()
                Button {
                    reloadSessions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            if sessionOptions.isEmpty {
                Text("No multi-strap sessions found yet. Record a session with 2+ straps first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(sessionOptions) { option in
                        Button(option.label) {
                            selectedSessionID = option.id
                        }
                    }
                } label: {
                    Label(selectedSessionLabel, systemImage: "calendar")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Text("Only sessions with saved per-strap data appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var assignmentsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Strap Assignments")
                .font(.headline)

            ForEach(selectedSessionSeries) { series in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(series.deviceName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(series.samples.count) samples")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Menu {
                        Button("Unassigned") {
                            setAssignment(nil, for: series.deviceID)
                        }
                        if !profiles.isEmpty {
                            Divider()
                        }
                        ForEach(profiles) { profile in
                            Button {
                                setAssignment(profile.id, for: series.deviceID)
                            } label: {
                                if activeAssignments[series.deviceID] == profile.id {
                                    Label(profile.displayName, systemImage: "checkmark")
                                } else {
                                    Text(profile.displayName)
                                }
                            }
                        }
                    } label: {
                        Text(assignedName(for: series.deviceID))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var winnersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Category Winners")
                .font(.headline)

            if let balanced = balancedWinner {
                winnerRow(
                    title: "Balanced Winner",
                    value: "\(balanced.balancedScore)",
                    winner: balanced.profile.displayName
                )
            }

            if let highest = highestWinner {
                winnerRow(
                    title: "Highest Peak Utilization",
                    value: "\(highest.peakUtilizationPercent)%",
                    winner: highest.profile.displayName
                )
            }

            if let longest = longestWinner {
                winnerRow(
                    title: "Longest High Effort",
                    value: "\(Int((longest.highEffortRatio * 100).rounded()))%",
                    winner: longest.profile.displayName
                )
            }

            if let recoveryDrop = recoveryDropWinner {
                winnerRow(
                    title: "Best Recovery Drop",
                    value: "\(recoveryDrop.recoveryDropPercent)%",
                    winner: recoveryDrop.profile.displayName
                )
            }

            if let recoveryRate = recoveryRateWinner {
                winnerRow(
                    title: "Fastest Recovery Rate",
                    value: "\(recoveryRate.recoveryRatePercent)%",
                    winner: recoveryRate.profile.displayName
                )
            }

            if let climb = climbConsistencyWinner {
                winnerRow(
                    title: "Best Climb Consistency",
                    value: "\(climb.climbConsistencyPercent)%",
                    winner: climb.profile.displayName
                )
            }

            if let stable = consistencyWinner {
                winnerRow(
                    title: "Most Stable Heart Rate",
                    value: "\(stable.steadyConsistencyPercent)%",
                    winner: stable.profile.displayName
                )
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var scoringModelCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Balanced Scoring Model")
                .font(.headline)

            Text("Base = 55% effort + 25% recovery + 20% stability")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Effort = 35% peak utilization + 20% high-effort time + 15% average utilization + 10% near-peak hold + 20% climb consistency")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Recovery = 65% drop from peak + 35% drop speed (both normalized to percent)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Profile adjustment = small add/deduct from age, body profile, gender, and training experience")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var scoreboardCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scoreboard")
                .font(.headline)

            ForEach(sortedResults) { result in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.profile.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text("Peak \(result.peakUtilizationPercent)% • Avg \(result.averageUtilizationPercent)% • High \(result.highEffortRatioPercent)% • Hold \(result.nearPeakHoldPercent)%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Recovery Drop \(result.recoveryDropPercent)% • Recovery Rate \(result.recoveryRatePercent)% • Climb \(result.climbConsistencyPercent)% (\(result.climbRateBPMPerMinute) bpm/min) • Stability \(result.steadyConsistencyPercent)% • Adj \(profileAdjustmentLabel(result.profileAdjustmentPoints))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Peak \(result.maxBPM) bpm → Floor \(result.recoveryFloorBPM) bpm in \(formatTime(result.recoveryTimeSeconds))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("\(result.balancedScore)")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.08))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var ownerKey: String {
        authStore.currentUserEmail ?? authStore.currentUsername ?? "default"
    }

    private var selectedSessionLabel: String {
        guard let selectedSessionID,
              let selected = sessionOptions.first(where: { $0.id == selectedSessionID }) else {
            return "Select Session"
        }
        return selected.label
    }

    private var competitorResults: [CompetitorResult] {
        selectedSessionSeries.compactMap { series in
            guard let profileID = activeAssignments[series.deviceID],
                  let profile = profiles.first(where: { $0.id == profileID }),
                  !series.samples.isEmpty else {
                return nil
            }
            return buildResult(profile: profile, samples: series.samples)
        }
    }

    private var balancedWinner: CompetitorResult? {
        competitorResults.max { lhs, rhs in lhs.balancedScore < rhs.balancedScore }
    }

    private var highestWinner: CompetitorResult? {
        competitorResults.max { lhs, rhs in lhs.peakUtilizationPercent < rhs.peakUtilizationPercent }
    }

    private var longestWinner: CompetitorResult? {
        competitorResults.max { lhs, rhs in lhs.highEffortRatio < rhs.highEffortRatio }
    }

    private var recoveryDropWinner: CompetitorResult? {
        competitorResults.max { lhs, rhs in lhs.recoveryDropPercent < rhs.recoveryDropPercent }
    }

    private var recoveryRateWinner: CompetitorResult? {
        competitorResults.max { lhs, rhs in lhs.recoveryRatePercent < rhs.recoveryRatePercent }
    }

    private var climbConsistencyWinner: CompetitorResult? {
        competitorResults.max { lhs, rhs in lhs.climbConsistencyPercent < rhs.climbConsistencyPercent }
    }

    private var consistencyWinner: CompetitorResult? {
        competitorResults.max { lhs, rhs in lhs.steadyConsistencyPercent < rhs.steadyConsistencyPercent }
    }

    private var sortedResults: [CompetitorResult] {
        competitorResults.sorted { lhs, rhs in
            if lhs.balancedScore == rhs.balancedScore {
                if lhs.recoveryScorePercent == rhs.recoveryScorePercent {
                    return lhs.peakUtilizationPercent > rhs.peakUtilizationPercent
                }
                return lhs.recoveryScorePercent > rhs.recoveryScorePercent
            }
            return lhs.balancedScore > rhs.balancedScore
        }
    }

    private func reloadAll() {
        loadProfiles()
        reloadSessions()
    }

    private func loadProfiles() {
        let bundle = store.loadBundle(ownerKey: ownerKey)
        profiles = bundle.profiles.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        persistedAssignments = bundle.deviceAssignments.reduce(into: [:]) { partial, entry in
            guard let deviceID = UUID(uuidString: entry.key) else { return }
            partial[deviceID] = entry.value
        }
    }

    private func reloadSessions() {
        let sessions = sessionStorage.listSessions()
        let options = sessions.compactMap { files -> SessionOption? in
            let series = sessionStorage.loadHeartRateDeviceSeries(from: files.heartRateDeviceSeriesURL)
            guard series.count >= 2 else { return nil }
            let metadata = sessionStorage.loadMetadata(from: files.metadataURL)
            let date = metadata?.startedAt ?? Date()
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let label = "\(formatter.string(from: date)) • \(series.count) straps"
            return SessionOption(id: files.sessionID, files: files, startedAt: date, label: label)
        }.sorted { lhs, rhs in
            lhs.startedAt > rhs.startedAt
        }

        sessionOptions = options
        if let selectedSessionID,
           options.contains(where: { $0.id == selectedSessionID }) {
            loadSelectedSessionSeries()
        } else {
            selectedSessionID = options.first?.id
            loadSelectedSessionSeries()
        }
    }

    private func loadSelectedSessionSeries() {
        guard let selectedSessionID,
              let option = sessionOptions.first(where: { $0.id == selectedSessionID }) else {
            selectedSessionSeries = []
            activeAssignments = [:]
            return
        }

        let series = sessionStorage.loadHeartRateDeviceSeries(from: option.files.heartRateDeviceSeriesURL)
        selectedSessionSeries = series

        var nextAssignments: [UUID: UUID] = [:]
        for item in series {
            guard let profileID = persistedAssignments[item.deviceID],
                  profiles.contains(where: { $0.id == profileID }) else {
                continue
            }
            nextAssignments[item.deviceID] = profileID
        }
        activeAssignments = nextAssignments
    }

    private func setAssignment(_ profileID: UUID?, for deviceID: UUID) {
        if let profileID {
            activeAssignments = activeAssignments.filter { key, value in
                key == deviceID || value != profileID
            }
            persistedAssignments = persistedAssignments.filter { key, value in
                key == deviceID || value != profileID
            }
            activeAssignments[deviceID] = profileID
            persistedAssignments[deviceID] = profileID
        } else {
            activeAssignments.removeValue(forKey: deviceID)
            persistedAssignments.removeValue(forKey: deviceID)
        }
        persistBundle()
    }

    private func assignedName(for deviceID: UUID) -> String {
        guard let profileID = activeAssignments[deviceID],
              let profile = profiles.first(where: { $0.id == profileID }) else {
            return "Assign Profile"
        }
        return profile.displayName
    }

    private func saveProfile(_ draft: ProfileDraft) {
        let updated = PvPParticipantProfile(
            id: draft.profileID ?? UUID(),
            displayName: draft.displayName,
            age: draft.age,
            weightLb: draft.weightLb,
            heightFeet: draft.heightFeet,
            gender: draft.gender,
            trainingExperience: draft.trainingExperience,
            updatedAt: Date()
        )

        if let existingIndex = profiles.firstIndex(where: { $0.id == updated.id }) {
            profiles[existingIndex] = updated
        } else {
            profiles.append(updated)
        }
        profiles.sort { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        persistBundle()
    }

    private func deleteProfile(_ profile: PvPParticipantProfile) {
        profiles.removeAll { $0.id == profile.id }
        persistedAssignments = persistedAssignments.filter { $0.value != profile.id }
        activeAssignments = activeAssignments.filter { $0.value != profile.id }
        persistBundle()
    }

    private func persistBundle() {
        let assignmentMap = persistedAssignments.reduce(into: [String: UUID]()) { partial, entry in
            partial[entry.key.uuidString] = entry.value
        }
        let bundle = PvPProfileBundle(
            profiles: profiles,
            deviceAssignments: assignmentMap
        )

        do {
            try store.saveBundle(bundle, ownerKey: ownerKey)
            saveError = nil
        } catch {
            saveError = "PvP save failed: \(error.localizedDescription)"
        }
    }

    private func buildResult(profile: PvPParticipantProfile, samples: [HeartRateSample]) -> CompetitorResult {
        let orderedSamples = samples.sorted { lhs, rhs in lhs.t < rhs.t }
        let maxBPM = orderedSamples.map(\.bpm).max() ?? 0
        let avgBPM = orderedSamples.isEmpty ? 0 : Int((Double(orderedSamples.map(\.bpm).reduce(0, +)) / Double(orderedSamples.count)).rounded())
        let estimatedMaxBPM = estimatedMaxBPM(for: profile)
        let highEffortThreshold = personalHighEffortThreshold(estimatedMaxBPM: estimatedMaxBPM)
        let highEffortSeconds = durationAboveThreshold(samples: orderedSamples, threshold: highEffortThreshold)
        let sessionDuration = trackedDuration(samples: orderedSamples)
        let highEffortRatio = sessionDuration > 0 ? min(1, highEffortSeconds / sessionDuration) : 0
        let steadyConsistencyPercent = consistencyScore(samples: orderedSamples)
        let relativePeak = normalizedRatio(value: maxBPM, baseline: estimatedMaxBPM, upperCap: 1.15)
        let relativeAverage = normalizedRatio(value: avgBPM, baseline: highEffortThreshold, upperCap: 1.15)
        let peakUtilizationPercent = Int((relativePeak * 100).rounded())
        let averageUtilizationPercent = Int((relativeAverage * 100).rounded())
        let nearPeakRatio = nearPeakHoldRatio(samples: orderedSamples, peakBPM: maxBPM)
        let nearPeakHoldPercent = Int((nearPeakRatio * 100).rounded())
        let recovery = recoveryMetrics(samples: orderedSamples, peakBPM: maxBPM)
        let climb = climbMetrics(samples: orderedSamples, peakBPM: maxBPM)

        let effortScore = (
            (relativePeak * 0.35) +
            (highEffortRatio * 0.20) +
            (relativeAverage * 0.15) +
            (nearPeakRatio * 0.10) +
            ((Double(climb.consistencyPercent) / 100.0) * 0.20)
        ) * 100
        let profileAdjustmentPoints = profileAdjustmentPoints(for: profile)
        let balancedScore = Int(
            max(
                0,
                min(
                    100,
                    (
                        (effortScore * 0.55) +
                        (Double(recovery.scorePercent) * 0.25) +
                        (Double(steadyConsistencyPercent) * 0.20) +
                        Double(profileAdjustmentPoints)
                    ).rounded()
                )
            )
        )

        return CompetitorResult(
            profile: profile,
            maxBPM: maxBPM,
            avgBPM: avgBPM,
            estimatedMaxBPM: estimatedMaxBPM,
            highEffortThreshold: highEffortThreshold,
            highEffortSeconds: highEffortSeconds,
            highEffortRatio: highEffortRatio,
            steadyConsistencyPercent: steadyConsistencyPercent,
            peakUtilizationPercent: peakUtilizationPercent,
            averageUtilizationPercent: averageUtilizationPercent,
            nearPeakHoldPercent: nearPeakHoldPercent,
            recoveryDropPercent: recovery.dropPercent,
            recoveryRatePercent: recovery.ratePercent,
            recoveryScorePercent: recovery.scorePercent,
            recoveryFloorBPM: recovery.floorBPM,
            recoveryTimeSeconds: recovery.timeToRecover,
            climbConsistencyPercent: climb.consistencyPercent,
            climbRateBPMPerMinute: climb.rateBPMPerMinute,
            profileAdjustmentPoints: profileAdjustmentPoints,
            balancedScore: balancedScore
        )
    }

    private func estimatedMaxBPM(for profile: PvPParticipantProfile) -> Int {
        // Tanaka baseline with small demographic offsets to reduce age/gender bias in raw BPM comparisons.
        var estimate = 208.0 - (0.7 * Double(profile.age))
        switch profile.gender.lowercased() {
        case "female":
            estimate += 2
        case "male":
            estimate -= 1
        default:
            break
        }
        return Int(max(120, min(205, estimate.rounded())))
    }

    private func personalHighEffortThreshold(estimatedMaxBPM: Int) -> Int {
        let threshold = Double(estimatedMaxBPM) * 0.84
        return Int(max(120, min(195, threshold.rounded())))
    }

    private func normalizedRatio(value: Int, baseline: Int, upperCap: Double) -> Double {
        guard baseline > 0 else { return 0 }
        let ratio = Double(value) / Double(baseline)
        return max(0, min(upperCap, ratio)) / upperCap
    }

    private func nearPeakHoldRatio(samples: [HeartRateSample], peakBPM: Int) -> Double {
        guard peakBPM > 0 else { return 0 }
        let threshold = Int((Double(peakBPM) * 0.92).rounded())
        let holdSeconds = durationAboveThreshold(samples: samples, threshold: threshold)
        let total = trackedDuration(samples: samples)
        guard total > 0 else { return 0 }
        return min(1, holdSeconds / total)
    }

    private func recoveryMetrics(
        samples: [HeartRateSample],
        peakBPM: Int
    ) -> (dropPercent: Int, ratePercent: Int, scorePercent: Int, floorBPM: Int, timeToRecover: TimeInterval) {
        guard samples.count >= 3, peakBPM > 0,
              let peakIndex = samples.firstIndex(where: { $0.bpm == peakBPM }) else {
            return (0, 0, 0, max(0, peakBPM), 0)
        }

        let peakSample = samples[peakIndex]
        let recoveryWindowEnd = peakSample.t + 180
        let postPeak = samples[(peakIndex + 1)...]
        let recoveryCandidates = postPeak.filter { $0.t <= recoveryWindowEnd }
        guard let floorSample = recoveryCandidates.min(by: { lhs, rhs in lhs.bpm < rhs.bpm }) else {
            return (0, 0, 0, peakBPM, 0)
        }

        let drop = max(0, peakBPM - floorSample.bpm)
        let rawDropPercent = (Double(drop) / Double(max(1, peakBPM))) * 100
        let timeToRecover = max(1, floorSample.t - peakSample.t)
        let dropPerMinute = Double(drop) / (timeToRecover / 60)

        let dropPercent = Int(rawDropPercent.rounded())
        let ratePercent = Int(max(0, min(100, (dropPerMinute / 25.0 * 100).rounded())))
        let dropTargetPercent = max(0, min(100, rawDropPercent / 22.0 * 100))
        let scorePercent = Int(max(0, min(100, ((dropTargetPercent * 0.65) + (Double(ratePercent) * 0.35)).rounded())))

        return (
            dropPercent,
            ratePercent,
            scorePercent,
            floorSample.bpm,
            timeToRecover
        )
    }

    private func climbMetrics(
        samples: [HeartRateSample],
        peakBPM: Int
    ) -> (consistencyPercent: Int, rateBPMPerMinute: Int) {
        guard samples.count >= 3, peakBPM > 0,
              let peakIndex = samples.firstIndex(where: { $0.bpm == peakBPM }),
              peakIndex > 0 else {
            return (0, 0)
        }

        let climbSlice = Array(samples[0...peakIndex])
        let totalSteps = max(1, climbSlice.count - 1)

        var positiveSteps = 0
        var directionFlips = 0
        var previousDirection = 0

        for index in 0..<(climbSlice.count - 1) {
            let delta = climbSlice[index + 1].bpm - climbSlice[index].bpm
            if delta >= 0 {
                positiveSteps += 1
            }

            let direction: Int
            if delta > 0 {
                direction = 1
            } else if delta < 0 {
                direction = -1
            } else {
                direction = 0
            }

            if direction != 0 {
                if previousDirection != 0, previousDirection != direction {
                    directionFlips += 1
                }
                previousDirection = direction
            }
        }

        let upwardRatio = Double(positiveSteps) / Double(totalSteps)
        let flipPenalty = Double(directionFlips) / Double(max(1, totalSteps - 1))
        let consistencyPercent = Int(
            max(
                0,
                min(
                    100,
                    ((upwardRatio * 100) - (flipPenalty * 35)).rounded()
                )
            )
        )

        let rise = max(0, peakBPM - climbSlice.first!.bpm)
        let timeToPeak = max(1, climbSlice.last!.t - climbSlice.first!.t)
        let rateBPMPerMinute = Int((Double(rise) / (timeToPeak / 60)).rounded())

        return (consistencyPercent, rateBPMPerMinute)
    }

    private func trackedDuration(samples: [HeartRateSample]) -> TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return max(1, last.t - first.t)
    }

    private func durationAboveThreshold(samples: [HeartRateSample], threshold: Int) -> TimeInterval {
        guard samples.count >= 2 else { return 0 }
        var total: TimeInterval = 0
        for index in 0..<(samples.count - 1) {
            let current = samples[index]
            let next = samples[index + 1]
            guard current.bpm >= threshold else { continue }
            let dt = max(0, min(2.5, next.t - current.t))
            total += dt
        }
        return total
    }

    private func consistencyScore(samples: [HeartRateSample]) -> Int {
        guard samples.count >= 2 else { return 0 }
        let values = samples.map { Double($0.bpm) }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 0 }
        let variance = values.reduce(0) { partial, value in
            let diff = value - mean
            return partial + (diff * diff)
        } / Double(values.count)
        let std = sqrt(variance)
        let cv = std / mean
        let score = (1 - cv) * 100
        return max(0, min(100, Int(score.rounded())))
    }

    private func profileAdjustmentPoints(for profile: PvPParticipantProfile) -> Int {
        let ageAdjustment = Double(profile.age - 30) * 0.22
        let bmiAdjustment = bodyMassAdjustmentPoints(profile: profile)
        let genderAdjustment = genderAdjustmentPoints(profile.gender)
        let experienceAdjustment = trainingExperienceAdjustmentPoints(profile.trainingExperience)
        let total = ageAdjustment + bmiAdjustment + genderAdjustment + experienceAdjustment
        return Int(max(-8, min(12, total.rounded())))
    }

    private func bodyMassAdjustmentPoints(profile: PvPParticipantProfile) -> Double {
        let weightKg = profile.weightLb * 0.45359237
        let heightM = profile.heightFeet * 0.3048
        guard heightM > 0 else { return 0 }
        let bmi = weightKg / (heightM * heightM)
        // Slight boost at both extremes where raw HR comparisons tend to be less fair.
        let distanceFromCenter = abs(bmi - 23)
        return min(3.0, distanceFromCenter * 0.12)
    }

    private func genderAdjustmentPoints(_ gender: String) -> Double {
        switch gender.lowercased() {
        case "female":
            return 1.0
        case "non-binary":
            return 0.5
        default:
            return 0
        }
    }

    private func trainingExperienceAdjustmentPoints(_ experience: String) -> Double {
        switch experience.lowercased() {
        case "beginner":
            return 4
        case "advanced":
            return -4
        default:
            return 0
        }
    }

    private func profileAdjustmentLabel(_ points: Int) -> String {
        if points > 0 {
            return "+\(points)"
        }
        return "\(points)"
    }

    private func winnerRow(title: String, value: String, winner: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            Text(winner)
                .font(.subheadline.weight(.bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func profileDetailLine(_ profile: PvPParticipantProfile) -> String {
        let weight = String(format: "%.0f", profile.weightLb)
        let height = feetInchesString(fromFeet: profile.heightFeet)
        return "Age \(profile.age) • \(weight) lb • \(height) • \(profile.gender) • \(profile.trainingExperience)"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func feetInchesString(fromFeet feetValue: Double) -> String {
        let totalInches = max(0, Int((feetValue * 12).rounded()))
        let feet = totalInches / 12
        let inches = totalInches % 12
        return "\(feet)'\(inches)\""
    }
}

private struct SessionOption: Identifiable {
    let id: String
    let files: SessionFiles
    let startedAt: Date
    let label: String
}

private struct CompetitorResult: Identifiable {
    let profile: PvPParticipantProfile
    let maxBPM: Int
    let avgBPM: Int
    let estimatedMaxBPM: Int
    let highEffortThreshold: Int
    let highEffortSeconds: TimeInterval
    let highEffortRatio: Double
    let steadyConsistencyPercent: Int
    let peakUtilizationPercent: Int
    let averageUtilizationPercent: Int
    let nearPeakHoldPercent: Int
    let recoveryDropPercent: Int
    let recoveryRatePercent: Int
    let recoveryScorePercent: Int
    let recoveryFloorBPM: Int
    let recoveryTimeSeconds: TimeInterval
    let climbConsistencyPercent: Int
    let climbRateBPMPerMinute: Int
    let profileAdjustmentPoints: Int
    let balancedScore: Int

    var id: UUID { profile.id }

    var highEffortRatioPercent: Int {
        Int((highEffortRatio * 100).rounded())
    }
}

private struct ProfileDraft: Identifiable {
    let draftID = UUID()
    var profileID: UUID?
    var displayName: String
    var ageText: String
    var weightText: String
    var heightFeetText: String
    var heightInchesText: String
    var gender: String
    var trainingExperience: String

    static func new() -> ProfileDraft {
        ProfileDraft(
            profileID: nil,
            displayName: "",
            ageText: "",
            weightText: "",
            heightFeetText: "",
            heightInchesText: "",
            gender: "Prefer not to say",
            trainingExperience: "Intermediate"
        )
    }

    static func from(_ profile: PvPParticipantProfile) -> ProfileDraft {
        let totalInches = max(0, Int((profile.heightFeet * 12).rounded()))
        let feet = totalInches / 12
        let inches = totalInches % 12
        return ProfileDraft(
            profileID: profile.id,
            displayName: profile.displayName,
            ageText: "\(profile.age)",
            weightText: String(format: "%.0f", profile.weightLb),
            heightFeetText: "\(feet)",
            heightInchesText: "\(inches)",
            gender: profile.gender,
            trainingExperience: profile.trainingExperience
        )
    }

    var id: UUID { draftID }

    var age: Int {
        Int(ageText) ?? 0
    }

    var weightLb: Double {
        Double(weightText) ?? 0
    }

    var heightFeet: Double {
        let feet = Int(heightFeetText) ?? 0
        let inches = Int(heightInchesText) ?? 0
        return Double(feet) + (Double(inches) / 12.0)
    }
}

private struct PvPProfileEditorView: View {
    @State var draft: ProfileDraft
    let onCancel: () -> Void
    let onSave: (ProfileDraft) -> Void

    @State private var error: String?

    private let genders = ["Male", "Female", "Non-binary", "Prefer not to say"]
    private let experienceLevels = ["Beginner", "Intermediate", "Advanced"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Display Name", text: $draft.displayName)
                    TextField("Age", text: $draft.ageText)
                        .keyboardType(.numberPad)
                    TextField("Weight (lb)", text: $draft.weightText)
                        .keyboardType(.decimalPad)
                    HStack(spacing: 8) {
                        Text("Height")
                            .foregroundStyle(.secondary)

                        TextField("ft", text: $draft.heightFeetText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 56)
                        Text("ft")
                            .foregroundStyle(.secondary)

                        TextField("in", text: $draft.heightInchesText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 56)
                        Text("in")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Gender", selection: $draft.gender) {
                        ForEach(genders, id: \.self) { gender in
                            Text(gender).tag(gender)
                        }
                    }
                    Picker("Training Experience", selection: $draft.trainingExperience) {
                        ForEach(experienceLevels, id: \.self) { level in
                            Text(level).tag(level)
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(draft.profileID == nil ? "New Participant" : "Edit Participant")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        validateAndSave()
                    }
                }
            }
        }
    }

    private func validateAndSave() {
        let trimmedName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            error = "Enter a display name."
            return
        }
        guard (10...120).contains(draft.age) else {
            error = "Enter a valid age."
            return
        }
        guard draft.weightLb > 0 else {
            error = "Enter a valid weight in lb."
            return
        }
        let feet = Int(draft.heightFeetText) ?? -1
        let inches = Int(draft.heightInchesText) ?? -1
        guard (2...8).contains(feet), (0...11).contains(inches) else {
            error = "Enter a valid height (example: 5 ft 11 in)."
            return
        }

        var updated = draft
        updated.displayName = trimmedName
        error = nil
        onSave(updated)
    }
}

#Preview {
    PvPView()
        .environmentObject(AuthStore())
}
