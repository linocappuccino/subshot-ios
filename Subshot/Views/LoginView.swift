import SwiftUI
import ClerkKit
import ClerkKitUI

/// Minimalist login screen — logo + one button, matching the Reminders-app
/// aesthetic the whole app follows (see project spec §9). Clerk's own AuthView
/// (sheet) handles the actual sign-in/sign-up form, Google, etc. — no custom
/// form fields to build or keep in sync with whatever auth methods are enabled
/// in the Clerk dashboard.
struct LoginView: View {
    @State private var authIsPresented = false

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Subshot")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Shots planen. Am Set abhaken.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                authIsPresented = true
            } label: {
                Text("Anmelden")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
        }
        .sheet(isPresented: $authIsPresented) {
            AuthView()
        }
    }
}

#Preview {
    LoginView()
}
