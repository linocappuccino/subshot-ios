import Foundation
import Combine
import MapKit

/// Wraps MKLocalSearchCompleter (Apple's own address-autocomplete, no API
/// key/account needed) for the project location field. Old-style delegate
/// pattern on purpose, not an actor-isolated rewrite — keeps this safe to
/// compile under any concurrency-checking setting without needing to know
/// this project's exact Swift/Xcode version.
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer: MKLocalSearchCompleter

    override init() {
        completer = MKLocalSearchCompleter()
        super.init()
        completer.delegate = self
        // Addresses AND named places (studios, parks, venues) — a shoot
        // location is at least as often "Sihlwald" or "Studio 4" as a street address.
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        completer.queryFragment = query
    }

    func clear() {
        completer.queryFragment = ""
        results = []
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        DispatchQueue.main.async {
            self.results = completer.results
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.results = []
        }
    }
}

struct ResolvedLocation {
    let address: String
    let lat: Double
    let lng: Double
}

enum LocationSearch {
    /// Resolves a tapped autocomplete suggestion into a full address string
    /// + coordinate pair — the completion itself only has title/subtitle,
    /// the actual coordinate needs a follow-up MKLocalSearch.
    static func resolve(_ completion: MKLocalSearchCompletion) async throws -> ResolvedLocation {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        // .placemark is deprecated in iOS 26 in favor of .location — same
        // coordinate, just a plain CLLocation instead of an MKPlacemark.
        guard let coordinate = response.mapItems.first?.location?.coordinate else {
            throw NSError(domain: "LocationSearch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keine Koordinaten gefunden"])
        }
        let address = [completion.title, completion.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        return ResolvedLocation(address: address, lat: coordinate.latitude, lng: coordinate.longitude)
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
