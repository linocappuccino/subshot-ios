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

    /// Fractional (0-1) face-detected focus point within the source image
    /// (see Folder.backgroundImageFocusX/Y) — when set, the `.fill`-mode
    /// crop below is shifted so this point lands centered in the visible
    /// frame instead of the image's geometric middle. `nil` (the default)
    /// keeps today's plain center crop.
    var focusPoint: UnitPoint? = nil

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
            if let focusPoint {
                FocusedFillImage(image: image, focusPoint: focusPoint)
            } else {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
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
        // A single failed attempt used to be permanent — `failed = true` with
        // no retry meant one dropped connection or auth-token-refresh race
        // mid-scroll left that card's cover photo blank until the app was
        // relaunched, reported as the image having "disappeared" even though
        // it was never actually lost server-side (confirmed via direct DB +
        // uploads-folder check while debugging that report). Three attempts
        // with a short backoff absorbs exactly that kind of transient blip.
        for attempt in 0..<3 {
            do {
                let fetched = try await APIClient.shared.fetchImage(path: path)
                Self.cache.setObject(fetched, forKey: key)
                image = fetched
                return
            } catch {
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 400_000_000 * UInt64(attempt + 1))
                }
            }
        }
        failed = true
    }
}

/// Fill-mode crop that pans toward a fractional focus point instead of
/// always centering — the standard SwiftUI "oversized image + offset +
/// clipped" trick, just with the offset computed from `focusPoint` instead
/// of implicitly being the geometric middle. Used for folder cover photos
/// with a face-detected focus point (see Folder.backgroundImageFocusX/Y);
/// unused (nil focusPoint) elsewhere just falls back to plain center-fill.
private struct FocusedFillImage: View {
    let image: UIImage
    let focusPoint: UnitPoint

    var body: some View {
        GeometryReader { geo in
            let frameW = geo.size.width
            let frameH = geo.size.height
            let imgW = image.size.width
            let imgH = image.size.height

            let offset: (x: CGFloat, y: CGFloat) = {
                guard frameW > 0, frameH > 0, imgW > 0, imgH > 0 else { return (0, 0) }
                let imageAspect = imgW / imgH
                let frameAspect = frameW / frameH
                if imageAspect > frameAspect {
                    // Image is relatively wider than the frame — height
                    // matches exactly, width overflows and needs panning.
                    let scaledWidth = frameH * imageAspect
                    let overflowX = scaledWidth - frameW
                    return (-(focusPoint.x - 0.5) * overflowX, 0)
                } else if imageAspect < frameAspect {
                    let scaledHeight = frameW / imageAspect
                    let overflowY = scaledHeight - frameH
                    return (0, -(focusPoint.y - 0.5) * overflowY)
                }
                return (0, 0)
            }()

            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: frameW, height: frameH)
                .offset(x: offset.x, y: offset.y)
                .clipped()
        }
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
