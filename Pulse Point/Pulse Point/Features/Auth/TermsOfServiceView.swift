import SwiftUI

struct TermsOfServiceView: View {
    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("Terms of Service")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("You need to accept these terms to use Ticker Flip.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    Text(tosText)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                HStack(spacing: 10) {
                    Button("Decline") {
                        authStore.signOut()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button("Accept & Continue") {
                        authStore.acceptTermsAndContinue()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
            .navigationBarHidden(true)
        }
    }

    private var tosText: String {
        """
        1. Use at your own risk.
        This app is for training feedback and not medical diagnosis or treatment.

        2. Data collection.
        The app records workout video and heart-rate data while you run sessions.

        3. Storage.
        Session files are stored on this device and may also sync to your configured backend API.

        4. User responsibility.
        You are responsible for handling your own account credentials and device security.

        5. Safety.
        Stop exercise immediately if you feel pain, dizziness, chest discomfort, or breathing issues.

        6. Updates.
        Features and policies may change in future versions.

        By tapping "Accept & Continue", you agree to these terms.
        """
    }
}

#Preview {
    TermsOfServiceView()
        .environmentObject(AuthStore())
}
