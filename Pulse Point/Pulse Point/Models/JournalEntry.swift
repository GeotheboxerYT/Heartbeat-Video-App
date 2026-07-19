import Foundation

struct JournalEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var trainingNotes: String
    var nutritionNotes: String
    var sleepHours: Double?
    var sleepNotes: String
    var dayNotes: String
    var extraNotes: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        trainingNotes: String = "",
        nutritionNotes: String = "",
        sleepHours: Double? = nil,
        sleepNotes: String = "",
        dayNotes: String = "",
        extraNotes: String = ""
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.trainingNotes = trainingNotes
        self.nutritionNotes = nutritionNotes
        self.sleepHours = sleepHours
        self.sleepNotes = sleepNotes
        self.dayNotes = dayNotes
        self.extraNotes = extraNotes
    }

    var hasContent: Bool {
        sleepHours != nil ||
        !trainingNotes.trimmed.isEmpty ||
        !nutritionNotes.trimmed.isEmpty ||
        !sleepNotes.trimmed.isEmpty ||
        !dayNotes.trimmed.isEmpty ||
        !extraNotes.trimmed.isEmpty
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
