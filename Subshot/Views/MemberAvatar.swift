import SwiftUI

/// Google/Apple OAuth profile picture when the member signed up that way
/// (synced from Clerk into User.avatar_url at first login), falls back to
/// the colored-initials circle otherwise. Plain AsyncImage, not
/// AsyncShotThumbnail — avatar URLs are public CDN URLs (Google/Clerk),
/// unlike shot images which need our own Bearer-token auth.
struct MemberAvatar: View {
    let name: String?
    let email: String
    let userId: String
    let avatarUrl: String?
    var size: CGFloat = 32
    var fontSize: CGFloat? = nil

    init(name: String?, email: String, userId: String, avatarUrl: String?, size: CGFloat = 32, fontSize: CGFloat? = nil) {
        self.name = name
        self.email = email
        self.userId = userId
        self.avatarUrl = avatarUrl
        self.size = size
        self.fontSize = fontSize
    }

    init(member: Member, size: CGFloat = 32, fontSize: CGFloat? = nil) {
        self.init(name: member.name, email: member.email, userId: member.userId, avatarUrl: member.avatarUrl, size: size, fontSize: fontSize)
    }

    private var initials: String {
        let source = name?.isEmpty == false ? name! : email
        return String(source.prefix(2)).uppercased()
    }

    var body: some View {
        Group {
            if let avatarUrl, let url = URL(string: avatarUrl) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        initialsView
                    }
                }
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initialsView: some View {
        Text(initials)
            .font(.system(size: fontSize ?? size * 0.42, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.stableColor(for: userId))
    }
}
