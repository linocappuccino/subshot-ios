import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// One search result, from either the Google Places path (place_id set, no
/// coordinates yet — see resolve()) or the Nominatim fallback path
/// (coordinates already included, place_id nil).
struct LocationSuggestion: Hashable, Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String = ""
    let placeId: String?
    let lat: Double?
    let lng: Double?
}

/// Debounced wrapper around the backend's Google-Places-backed
/// /geocode/search (2026-07-15, replaces the old MKLocalSearchCompleter —
/// see [[project_subshot_billing_geocoding_20260715]]/Todoist #41: Apple's
/// on-device search has near-zero business/POI coverage, e.g. "ese agency"
/// in Zürich returned nothing, same root cause the web app already fixed by
/// switching to Google Places. iOS was left on MapKit at the time and never
/// got the same fix, which is what Lino kept reporting as still broken.
@MainActor
final class LocationSearchCompleter: ObservableObject {
    @Published var results: [LocationSuggestion] = []

    /// One UUID per search session, reused across every keystroke and passed
    /// to resolve() on pick, then replaced — see mapping.py's geocode_search
    /// doc comment for why this is what makes Google's Autocomplete billing
    /// stay free/near-free. Exposed so call sites can pass it into resolve().
    private(set) var sessionToken = UUID().uuidString

    private var searchTask: Task<Void, Never>?

    func update(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            results = []
            return
        }
        searchTask = Task { [sessionToken] in
            // Same 350ms-ish debounce as the web LocationPicker (400ms) —
            // avoids firing a request on every single keystroke.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            guard let fetched = try? await APIClient.shared.geocodeSearch(query: trimmed, sessionToken: sessionToken) else { return }
            guard !Task.isCancelled else { return }
            results = fetched.map {
                LocationSuggestion(title: $0.display_name, placeId: $0.place_id, lat: $0.lat, lng: $0.lng)
            }
        }
    }

    func clear() {
        searchTask?.cancel()
        results = []
        // Fresh session for the next search — mirrors the sessionToken
        // rotation the web app does after a pick/field blur.
        sessionToken = UUID().uuidString
    }
}

struct ResolvedLocation {
    let address: String
    let lat: Double
    let lng: Double
}

enum LocationSearch {
    /// Resolves a tapped suggestion into a full address string + coordinate
    /// pair. Nominatim results already carry coordinates inline; a Google
    /// result only has a place_id and needs the terminating /geocode/resolve
    /// call (see APIClient.geocodeResolve's doc comment).
    static func resolve(_ suggestion: LocationSuggestion, sessionToken: String) async throws -> ResolvedLocation {
        if let placeId = suggestion.placeId {
            let resolved = try await APIClient.shared.geocodeResolve(placeId: placeId, sessionToken: sessionToken)
            return ResolvedLocation(address: resolved.display_name, lat: resolved.lat, lng: resolved.lng)
        }
        guard let lat = suggestion.lat, let lng = suggestion.lng else {
            throw NSError(domain: "LocationSearch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keine Koordinaten gefunden"])
        }
        return ResolvedLocation(address: suggestion.title, lat: lat, lng: lng)
    }

    /// Opens Google Maps for the coordinate — a plain universal link, so it
    /// opens the native Google Maps app if installed (iOS upgrades
    /// google.com/maps links automatically) and falls back to the website
    /// otherwise. No custom URL scheme / Info.plist entry needed either way.
    /// `@MainActor` because UIApplication.shared is main-actor isolated in
    /// recent SDKs — called from synchronous SwiftUI gesture closures, which
    /// are themselves already main-actor, so this needs no `await` at the call site.
    @MainActor
    static func openInGoogleMaps(lat: Double, lng: Double) {
        guard let url = URL(string: "https://www.google.com/maps/search/?api=1&query=\(lat),\(lng)") else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}
