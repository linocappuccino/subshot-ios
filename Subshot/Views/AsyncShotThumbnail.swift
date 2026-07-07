import SwiftUI

/// Shot images require the same Bearer-token auth as every other API call
/// (see GET /shots/:id/image/:filename on the backend — any project member
/// can view, but it's not a public URL) — SwiftUI's built-in `AsyncImage(url:)`
/// can't attach custom headers, so this fetches the bytes manually via
/// APIClient's authorized-request machinery and decodes them into a UIImage.
struct AsyncShotThumbnail: View {
    let path: String  // e.g. "/shots/{id}/image/{filename}" (already relative to baseURL)
    var size: CGFloat = 44

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: path) {
            await load()
        }
    }

    private func load() async {
        do {
            image = try await APIClient.shared.fetchImage(path: path)
        } catch {
            failed = true
        }
    }
}
