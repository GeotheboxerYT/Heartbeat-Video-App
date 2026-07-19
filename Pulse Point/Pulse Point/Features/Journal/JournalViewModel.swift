import Foundation

struct JournalEntryDraft {
    var trainingNotes: String = ""
    var nutritionNotes: String = ""
    var sleepHoursText: String = ""
    var sleepNotes: String = ""
    var dayNotes: String = ""
    var extraNotes: String = ""

    init() {}

    init(entry: JournalEntry) {
        trainingNotes = entry.trainingNotes
        nutritionNotes = entry.nutritionNotes
        if let sleepHours = entry.sleepHours {
            sleepHoursText = JournalEntryDraft.sleepHoursFormatter.string(from: NSNumber(value: sleepHours)) ?? ""
        }
        sleepNotes = entry.sleepNotes
        dayNotes = entry.dayNotes
        extraNotes = entry.extraNotes
    }

    var hasTextContent: Bool {
        !trainingNotes.trimmed.isEmpty ||
        !nutritionNotes.trimmed.isEmpty ||
        !sleepNotes.trimmed.isEmpty ||
        !dayNotes.trimmed.isEmpty ||
        !extraNotes.trimmed.isEmpty
    }

    private static let sleepHoursFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

@MainActor
final class JournalViewModel: ObservableObject {
    @Published private(set) var entries: [JournalEntry] = []
    @Published var isEditorPresented = false
    @Published var draft = JournalEntryDraft()
    @Published var errorMessage: String?
    @Published private(set) var autoFillMessage: String?

    private(set) var editingEntryID: UUID?
    private var userEmail: String?
    private let store: JournalStore
    private let sessionStorage: SessionStorage
    private let sleepStorage: SleepSessionStorage
    private let pvtStorage: PVTSessionStorage

    private let calendar = Calendar.current

    init(
        store: JournalStore = JournalStore(),
        sessionStorage: SessionStorage = SessionStorage(),
        sleepStorage: SleepSessionStorage = SleepSessionStorage(),
        pvtStorage: PVTSessionStorage = PVTSessionStorage()
    ) {
        self.store = store
        self.sessionStorage = sessionStorage
        self.sleepStorage = sleepStorage
        self.pvtStorage = pvtStorage
    }

    func setUserEmail(_ email: String?) {
        let normalized = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized != userEmail else { return }
        userEmail = normalized
        reloadEntries()
    }

    func reloadEntries() {
        entries = store.listEntries(for: userEmail)
    }

    func startNewEntry() {
        editingEntryID = nil
        let autoFill = buildAutoFillDraft(for: Date())
        draft = autoFill.draft
        autoFillMessage = autoFill.message
        errorMessage = nil
        isEditorPresented = true
    }

    func startEditing(_ entry: JournalEntry) {
        editingEntryID = entry.id
        draft = JournalEntryDraft(entry: entry)
        autoFillMessage = nil
        errorMessage = nil
        isEditorPresented = true
    }

    func cancelEditing() {
        isEditorPresented = false
        autoFillMessage = nil
        errorMessage = nil
    }

    func refreshAutoFillForToday() {
        let autoFill = buildAutoFillDraft(for: Date())
        autoFillMessage = autoFill.message
        guard autoFill.hasData else { return }

        mergeIfEmpty(current: &draft.trainingNotes, auto: autoFill.draft.trainingNotes)
        mergeIfEmpty(current: &draft.nutritionNotes, auto: autoFill.draft.nutritionNotes)
        mergeIfEmpty(current: &draft.sleepHoursText, auto: autoFill.draft.sleepHoursText)
        mergeIfEmpty(current: &draft.sleepNotes, auto: autoFill.draft.sleepNotes)
        mergeIfEmpty(current: &draft.dayNotes, auto: autoFill.draft.dayNotes)
        mergeIfEmpty(current: &draft.extraNotes, auto: autoFill.draft.extraNotes)
    }

    func saveDraft() {
        errorMessage = nil

        let sleepHoursInput = draft.sleepHoursText.trimmed
        var sleepHours: Double?
        if !sleepHoursInput.isEmpty {
            guard let parsed = Double(sleepHoursInput), parsed >= 0, parsed <= 24 else {
                errorMessage = "Sleep hours must be a number between 0 and 24."
                return
            }
            sleepHours = parsed
        }

        guard draft.hasTextContent || sleepHours != nil else {
            errorMessage = "Add at least one note before saving."
            return
        }

        if let id = editingEntryID,
           let existingIndex = entries.firstIndex(where: { $0.id == id }) {
            var updated = entries[existingIndex]
            updated.trainingNotes = draft.trainingNotes.trimmed
            updated.nutritionNotes = draft.nutritionNotes.trimmed
            updated.sleepHours = sleepHours
            updated.sleepNotes = draft.sleepNotes.trimmed
            updated.dayNotes = draft.dayNotes.trimmed
            updated.extraNotes = draft.extraNotes.trimmed
            updated.updatedAt = Date()
            entries[existingIndex] = updated
        } else {
            let now = Date()
            let entry = JournalEntry(
                createdAt: now,
                updatedAt: now,
                trainingNotes: draft.trainingNotes.trimmed,
                nutritionNotes: draft.nutritionNotes.trimmed,
                sleepHours: sleepHours,
                sleepNotes: draft.sleepNotes.trimmed,
                dayNotes: draft.dayNotes.trimmed,
                extraNotes: draft.extraNotes.trimmed
            )
            entries.append(entry)
        }

        entries.sort(by: { $0.updatedAt > $1.updatedAt })
        persistEntries()
    }

    func delete(_ entry: JournalEntry) {
        entries.removeAll(where: { $0.id == entry.id })
        persistEntries()
    }

    func displayDate(for entry: JournalEntry) -> String {
        entry.updatedAt.formatted(date: .abbreviated, time: .shortened)
    }

    func headline(for entry: JournalEntry) -> String {
        let firstText = [entry.trainingNotes, entry.nutritionNotes, entry.sleepNotes, entry.dayNotes, entry.extraNotes]
            .map(\.trimmed)
            .first(where: { !$0.isEmpty })

        if let firstText {
            if firstText.count > 86 {
                return String(firstText.prefix(86)) + "…"
            }
            return firstText
        }

        if let sleepHours = entry.sleepHours {
            return "Sleep: \(sleepHours.formatted(.number.precision(.fractionLength(0...1)))) hours"
        }

        return "Journal entry"
    }

    func detailLine(for entry: JournalEntry) -> String {
        var tags: [String] = []
        if !entry.trainingNotes.trimmed.isEmpty { tags.append("Training") }
        if !entry.nutritionNotes.trimmed.isEmpty { tags.append("Nutrition") }
        if entry.sleepHours != nil || !entry.sleepNotes.trimmed.isEmpty { tags.append("Sleep") }
        if !entry.dayNotes.trimmed.isEmpty { tags.append("Day") }
        if !entry.extraNotes.trimmed.isEmpty { tags.append("Other") }
        return tags.joined(separator: " • ")
    }

    private func persistEntries() {
        do {
            try store.saveEntries(entries, for: userEmail)
            isEditorPresented = false
            editingEntryID = nil
            autoFillMessage = nil
        } catch {
            errorMessage = "Could not save this journal entry."
            reloadEntries()
        }
    }

    private func mergeIfEmpty(current: inout String, auto: String) {
        guard current.trimmed.isEmpty, !auto.trimmed.isEmpty else { return }
        current = auto
    }

    private func buildAutoFillDraft(for date: Date) -> AutoFillResult {
        let workoutSummary = summarizeWorkouts(for: date)
        let sleepSummary = summarizeSleep(for: date)
        let pvtSummary = summarizePVT(for: date)

        var draft = JournalEntryDraft()
        var tags: [String] = []

        if let workoutSummary {
            draft.trainingNotes = workoutSummary
            tags.append("training")
        }

        if let sleepSummary {
            if let sleepHours = sleepSummary.sleepHours {
                draft.sleepHoursText = sleepHours.formatted(.number.precision(.fractionLength(0...1)))
            }
            draft.sleepNotes = sleepSummary.notes
            tags.append("sleep")
        }

        if let pvtSummary {
            draft.dayNotes = pvtSummary
            tags.append("PVT")
        }

        let hasData = !tags.isEmpty
        let dayLabel = date.formatted(date: .abbreviated, time: .omitted)
        let message: String = {
            if hasData {
                return "Auto-filled \(tags.joined(separator: ", ")) from app data for \(dayLabel). You can edit anything."
            }
            return "No app data found for \(dayLabel) yet. Enter your notes manually."
        }()

        return AutoFillResult(draft: draft, hasData: hasData, message: message)
    }

    private func summarizeWorkouts(for date: Date) -> String? {
        let files = sessionStorage.listSessions()
        var matchingSessions: [(metadata: WorkoutSessionMetadata, files: SessionFiles)] = []
        for sessionFiles in files {
            guard let metadata = sessionStorage.loadMetadata(from: sessionFiles.metadataURL),
                  calendar.isDate(metadata.startedAt, inSameDayAs: date) else {
                continue
            }
            matchingSessions.append((metadata: metadata, files: sessionFiles))
        }

        guard !matchingSessions.isEmpty else { return nil }

        let sessionCount = matchingSessions.count
        let videoAndHRCount = matchingSessions.filter { $0.metadata.videoFileName != nil }.count
        let hrOnlyCount = sessionCount - videoAndHRCount
        let totalDuration = matchingSessions.reduce(0) { $0 + $1.metadata.duration }
        let firstStart = matchingSessions.map(\.metadata.startedAt).min()
        let lastStart = matchingSessions.map(\.metadata.startedAt).max()

        let allSamples = matchingSessions.flatMap { sessionStorage.loadHeartRateSamples(from: $0.files.heartRateURL) }
        let minBPM = allSamples.map(\.bpm).min()
        let maxBPM = allSamples.map(\.bpm).max()
        let avgBPM: Int? = {
            guard !allSamples.isEmpty else { return nil }
            let sum = allSamples.reduce(0) { $0 + $1.bpm }
            return Int((Double(sum) / Double(allSamples.count)).rounded())
        }()

        var lines: [String] = []
        lines.append("Auto workout log")
        lines.append("- Sessions recorded: \(sessionCount) (\(videoAndHRCount) video + HR, \(hrOnlyCount) HR only)")
        lines.append("- Total recorded duration: \(formatDuration(totalDuration, includeSeconds: false))")
        if let avgBPM, let minBPM, let maxBPM {
            lines.append("- Heart rate summary: avg \(avgBPM) bpm, min \(minBPM), max \(maxBPM)")
        }
        if let firstStart {
            lines.append("- First session: \(firstStart.formatted(date: .omitted, time: .shortened))")
        }
        if let lastStart {
            lines.append("- Last session: \(lastStart.formatted(date: .omitted, time: .shortened))")
        }
        return lines.joined(separator: "\n")
    }

    private func summarizeSleep(for date: Date) -> (sleepHours: Double?, notes: String)? {
        let sessions = sleepStorage.listSessions()
        var metadataList: [SleepSessionMetadata] = []
        for session in sessions {
            guard let metadata = sleepStorage.loadMetadata(from: session.metadataURL) else { continue }
            metadataList.append(metadata)
        }

        let sameDayByEnd = metadataList
            .filter { calendar.isDate($0.endedAt, inSameDayAs: date) }
            .sorted { $0.endedAt > $1.endedAt }

        let sameDayByStart = metadataList
            .filter { calendar.isDate($0.startedAt, inSameDayAs: date) }
            .sorted { $0.startedAt > $1.startedAt }

        let metadata = sameDayByEnd.first ?? sameDayByStart.first
        guard let metadata else { return nil }

        let analysis = metadata.analysis
        let sleepHours = max(0, analysis.totalSleepTimeSeconds / 3600.0)
        var lines: [String] = []
        lines.append("Auto sleep log")
        lines.append("- Total sleep: \(formatDuration(analysis.totalSleepTimeSeconds, includeSeconds: false))")
        lines.append("- Time in bed: \(formatDuration(analysis.timeInBedSeconds, includeSeconds: false))")
        lines.append("- Sleep efficiency: \(Int(analysis.sleepEfficiencyPercent.rounded()))%")
        lines.append("- Resting HR: \(analysis.restingHeartRate) bpm")
        lines.append("- Avg sleep HR: \(analysis.averageSleepHeartRate) bpm")
        lines.append("- Readiness: \(analysis.readinessScore)% (\(analysis.readinessLabel))")
        lines.append("- Recovery score: \(analysis.recoveryScore)%")

        return (sleepHours: sleepHours, notes: lines.joined(separator: "\n"))
    }

    private func summarizePVT(for date: Date) -> String? {
        let sessions = pvtStorage.listSessions()
        let daySessions = sessions
            .filter { calendar.isDate($0.completedAt, inSameDayAs: date) }
            .sorted { $0.completedAt > $1.completedAt }

        guard !daySessions.isEmpty else { return nil }

        let beforeCount = daySessions.filter { $0.workoutTiming == .beforeWorkout }.count
        let afterCount = daySessions.count - beforeCount
        let latest = daySessions[0]

        var lines: [String] = []
        lines.append("Auto PVT log")
        lines.append("- Tests completed: \(daySessions.count) (\(beforeCount) before workout, \(afterCount) after workout)")
        lines.append("- Latest test: \(latest.workoutTiming.title), mean \(latest.metrics.meanReactionMS) ms, lapses \(latest.metrics.lapses), false starts \(latest.metrics.falseStarts)")

        if latest.workoutTiming == .afterWorkout,
           let beforeID = latest.linkedBeforeSessionID,
           let linkedBefore = sessions.first(where: { $0.id == beforeID }) {
            let meanDelta = latest.metrics.meanReactionMS - linkedBefore.metrics.meanReactionMS
            let lapseDelta = latest.metrics.lapses - linkedBefore.metrics.lapses
            lines.append("- Before vs after: mean \(deltaText(meanDelta, suffix: " ms")), lapses \(deltaText(lapseDelta))")
        }

        return lines.joined(separator: "\n")
    }

    private func formatDuration(_ seconds: TimeInterval, includeSeconds: Bool) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 || hours > 0 { parts.append("\(minutes)m") }
        if includeSeconds || (hours == 0 && minutes == 0) {
            parts.append("\(secs)s")
        }
        return parts.joined(separator: " ")
    }

    private func deltaText(_ delta: Int, suffix: String = "") -> String {
        if delta == 0 { return "0\(suffix)" }
        if delta > 0 { return "+\(delta)\(suffix)" }
        return "\(delta)\(suffix)"
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AutoFillResult {
    let draft: JournalEntryDraft
    let hasData: Bool
    let message: String
}
