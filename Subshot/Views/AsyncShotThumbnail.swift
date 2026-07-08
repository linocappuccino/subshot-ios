import SwiftUI

/// Shot images require the same Bearer-token auth as every other API call
/// (see GET /shots/:id/image/:filename on the backend — any project member
/// can view, but it's not a public URL) — SwiftUI's built-in `AsyncImage(url:)`
/// can't attach custom headers, so this fetches the bytes manually via
/// APIClient's authorized-request machinery and decodes them into a UIImage.
struct AsyncShotThumbnail: View {
    let path: String  // e.g. "/shots/{id}/image/{filename}" (already relative to baseURL)

    /// Square frame side length. Pass `nil` for the big storyboard-card look,
    /// where the caller applies its own (non-square) `.frame(...)` instead.
    var size: CGFloat? = 44

    /// When true, ignores `size` and instead forces the frame itself to a
    /// clean 16:9 (landscape source) or 9:16 (portrait source) box, filling
    /// and cropping the photo to match — used for scene cover images so
    /// mixed photo orientations don't produce inconsistent card heights.
    var lockAspectRatio: Bool = false

    @State private var image: UIImage?
    @State private var failed = false

    /// Shared across every instance, keyed by path — without this, scrolling
    /// a list of image-bearing cards re-fetches the same image over and over
    /// as LazyVStack tears down and rebuilds off-screen rows, piling up
    /// concurrent authenticated network requests until the app becomes
    /// unresponsive (the reported scroll freeze). NSCache is thread-safe and
    /// evicts under memory pressure on its own.
    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        Group {
            if lockAspectRatio {
                let ratio: CGFloat = {
                    guard let image, image.size.height > 0 else { return 16.0 / 9.0 }
                    return image.size.width >= image.size.height ? 16.0 / 9.0 : 9.0 / 16.0
                }()
                Color.clear
                    .aspectRatio(ratio, contentMode: .fit)
                    .overlay { thumbnailContent }
                    .clipped()
            } else {
                thumbnailContent
                    .modifier(OptionalSquareFrame(size: size))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: path) {
            await load()
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if failed {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
        }
    }

    private func load() async {
        let key = path as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }
        print("🔵 [\(Self.ts())] START loading \(path)")
        do {
            let fetched = try await APIClient.shared.fetchImage(path: path)
            Self.cache.setObject(fetched, forKey: key)
            image = fetched
            print("🟢 [\(Self.ts())] DONE loading \(path)")
        } catch {
            failed = true
            print("🔴 [\(Self.ts())] FAILED loading \(path): \(error)")
        }
    }

    // TEMPORARY debugging aid for the scroll-freeze investigation — remove
    // once the cause is confirmed. A START print with no matching DONE/
    // FAILED print in the console right before a freeze means that specific
    // fetch is the one stuck.
    private static func ts() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}

private struct OptionalSquareFrame: ViewModifier {
    let size: CGFloat?
    @ViewBuilder
    func body(content: Content) -> some View {
        if let size {
            content.frame(width: size, height: size)
        } else {
            content
        }
    }
}
