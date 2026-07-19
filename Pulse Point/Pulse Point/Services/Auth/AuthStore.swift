import CryptoKit
import FirebaseAuth
import Foundation

struct LocalAuthUser: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var firebaseUID: String?
    let username: String
    let email: String
    var passwordHash: String
    let createdAt: Date
    var acceptedTerms: Bool
    var onboardingProfile: UserOnboardingProfile?
}

struct UserOnboardingProfile: Codable, Equatable, Sendable {
    let age: Int
    let weightLb: Double
    let heightCm: Double
    let gender: String
    let completedAt: Date
}

enum AuthStoreError: LocalizedError {
    case invalidUsername
    case invalidEmail
    case weakPassword
    case passwordMismatch
    case emailAlreadyRegistered
    case invalidCredentials

    var errorDescription: String? {
        switch self {
        case .invalidUsername:
            return "Enter a username with at least 3 characters."
        case .invalidEmail:
            return "Enter a valid email address."
        case .weakPassword:
            return "Use at least 8 characters for your password."
        case .passwordMismatch:
            return "Passwords do not match."
        case .emailAlreadyRegistered:
            return "That email is already registered."
        case .invalidCredentials:
            return "Email or password is incorrect."
        }
    }
}

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var needsTermsAcceptance = false
    @Published private(set) var needsProfileCompletion = false
    @Published private(set) var currentUserEmail: String?
    @Published private(set) var currentUsername: String?
    @Published private(set) var currentFirebaseUID: String?
    @Published private(set) var currentUserProfile: UserOnboardingProfile?

    private var users: [LocalAuthUser] = []
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let users = "auth.local.users"
        static let currentUserEmail = "auth.local.currentUserEmail"
    }

    init() {
        loadUsers()
        restoreSession()
    }

    func register(
        username: String,
        email: String,
        password: String,
        confirmPassword: String
    ) async throws {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmail = normalize(email)

        guard cleanUsername.count >= 3 else {
            throw AuthStoreError.invalidUsername
        }
        guard isValidEmail(cleanEmail) else {
            throw AuthStoreError.invalidEmail
        }
        guard password.count >= 8 else {
            throw AuthStoreError.weakPassword
        }
        guard password == confirmPassword else {
            throw AuthStoreError.passwordMismatch
        }
        guard userIndex(for: cleanEmail) == nil else {
            throw AuthStoreError.emailAlreadyRegistered
        }

        let firebaseUser = try await createFirebaseUser(email: cleanEmail, password: password)
        try await updateFirebaseDisplayName(cleanUsername, for: firebaseUser)

        let user = LocalAuthUser(
            id: UUID(),
            firebaseUID: firebaseUser.uid,
            username: cleanUsername,
            email: cleanEmail,
            passwordHash: hash(password),
            createdAt: Date(),
            acceptedTerms: false,
            onboardingProfile: nil
        )
        users.append(user)
        saveUsers()
        // New registration should always be offered the in-app tour.
        defaults.removeObject(forKey: tourPromptStorageKey(for: cleanEmail))
        setAuthenticatedSession(for: cleanEmail)
    }

    func signIn(email: String, password: String) async throws {
        let cleanEmail = normalize(email)
        guard isValidEmail(cleanEmail) else {
            throw AuthStoreError.invalidEmail
        }

        do {
            let firebaseUser = try await signInFirebaseUser(email: cleanEmail, password: password)
            upsertLocalUserFromFirebase(firebaseUser, email: cleanEmail, password: password)
            setAuthenticatedSession(for: cleanEmail)
        } catch {
            // Keeps old local test accounts usable if Firebase is temporarily unreachable while developing.
            guard let index = userIndex(for: cleanEmail), users[index].passwordHash == hash(password) else {
                throw error
            }
            setAuthenticatedSession(for: cleanEmail)
        }
    }

    @discardableResult
    func resetPassword(email: String) async throws -> Bool {
        let cleanEmail = normalize(email)
        guard isValidEmail(cleanEmail) else {
            throw AuthStoreError.invalidEmail
        }

        try await sendFirebasePasswordReset(email: cleanEmail)
        return true
    }

    func acceptTermsAndContinue() {
        guard let currentUserEmail,
              let index = userIndex(for: currentUserEmail) else {
            signOut()
            return
        }

        users[index].acceptedTerms = true
        saveUsers()
        needsTermsAcceptance = false
        needsProfileCompletion = users[index].onboardingProfile == nil
        syncCurrentUserToBackend()
    }

    func completeOnboardingProfile(
        age: Int,
        weightLb: Double,
        heightCm: Double,
        gender: String
    ) {
        guard let currentUserEmail,
              let index = userIndex(for: currentUserEmail) else {
            signOut()
            return
        }

        users[index].onboardingProfile = UserOnboardingProfile(
            age: age,
            weightLb: weightLb,
            heightCm: heightCm,
            gender: gender,
            completedAt: Date()
        )
        saveUsers()
        currentUserProfile = users[index].onboardingProfile
        needsProfileCompletion = false
        syncCurrentUserToBackend()
    }

    func deleteCurrentAccountKeepSessions() async throws {
        guard let currentUserEmail,
              let index = userIndex(for: currentUserEmail) else {
            signOut()
            return
        }

        if let firebaseUser = Auth.auth().currentUser,
           firebaseUser.email?.lowercased() == currentUserEmail || firebaseUser.uid == users[index].firebaseUID {
            try await deleteFirebaseUser(firebaseUser)
        }

        defaults.removeObject(forKey: tourPromptStorageKey(for: currentUserEmail))
        users.remove(at: index)
        saveUsers()
        signOut()
    }

    func signOut() {
        try? Auth.auth().signOut()
        defaults.removeObject(forKey: Keys.currentUserEmail)
        isAuthenticated = false
        needsTermsAcceptance = false
        needsProfileCompletion = false
        currentUserEmail = nil
        currentUsername = nil
        currentFirebaseUID = nil
        currentUserProfile = nil
    }

    private func restoreSession() {
        guard let email = defaults.string(forKey: Keys.currentUserEmail),
              let index = userIndex(for: email) else {
            signOut()
            return
        }

        let user = users[index]
        currentUserEmail = user.email
        currentUsername = user.username
        currentFirebaseUID = user.firebaseUID ?? Auth.auth().currentUser?.uid
        currentUserProfile = user.onboardingProfile
        isAuthenticated = true
        needsTermsAcceptance = !user.acceptedTerms
        needsProfileCompletion = user.onboardingProfile == nil
        syncCurrentUserToBackend()
    }

    private func setAuthenticatedSession(for email: String) {
        guard let index = userIndex(for: email) else { return }
        let user = users[index]

        defaults.set(user.email, forKey: Keys.currentUserEmail)
        currentUserEmail = user.email
        currentUsername = user.username
        currentFirebaseUID = user.firebaseUID ?? Auth.auth().currentUser?.uid
        currentUserProfile = user.onboardingProfile
        isAuthenticated = true
        needsTermsAcceptance = !user.acceptedTerms
        needsProfileCompletion = user.onboardingProfile == nil
        syncCurrentUserToBackend()
    }

    private func upsertLocalUserFromFirebase(_ firebaseUser: FirebaseAuth.User, email: String, password: String) {
        let displayName = firebaseUser.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = displayName?.isEmpty == false ? displayName! : email.components(separatedBy: "@").first ?? "User"

        if let index = userIndex(for: email) {
            users[index].firebaseUID = firebaseUser.uid
            users[index].passwordHash = hash(password)
        } else {
            users.append(
                LocalAuthUser(
                    id: UUID(),
                    firebaseUID: firebaseUser.uid,
                    username: username,
                    email: email,
                    passwordHash: hash(password),
                    createdAt: Date(),
                    acceptedTerms: false,
                    onboardingProfile: nil
                )
            )
        }
        saveUsers()
    }

    private func createFirebaseUser(email: String, password: String) async throws -> FirebaseAuth.User {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FirebaseAuth.User, Error>) in
            Auth.auth().createUser(withEmail: email, password: password) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let user = result?.user else {
                    continuation.resume(throwing: AuthStoreError.invalidCredentials)
                    return
                }
                continuation.resume(returning: user)
            }
        }
    }

    private func signInFirebaseUser(email: String, password: String) async throws -> FirebaseAuth.User {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FirebaseAuth.User, Error>) in
            Auth.auth().signIn(withEmail: email, password: password) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let user = result?.user else {
                    continuation.resume(throwing: AuthStoreError.invalidCredentials)
                    return
                }
                continuation.resume(returning: user)
            }
        }
    }

    private func updateFirebaseDisplayName(_ displayName: String, for user: FirebaseAuth.User) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let request = user.createProfileChangeRequest()
            request.displayName = displayName
            request.commitChanges { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func sendFirebasePasswordReset(email: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Auth.auth().sendPasswordReset(withEmail: email) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func deleteFirebaseUser(_ user: FirebaseAuth.User) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            user.delete { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func userIndex(for email: String) -> Int? {
        users.firstIndex(where: { normalize($0.email) == normalize(email) })
    }

    private func loadUsers() {
        guard let data = defaults.data(forKey: Keys.users),
              let decoded = try? JSONDecoder().decode([LocalAuthUser].self, from: data) else {
            users = []
            return
        }
        users = decoded
    }

    private func saveUsers() {
        guard let data = try? JSONEncoder().encode(users) else { return }
        defaults.set(data, forKey: Keys.users)
    }

    private func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func hash(_ password: String) -> String {
        let digest = SHA256.hash(data: Data(password.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isValidEmail(_ email: String) -> Bool {
        guard email.contains("@"), email.contains(".") else { return false }
        let parts = email.split(separator: "@")
        guard parts.count == 2 else { return false }
        return !parts[0].isEmpty && parts[1].contains(".")
    }

    private func tourPromptStorageKey(for email: String) -> String {
        "onboarding.tour.prompted.\(normalize(email))"
    }

    private func syncCurrentUserToBackend() {
        guard let email = currentUserEmail else { return }

        let displayName = currentUsername
        let firebaseUID = currentFirebaseUID
        let profile = currentUserProfile
        let acceptedTerms = !needsTermsAcceptance

        Task {
            _ = try? await APIClient.shared.resolveUser(
                email: email,
                displayName: displayName,
                firebaseUid: firebaseUID,
                profile: profile,
                termsAccepted: acceptedTerms
            )
        }
    }
}
