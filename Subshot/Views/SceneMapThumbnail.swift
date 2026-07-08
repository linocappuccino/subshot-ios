import SwiftUI
import MapKit

/// Static map image for a scene's location, tap opens Google Maps — unlike
/// ProjectInfoBox's LocationSection (which deliberately uses a plain icon
/// tile, see its doc comment), this scene tile explicitly asked for a real
/// map image. Safe to reintroduce MKMapSnapshotter now that the earlier
/// "Map/MKMapSnapshotter crash the Simulator" finding turned out to be the
/// general iOS-26.5-Simulator rendering bug (see project memory), not
/// something specific to MapKit — confirmed fine on a real device. Snapshots
/// are generated once and cached (same NSCache-by-key pattern as
/// AsyncShotThumbnail) so LazyVStack scroll-recycling doesn't regenerate one
/// per re-render, which is what actually caused the original freeze.
struct SceneMapThumbnail: View {
    let lat: Double
    let lng: Double
    var size: CGFloat = 64

    @State private var image: UIImage?
    @State private var failed = false

    private static let cache = NSCache<NSString, UIImage>()

    private var cacheKey: String {
        "\(round(lat * 1000) / 1000),\(round(lng * 1000) / 1000)"
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.accentColor.opacity(0.15))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if failed {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                } else {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture { LocationSearch.openInGoogleMaps(lat: lat, lng: lng) }
            .task(id: cacheKey) { await load() }
    }

    private func load() async {
        let key = cacheKey as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            latitudinalMeters: 400, longitudinalMeters: 400
        )
        options.size = CGSize(width: size * 2, height: size * 2)
        options.scale = await UIScreen.main.scale
        options.showsBuildings = false
        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            Self.cache.setObject(snapshot.image, forKey: key)
            image = snapshot.image
        } catch {
            failed = true
        }
    }
}
