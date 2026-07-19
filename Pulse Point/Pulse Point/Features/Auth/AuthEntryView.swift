import SwiftUI

struct AuthEntryView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case login = "Login"
        case register = "Register"

        var id: String { rawValue }
    }

    @EnvironmentObject private var authStore: AuthStore

    @State private var mode: Mode = .login

    @State private var loginEmail = ""
    @State private var loginPassword = ""

    @State private var registerUsername = ""
    @State private var registerEmail = ""
    @State private var registerPassword = ""
    @State private var registerConfirmPassword = ""

    @State private var resetEmail = ""
    @State private var showForgotPasswordSheet = false

    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.08, blue: 0.15),
                        Color(red: 0.03, green: 0.03, blue: 0.06),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerCard
                        modePicker

                        switch mode {
                        case .login:
                            loginCard
                        case .register:
                            registerCard
                        }

                        if let errorMessage {
                            statusCard(text: errorMessage, isError: true)
                        } else if let infoMessage {
                            statusCard(text: infoMessage, isError: false)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showForgotPasswordSheet) {
                forgotPasswordSheet
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ticker Flip")
                .font(.system(size: 32, weight: .black, design: .rounded))
            Text("Log in or create your account to continue.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var modePicker: some View {
        Picker("Auth Mode", selection: $mode) {
            ForEach(Mode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: mode) { _, _ in
            clearMessages()
        }
    }

    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Login")
                .font(.headline)

            TextField("Email", text: $loginEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $loginPassword)
                .textFieldStyle(.roundedBorder)

            Button("Log In") {
                Task {
                    await handleLogin()
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isSubmitting)

            Button("Forgot Password?") {
                clearMessages()
                resetEmail = loginEmail
                showForgotPasswordSheet = true
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var registerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Register")
                .font(.headline)

            TextField("Username", text: $registerUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textFieldStyle(.roundedBorder)

            TextField("Email", text: $registerEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $registerPassword)
                .textFieldStyle(.roundedBorder)

            SecureField("Confirm Password", text: $registerConfirmPassword)
                .textFieldStyle(.roundedBorder)

            Text("After registration, you must accept Terms of Service before using the app.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Create Account") {
                Task {
                    await handleRegister()
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isSubmitting)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var forgotPasswordSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("We will send a Firebase password reset email.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Email", text: $resetEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textFieldStyle(.roundedBorder)

                Button("Send Reset Email") {
                    Task {
                        await handleResetPassword()
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(isSubmitting)

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Forgot Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showForgotPasswordSheet = false
                    }
                }
            }
        }
    }

    private func statusCard(text: String, isError: Bool) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(isError ? .red : .secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func clearMessages() {
        errorMessage = nil
        infoMessage = nil
    }

    @MainActor
    private func handleLogin() async {
        clearMessages()
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await authStore.signIn(email: loginEmail, password: loginPassword)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func handleRegister() async {
        clearMessages()
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await authStore.register(
                username: registerUsername,
                email: registerEmail,
                password: registerPassword,
                confirmPassword: registerConfirmPassword
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func handleResetPassword() async {
        clearMessages()
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await authStore.resetPassword(email: resetEmail)
            infoMessage = "Password reset email sent. Check your inbox."
            showForgotPasswordSheet = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    AuthEntryView()
        .environmentObject(AuthStore())
}
