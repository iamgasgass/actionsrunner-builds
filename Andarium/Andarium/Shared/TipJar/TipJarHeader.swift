// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import SwiftUI
import UIKit

// The sender line above the developer's bubbles: a circular avatar, the
// developer's name and role, and a logo button for each profile. Every piece
// follows what the build holds: without the avatar the header keeps the app's
// own mark, without the name it reads the role alone, and a logo button exists
// only where its handle and its logo asset both do. The values are the
// maker's, local to an AppStore build (`Config/Developer.local.xcconfig`), and
// so are the assets, which are catalogs of their own; nothing here names one.

/// What the header shows, read once when the sheet opens.
struct TipJarSenderContent {
    struct Link: Identifiable {
        enum Site: String { case github, x }

        let site: Site
        let url: URL
        /// A template image: it takes the colour of the text around it.
        let logo: UIImage
        var id: String { site.rawValue }
        /// The brand's own name, which no language translates.
        var name: String { site == .github ? "GitHub" : "X" }
        var aspectRatio: Double { logo.size.height > 0 ? logo.size.width / logo.size.height : 1 }
    }

    var name: String?
    var avatar: UIImage?
    var links: [Link]

    init(name: String? = nil, avatar: UIImage? = nil, links: [Link] = []) {
        self.name = name
        self.avatar = avatar
        self.links = links
    }

    /// The developer and the artwork, each piece only where both parts of it exist.
    init(developer: TipJarDeveloper, avatar: UIImage?, githubLogo: UIImage?, xLogo: UIImage?) {
        var links: [Link] = []
        if let url = developer.githubURL, let logo = githubLogo {
            links.append(Link(site: .github, url: url, logo: logo.withRenderingMode(.alwaysTemplate)))
        }
        #if SHEET_X
        // The profile's address is Follow developer on X's to build.
        if let url = developer.xHandle.flatMap({ FollowXProfile.url(handle: $0) }), let logo = xLogo {
            links.append(Link(site: .x, url: url, logo: logo.withRenderingMode(.alwaysTemplate)))
        }
        #endif
        self.init(name: developer.name, avatar: avatar, links: links)
    }

    /// The build's own: the Info.plist values and the assets compiled into the product.
    @MainActor
    static var live: TipJarSenderContent {
        typealias Configuration = TipJarDeveloperConfiguration
        return TipJarSenderContent(
            developer: Configuration.developer, avatar: UIImage(named: Configuration.avatarAsset),
            githubLogo: UIImage(named: Configuration.githubAsset), xLogo: UIImage(named: Configuration.xAsset))
    }

    /// The sender line, as VoiceOver reads it and as the header shows it.
    var line: String {
        let role = String(localized: TipJarWords.sender)
        return name.map { "\($0) \u{00B7} \(role)" } ?? role
    }

    var spokenLine: String {
        let role = String(localized: TipJarWords.sender)
        return name.map { "\($0), \(role)" } ?? role
    }
}

/// Who speaks. `links` is false for the second line, where the developer answers.
struct TipJarSender: View {
    let content: TipJarSenderContent
    var links = true
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .caption) private var avatarMetric = 28.0
    @ScaledMetric(relativeTo: .caption) private var glyphMetric = 15.0

    /// The system's touch target, which a logo keeps without letting it space the glyphs.
    private let target = 44.0
    /// The gap between the name and the first logo, and between the logos, as text has between words.
    private let spacing = 8.0

    private var avatarSize: Double { avatarMetric }
    private var glyphSize: Double { glyphMetric }
    private var shownLinks: [TipJarSenderContent.Link] { links ? content.links : [] }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // One line when it fits.
            HStack(spacing: spacing) {
                avatar
                line.lineLimit(1)
                logos
            }
            // The logos move under the text when it does not.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: spacing) {
                    avatar
                    line
                }
                logos.padding(.leading, avatarSize + spacing)
            }
        }
    }

    /// The avatar, or the application's mark where the build has none. Decorative.
    @ViewBuilder
    private var avatar: some View {
        Group {
            if let image = content.avatar {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(.circle)
                    // A hairline from the separator colour reads on light and dark.
                    .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 1 / displayScale))
            } else {
                StackMark(lit: true, width: avatarSize * 0.7)
                    .frame(width: avatarSize, height: avatarSize)
                    .background(Color(.secondarySystemBackground), in: .circle)
            }
        }
        .accessibilityHidden(true)
    }

    /// The name and the role, read once as one element.
    private var line: some View {
        Text(verbatim: content.line)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: content.spokenLine))
            .accessibilityAddTraits(.isHeader)
    }

    private var logos: some View {
        HStack(spacing: spacing) {
            ForEach(Array(shownLinks.enumerated()), id: \.element.id) { index, link in
                let reach = reach(ofLinkAt: index)
                let across = (target - glyphSize) / 2
                SwiftUI.Link(destination: link.url) {
                    // The label colour, black or white as the appearance says, never the tint.
                    Image(uiImage: link.logo)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(link.aspectRatio, contentMode: .fit)
                        .foregroundStyle(Color(.label))
                        .frame(height: glyphSize)
                        // The touch target is the glyph and the space around it...
                        .padding(EdgeInsets(top: across, leading: reach.leading, bottom: across, trailing: reach.trailing))
                        .contentShape(.rect)
                }
                // ...which the layout does not count, so the glyphs sit one gap apart.
                .padding(EdgeInsets(top: -across, leading: -reach.leading, bottom: -across, trailing: -reach.trailing))
                .accessibilityLabel(Text(verbatim: link.name))
                .accessibilityIdentifier("tipjar-link-\(link.site.rawValue)")
            }
        }
    }

    /// How far a logo's touch target reaches past its glyph on each side: 44 pt tall, and wide enough
    /// to make 44 pt where nothing is next to it. Two logos one gap apart cannot each have 44 pt of
    /// width, so they share the gap between them, and no tap lands on the wrong glyph.
    private func reach(ofLinkAt index: Int) -> (leading: Double, trailing: Double) {
        let width = glyphSize * shownLinks[index].aspectRatio
        let outer = max(0, (target - width) / 2)
        let inner = spacing / 2
        return (index == 0 ? outer : inner, index == shownLinks.count - 1 ? outer : inner)
    }
}

#endif
