import Foundation
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
        APIClient.shared.tokenProvider = {
            try await Clerk.shared.session?.getToken()?.jwt
        }
    }

    func refreshMe() async {
        currentUser = try? await APIClient.shared.me()
    }

    func clear() {
        currentUser = nil
    }
}
