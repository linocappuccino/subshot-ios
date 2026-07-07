import Foundation
import Combine
import ClerkKit

/// Thin bridge between Clerk (handles sign-in/session/token) and our own
/// backend's `/me` (our own User row — Clerk only knows about ITS user object,
/// not ours). Clerk.shared itself is @Observable and injected into the SwiftUI
/// environment directly in SubshotApp.swift — this class only holds the extra
/// state our backend adds on top.
///
/// One-time Xcode setup:
/// 1. File > Add Package Dependencies... > https://github.com/clerk/clerk-ios
///    Add both products: ClerkKit and ClerkKitUI.
/// 2. See SubshotApp.swift for `Clerk.configure(publishableKey:)`.
@MainActor
final class BackendAuth: ObservableObject {
    static let shared = BackendAuth()

    @Published var currentUser: Me?

    private init() {
        // NOTE (2026-07-07): getToken() returns the JWT String directly in
        // the installed SDK version — a `.jwt` was assumed from docs/older
        // examples and didn't compile ("Value of type 'String' has no
        // member 'jwt'").
        APIClient.shared.tokenProvider = {
            try await Clerk.shared.session?.getToken()
        }
    }

    func refreshMe() async {
        currentUser = try? await APIClient.shared.me()
    }

    func clear() {
        currentUser = nil
    }
}
