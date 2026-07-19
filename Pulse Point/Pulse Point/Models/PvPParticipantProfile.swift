import Foundation

struct PvPParticipantProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var age: Int
    var weightLb: Double
    var heightFeet: Double
    var gender: String
    var trainingExperience: String
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        age: Int,
        weightLb: Double,
        heightFeet: Double,
        gender: String,
        trainingExperience: String = "Intermediate",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.age = age
        self.weightLb = weightLb
        self.heightFeet = heightFeet
        self.gender = gender
        self.trainingExperience = trainingExperience
        self.updatedAt = updatedAt
    }

    // Supports older saved profiles that stored height in centimeters.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        age = try container.decode(Int.self, forKey: .age)
        weightLb = try container.decode(Double.self, forKey: .weightLb)
        gender = try container.decode(String.self, forKey: .gender)
        trainingExperience = try container.decodeIfPresent(String.self, forKey: .trainingExperience) ?? "Intermediate"
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        if let feet = try container.decodeIfPresent(Double.self, forKey: .heightFeet) {
            heightFeet = feet
        } else if let cm = try container.decodeIfPresent(Double.self, forKey: .heightCm) {
            heightFeet = cm / 30.48
        } else {
            heightFeet = 0
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case age
        case weightLb
        case heightFeet
        case heightCm
        case gender
        case trainingExperience
        case updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(age, forKey: .age)
        try container.encode(weightLb, forKey: .weightLb)
        try container.encode(heightFeet, forKey: .heightFeet)
        try container.encode(gender, forKey: .gender)
        try container.encode(trainingExperience, forKey: .trainingExperience)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct PvPProfileBundle: Codable {
    var profiles: [PvPParticipantProfile]
    var deviceAssignments: [String: UUID]

    static let empty = PvPProfileBundle(
        profiles: [],
        deviceAssignments: [:]
    )
}
